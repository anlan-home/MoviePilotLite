import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'player_engine.dart';
import '../mpv/mpv_engine.dart';
import '../exo/exo_engine.dart';
import '../exo/exo_ffmpeg_engine.dart';
import '../../services/storage_service.dart';
import '../../utils/app_log.dart';

/// 播放器内核选择策略
enum EngineSelectStrategy {
  /// 自动（默认）：网络流/HLS/DASH 用 ExoPlayer（自适应/硬解最优），
  /// 本地/HDR/原盘用 MPV（格式兼容 + tone-mapping）。
  /// 命名与行为一致：`auto` 而不是误导性的 `preferMpv`。
  auto,
  /// 仅 MPV
  mpvOnly,
  /// 仅 Exo
  exoOnly,
}

/// 播放器管理器 — 负责内核选择、切换、回退
class PlayerManager {
  PlayerEngine? _currentEngine;
  EngineSelectStrategy _strategy = EngineSelectStrategy.auto;
  String? _currentUrl;
  Map<String, String>? _currentHeaders;
  // 引擎创建重入守卫:并发 createEngine(快速重试/连点播放)会在
  // disposeEngine 置空 _currentEngine 与 return _currentEngine! 之间互踩,
  // 抛「Null check operator」(真机堆栈实证 2026-08-29)。创建期间拒绝重入。
  bool _creating = false;

  final StreamController<PlayerEngineType> _engineChangeController =
      StreamController<PlayerEngineType>.broadcast();

  /// 当前引擎
  PlayerEngine? get currentEngine => _currentEngine;

  /// 当前引擎类型
  PlayerEngineType get currentEngineType => _currentEngine?.engineType ?? PlayerEngineType.mpv;

  /// 引擎切换通知流
  Stream<PlayerEngineType> get engineChangeStream => _engineChangeController.stream;

  /// 选择策略
  EngineSelectStrategy get strategy => _strategy;

  /// 设置选择策略
  void setStrategy(EngineSelectStrategy strategy) {
    _strategy = strategy;
  }

  /// 根据设置和 URL 自动选择最佳引擎
  PlayerEngineType selectEngine(String url) {
    // iOS 上 ExoPlayer 不存在(video_player 走 AVPlayer,不支持 MKV/HEVC
    // 等媒体中心常见格式)—— iOS 强制 MPV(mpv iOS 带 videotoolbox 硬解)
    if (Platform.isIOS) {
      return PlayerEngineType.mpv;
    }

    // HDR/蓝光原盘文件强制使用 MPV（MPV 已配置 tone-mapping，ExoPlayer 无法处理）
    if (_isHdrFile(url)) {
      AppLog.i('PlayerManager', 'selectEngine: HDR/蓝光 → MPV (url=${url.length > 80 ? '${url.substring(0, 80)}...' : url})');
      return PlayerEngineType.mpv;
    }

    final streaming = _isStreamingUrl(url);
    AppLog.i('PlayerManager', 'selectEngine: strategy=$_strategy, isStreaming=$streaming, url=${url.length > 100 ? '${url.substring(0, 100)}...' : url}');

    switch (_strategy) {
      case EngineSelectStrategy.mpvOnly:
        return PlayerEngineType.mpv;
      case EngineSelectStrategy.exoOnly:
        return PlayerEngineType.exo;
      case EngineSelectStrategy.auto:
        // ExoPlayer 为主力引擎（TV 上 Surface 直通性能最优），
        // MPV 仅用于 HDR/ISO/BDMV 原盘（已由 _isHdrFile 在上方拦截）
        return PlayerEngineType.exo;
    }
  }

  bool _isStreamingUrl(String url) {
    final lower = url.toLowerCase();
    // HLS / DASH 显式流媒体协议
    if (lower.contains('.m3u8') ||
        lower.contains('.mpd') ||
        lower.contains('/dash/') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://')) {
      return true;
    }
    // Emby / Jellyfin 转码流：包含 /Videos/xxx/stream 且带 ?api_key=
    // 这类流返回的是实时转码的 MP4 片段，MPV 处理不佳
    if ((lower.contains('/videos/') && lower.contains('stream?')) ||
        (lower.contains('static=true') && lower.contains('mediasourceid='))) {
      return true;
    }
    // 任何带 api_key 参数的 Emby 链接都视为流媒体
    if (lower.contains('?api_key=') || lower.contains('&api_key=')) {
      return true;
    }
    // 飞牛原生直流：/v/api/v1/media/range/{guid}（HTTP 206 Range）
    if (lower.contains('/media/range/')) {
      return true;
    }
    // 兜底：任何 http/https 网络 URL 都视为流媒体（本地文件走 _isLocalFile）
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return true;
    }
    return false;
  }

  bool _isLocalFile(String url) {
    return url.startsWith('/') || url.startsWith('file://');
  }

  /// 判断是否为 HDR/蓝光原盘文件，这类文件需要 MPV 的 tone-mapping 才能正确显示
  bool _isHdrFile(String url) {
    final lower = url.toLowerCase();
    // ISO 蓝光原盘
    if (lower.endsWith('.iso')) return true;
    // BDMV 目录结构
    if (lower.contains('/bdmv/') || lower.contains('\\bdmv\\')) return true;
    // 常见 HDR 视频格式（本地文件路径才判断）
    if (_isLocalFile(url)) {
      if (lower.endsWith('.mkv') || lower.endsWith('.ts') || lower.endsWith('.m2ts')) {
        return true;
      }
    }
    return false;
  }

  /// 给 Emby/Jellyfin 转码流 URL 补充色彩参数，避免 ExoPlayer 偏绿
  /// 偏绿原因：Emby 转码时默认输出 tv 色彩范围 + bt709 色彩空间，
  /// Android ExoPlayer 把 tv 范围当成 pc 范围处理，导致高光偏绿。
  /// 通过强制让 Emby 输出 pc 色彩范围可以解决。
  String _fixEmbyColorParams(String url) {
    final lower = url.toLowerCase();
    // Static=true 是直出流（不转码），色彩参数无意义且会导致服务器拒绝请求
    if (lower.contains('static=true')) return url;
    final isEmbyStream = (lower.contains('/videos/') && lower.contains('stream?')) ||
        (lower.contains('mediasourceid=') && lower.contains('api_key='));
    if (!isEmbyStream) return url;

    final uri = Uri.parse(url);
    final params = Map<String, String>.from(uri.queryParameters);
    // 强制色彩范围为 pc（限制范围），并显式指定 8bit + bt709，避免色彩错位
    params['colorrange'] = 'pc';
    params['colorprimaries'] = 'bt709';
    params['colortransfer'] = 'bt709';
    params['colorspace'] = 'bt709';
    if (!params.containsKey('videobitdepth')) {
      params['videobitdepth'] = '8';
    }

    final newUri = uri.replace(queryParameters: params);
    return newUri.toString();
  }

  /// 创建并初始化引擎
  Future<PlayerEngine> createEngine({
    required String url,
    Map<String, String>? httpHeaders,
    bool autoPlay = true,
    PlayerEngineType? forceEngine,
  }) async {
    // 重入守卫:创建期间(含转码回退)拒绝并发调用——并发会在 disposeEngine
    // 置空 _currentEngine 与 return _currentEngine! 之间互踩,抛 Null check
    // (真机堆栈实证 2026-08-29)。
    if (_creating) {
      throw Exception('播放引擎正在创建中，请稍候重试');
    }
    _creating = true;
    try {
      final engine = await _createEngineInternal(
        url: url,
        httpHeaders: httpHeaders,
        autoPlay: autoPlay,
        forceEngine: forceEngine,
      );
      return engine;
    } finally {
      _creating = false;
    }
  }

  Future<PlayerEngine> _createEngineInternal({
    required String url,
    Map<String, String>? httpHeaders,
    bool autoPlay = true,
    PlayerEngineType? forceEngine,
  }) async {
    // 释放旧引擎
    await disposeEngine();

    final engineType = forceEngine ?? selectEngine(url);
    // 对 Emby/Jellyfin 转码流 URL 补充色彩参数，避免 ExoPlayer 偏绿
    final fixedUrl = _fixEmbyColorParams(url);
    _currentUrl = fixedUrl;
    _currentHeaders = httpHeaders;

    AppLog.i('PlayerManager', '使用 ${engineType.shortLabel} 内核播放');

    _currentEngine = _createEngineInstance(engineType);

    try {
      await _currentEngine!.open(
        url: fixedUrl,
        httpHeaders: httpHeaders,
        autoPlay: autoPlay,
      );
      _engineChangeController.add(engineType);
      return _currentEngine!;
    } catch (e, st) {
      AppLog.e('PlayerManager', '${engineType.shortLabel} 播放失败: $e | 堆栈: $st');

      // 尝试回退到另一个引擎
      if (forceEngine == null && _strategy != EngineSelectStrategy.mpvOnly && _strategy != EngineSelectStrategy.exoOnly) {
        final fallbackType = engineType == PlayerEngineType.mpv
            ? PlayerEngineType.exo
            : PlayerEngineType.mpv;
        AppLog.i('PlayerManager', '回退到 ${fallbackType.shortLabel} 内核');

        await _currentEngine!.dispose();
        _currentEngine = _createEngineInstance(fallbackType);

        try {
          await _currentEngine!.open(
            url: fixedUrl,
            httpHeaders: httpHeaders,
            autoPlay: autoPlay,
          );
          _engineChangeController.add(fallbackType);
          return _currentEngine!;
        } catch (e2, st2) {
          AppLog.e('PlayerManager', '${fallbackType.shortLabel} 回退也失败: $e2', st2);
          rethrow;
        }
      }
      rethrow;
    }
  }

  PlayerEngine _createEngineInstance(PlayerEngineType type) {
    switch (type) {
      case PlayerEngineType.mpv:
        return MpvEngine();
      case PlayerEngineType.exo:
        // Android 平台使用 ExoFFmpegEngine（Media3 + FFmpeg 软解 + HDR）
        // 原生层会自动检测 FFmpeg 可用性，不可用时回退到 Media3 内置解码器
        if (Platform.isAndroid) {
          return ExoFFmpegEngine();
        }
        return ExoPlayerEngine();
      case PlayerEngineType.auto:
        return MpvEngine(); // auto 模式下默认先尝试 MPV
    }
  }

  /// 切换引擎（保持当前播放位置）
  Future<PlayerEngine> switchEngine(PlayerEngineType newType) async {
    if (_currentEngine == null || _currentUrl == null) {
      throw Exception('没有正在播放的媒体');
    }
    if (_currentEngine!.engineType == newType) {
      return _currentEngine!;
    }

    final currentPosition = _currentEngine!.currentState.position;
    final wasPlaying = _currentEngine!.currentState.isPlaying;
    final speed = _currentEngine!.currentState.speed;

    AppLog.i('PlayerManager', '切换内核: ${_currentEngine!.engineType.shortLabel} → ${newType.shortLabel}');

    await _currentEngine!.dispose();
    _currentEngine = _createEngineInstance(newType);

    await _currentEngine!.open(
      url: _currentUrl!,
      httpHeaders: _currentHeaders,
      autoPlay: false,
    );

    // 恢复播放位置和速度
    if (currentPosition > Duration.zero) {
      await _currentEngine!.seek(currentPosition);
    }
    await _currentEngine!.setSpeed(speed);
    
    if (wasPlaying) {
      await _currentEngine!.play();
    }

    _engineChangeController.add(newType);
    return _currentEngine!;
  }

  /// 释放当前引擎
  Future<void> disposeEngine() async {
    await _currentEngine?.dispose();
    _currentEngine = null;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await disposeEngine();
    await _engineChangeController.close();
  }

  /// 从存储加载策略设置
  void loadStrategyFromSettings() {
    final settingsJson = StorageService.getString(StorageService.playerSettingsKey);
    if (settingsJson != null) {
      try {
        final map = StorageService.getJson(StorageService.playerSettingsKey);
        if (map != null) {
          final kernel = map['playerKernel'] as String? ?? 'auto';
          switch (kernel) {
            case 'mpv':
              _strategy = EngineSelectStrategy.mpvOnly;
              break;
            case 'exo':
              _strategy = EngineSelectStrategy.exoOnly;
              break;
            default:
              _strategy = EngineSelectStrategy.auto;
          }
        }
      } catch (_) {}
    }
  }
}

/// Riverpod Provider
final playerManagerProvider = Provider<PlayerManager>((ref) {
  final manager = PlayerManager();
  manager.loadStrategyFromSettings();
  ref.onDispose(() => manager.dispose());
  return manager;
});

/// 当前引擎类型 Provider
final currentEngineTypeProvider = StateProvider<PlayerEngineType>((ref) {
  return PlayerEngineType.mpv;
});
