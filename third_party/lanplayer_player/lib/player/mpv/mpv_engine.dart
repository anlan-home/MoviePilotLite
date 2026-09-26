import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import '../core/player_engine.dart';
import '../../models/player_settings.dart';
import '../../services/audio_capability.dart';
import '../../utils/app_log.dart';

/// MPV 播放器引擎实现（基于 media_kit / libmpv）
/// 优势：格式兼容性最强、支持杜比视界/HDR、本地文件播放最佳
class MpvEngine implements PlayerEngine {
  /// 解码兼容模式(TV 逃生门):true=hwdec 走 mediacodec-copy(每帧拷回内存,
  /// 弱芯 TV 上 72MB/s 原生分配 → NativeAlloc GC 2次/秒,全局掉帧);
  /// false=mediacodec 直连(解码帧直达 GPU 纹理)。main_tv 启动时从持久化
  /// 设置注入,TV 设置切换时同步 —— 下次播放生效。手机端不注入(默认
  /// true=copy,行为不变)。
  static bool decodeCompatMode = true;
  late mk.Player _player;
  late VideoController _videoController;

  final StreamController<PlayerState> _stateController = StreamController<PlayerState>.broadcast();
  PlayerState _state = const PlayerState(engineType: PlayerEngineType.mpv);

  StreamSubscription? _playingSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _errorSub;

  /// dispose 后置位：切换内核/换片的瞬间，界面残留的手势回调（双击快进、
  /// 进度条拖动）仍会调到旧引擎，media_kit 对已销毁 Player 直接断言炸出
  /// （真机日志 2026-08-29 实证 3 次 unhandled exception）。防护后静默忽略。
  bool _disposed = false;

  void _guardDisposed() {
    if (_disposed) {
      AppLog.d('MpvEngine', '引擎已销毁，忽略本次调用');
    }
  }

  double _videoScale = 1.0;
  PlayerSettings _subtitleSettings = PlayerSettings.defaults;
  final ValueNotifier<BoxFit> _fitModeNotifier = ValueNotifier(BoxFit.contain);
  final ValueNotifier<Size> _videoSizeNotifier = ValueNotifier(const Size(0, 0));

  @override
  PlayerEngineType get engineType => PlayerEngineType.mpv;

  @override
  Stream<PlayerState> get stateStream => _stateController.stream;

  @override
  PlayerState get currentState => _state;

  @override
  Widget buildVideoWidget() {
    return ClipRect(
      child: ValueListenableBuilder<BoxFit>(
        valueListenable: _fitModeNotifier,
        builder: (context, fit, child) {
          return FittedBox(
            fit: fit,
            child: child,
          );
        },
        child: ValueListenableBuilder<Size>(
          valueListenable: _videoSizeNotifier,
          builder: (context, size, child) {
            return SizedBox(
              width: size.width > 0 ? size.width : 1920,
              height: size.height > 0 ? size.height : 1080,
              child: child,
            );
          },
          // 禁用 media_kit 自带控件（红色进度条、播放状态提示等）
          // 完全由 Flutter UI 控制
          child: Video(
            controller: _videoController,
            controls: null,
          ),
        ),
      ),
    );
  }

  MpvEngine() {
    _init();
  }

  /// 视频流磁盘缓存目录。null 表示还没准备好（此时退回纯内存缓存）。
  String? _cacheDir;

  /// 准备磁盘缓存目录。
  ///
  /// 放在 cache 目录而不是 support 目录：这些是可丢弃的预读数据，系统清理
  /// 缓存时应该能直接删掉，不该跟数据库/配置混在一起。
  Future<String?> _prepareCacheDir() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/mpv_stream_cache');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.path;
    } catch (e) {
      AppLog.w('MpvEngine', '磁盘缓存目录准备失败，退回内存缓存: $e');
      return null;
    }
  }

  void _init() {
    _player = mk.Player();
    _videoController = VideoController(_player);

    Future.microtask(() async {
      _cacheDir = await _prepareCacheDir();
      final platform = _player.platform;
      if (platform != null) {
        try {
          // 视频解码:默认 mediacodec 直连(解码帧直达 GPU 纹理,省掉每帧
          // ~3MB 的解码→内存拷贝 —— TV 真机 2026-09-06 实证 copy 路径的
          // 原生分配把 NativeAlloc GC 逼到 2次/秒,全局掉帧 55.89%);
          // 黑屏/花屏设备用「解码兼容模式」切回 copy
          // iOS:videotoolbox-copy(Apple 平台 copy 路径最稳,直连 interop
          // 在 libmpv 纹理路径上不稳定 —— macOS 同类问题 linplayer 已实证)
          final hwdecValue = Platform.isIOS
              ? 'videotoolbox-copy'
              : (decodeCompatMode ? 'mediacodec-copy' : 'mediacodec');
          await (platform as dynamic).setProperty('hwdec', hwdecValue);
          // ── 弱 GPU 电视渲染降负（用户实测 MPV 内核播放卡顿）──
          // 1080p 片源在 1080p 电视是 1:1 映射,bilinear 与默认 lanczos/
          // spline36 视觉无差,但缩放核开销骤降;关闭抖动消除同样省 GPU。
          await (platform as dynamic).setProperty('scale', 'bilinear');
          await (platform as dynamic).setProperty('cscale', 'bilinear');
          await (platform as dynamic).setProperty('dscale', 'bilinear');
          // 安全加固 · CVE-2026-8461：libavcodec 的 magicyuv 解码器有堆越界写，
          // 构造好的 AVI/MKV/MOV 即可触发崩溃乃至 RCE。修复随 FFmpeg 8.1.2 发布，
          // 但 media_kit 打包的 libmpv 可能仍内置旧版。MagicYUV 是冷门无损录屏
          // 编码，影视/番剧绝不会用到，直接在解码层黑名单掉即可消除攻击面
          // （前缀 '-' 只黑这一个，其余编码仍走自动选择）。
          await (platform as dynamic).setProperty('vd', '-magicyuv');
          // 帧同步：回默认 audio。display-resample 需逐帧计算重采样节奏,
          // 弱 GPU 电视上是掉帧放大器(用户实测 MPV 卡顿的另一来源);
          // 该选项本是高端机的 judder 修正,弱机先保流畅。
          await (platform as dynamic).setProperty('video-sync', 'audio');
          // 音频解码配置：强制使用 FFmpeg 软件解码，支持 TrueHD/DTS-HD 等高端格式
          await (platform as dynamic).setProperty('ad', 'lavc');
          await (platform as dynamic).setProperty('audio-spdif', '');
          // ── 音频输出三件套(linplayer 同款)──
          // ao 固定 audiotrack 优先;TrueHD/DTS-HD 多声道直连出声靠
          // audio-channels=stereo + ad-lavc-downmix(下混成立体声)。
          // 例外:HDMI 环绕声系统检测到时不强制下混,保留原生多声道直出。
          if (Platform.isIOS) {
            // iOS:音频输出走 mpv 默认(avfoundation),Android 专属属性不设置
            AppLog.i('MpvEngine', '音频输出: iOS 默认 avfoundation');
          } else {
            await (platform as dynamic).setProperty('ao', 'audiotrack,opensles');
            final surround = await AudioCapability.hasSurroundOutput();
            await (platform as dynamic)
                .setProperty('audio-channels', surround ? 'auto' : 'stereo');
            await (platform as dynamic)
                .setProperty('ad-lavc-downmix', surround ? 'no' : 'yes');
            AppLog.i('MpvEngine',
                '音频输出: ao=audiotrack,opensles, channels=${surround ? "auto(环绕)" : "stereo(下混)"}');
          }
          // HDR 配置：auto 模式自动检测显示器 HDR 能力
          // - HDR 显示器：直通 HDR10/HLG 信号（tone-mapping=auto）
          // - SDR 显示器：自动 tone-mapping 到 BT.2390
          await (platform as dynamic).setProperty('tone-mapping', 'auto');
          // hdr-compute-peak 必须关。开启后 mpv 会**逐帧扫描像素**重算 HDR 峰值
          // 亮度，表现是画面亮度忽明忽暗（就是"闪"），而且每帧全画面扫描额外吃
          // GPU/CPU，在 Android 盒子上直接加剧掉帧。关掉改用固定峰值，亮度稳定。
          await (platform as dynamic).setProperty('hdr-compute-peak', 'no');
          // 不强制 target-prim/target-trc，让 mpv 根据显示器能力自动选择
          // 如需 SDR 输出可设置: target-prim=bt.709, target-trc=srgb
          await (platform as dynamic).setProperty('target-prim', 'auto');
          await (platform as dynamic).setProperty('target-trc', 'auto');
          // GPU 上下文：Android 上优先 vulkan，回退 opengl
          await (platform as dynamic).setProperty('gpu-context', 'auto');
          // 10bit 色深输出
          // 抖动消除关闭(弱机省 GPU;与 bilinear 缩放配套)
          await (platform as dynamic).setProperty('dither-depth', 'no');
          // 禁用 MPV 自带 OSD 层（进度条、播放状态等由 Flutter UI 控制）
          await (platform as dynamic).setProperty('osd-level', '0');
          await (platform as dynamic).setProperty('osd-bar', 'no');
          await (platform as dynamic).setProperty('osd-playing-msg', '');
          // 默认字幕字号（200 ≈ 视频高度 20%），避免 4K 视频字幕过小
          await (platform as dynamic).setProperty('sub-font-size', '200');
          await (platform as dynamic).setProperty('sub-ass-override', 'force');
          await (platform as dynamic).setProperty('osd-paused-msg', '');
          // 字幕配置：使用默认样式，运行时由 applySubtitleStyle() 动态调整
          await applySubtitleStyle(PlayerSettings.defaults);
          // 确保字幕可见（默认开启）
          await (platform as dynamic).setProperty('sub-visibility', 'yes');
          // ASS/SSA 特效字幕：按原始位置定位
          await (platform as dynamic).setProperty('sub-use-margins', 'no');
          await (platform as dynamic).setProperty('sub-ass-vsfilter-aspect-compat', 'no');
          // ── 网络流媒体缓存（解决 HTTP 流播放掉帧/卡顿）──
          //
          // ⚠️ 改造前这一段有个致命的重复：上方先设了
          //   demuxer-max-bytes = 128MiB / demuxer-max-back-bytes = 32MiB，
          // 这里又设成 512MB / 128MB，后者生效。而 demuxer-max-bytes 是
          // **常驻 RAM** 的解复用队列上限 —— 640MB 常驻内存在 Android 盒子上
          // 就是 OOM 的邀请函，而且上面那两行注释成了永远不生效的谎言。
          //
          // 现在只保留一处定义，并把大缓冲改成**落盘**：cache-on-disk 让 mpv
          // 把预读数据写到磁盘，RAM 里只留一个小窗口。既保住了抗网络抖动的
          // 深度，又不吃内存。
          await (platform as dynamic).setProperty('cache', 'yes');
          await (platform as dynamic).setProperty('cache-on-disk', 'yes');
          if (_cacheDir != null) {
            await (platform as dynamic).setProperty('cache-dir', _cacheDir);
          }
          // RAM 里的解复用队列：前向 64MB / 后向 16MB。够吸收常见网络抖动，
          // 又不会让常驻内存失控。真正的深度靠上面的磁盘缓存。
          await (platform as dynamic).setProperty('demuxer-max-bytes', '67108864');
          await (platform as dynamic).setProperty('demuxer-max-back-bytes', '16777216');
          await (platform as dynamic).setProperty('demuxer-readahead-secs', '60');
          await (platform as dynamic).setProperty('cache-secs', '300');
          await (platform as dynamic).setProperty('demuxer-seekable-cache', 'yes');
          // 缓冲暂停策略：缓冲低于 3 秒时暂停等待（平衡起播速度与流畅度）
          await (platform as dynamic).setProperty('cache-pause', 'yes');
          await (platform as dynamic).setProperty('cache-pause-wait', '3');
          // 起播不等缓冲填满，避免"点了半天不动"
          await (platform as dynamic).setProperty('cache-pause-initial', 'no');
          // 解码线程按 CPU 核数自动，别让单线程解码成为 4K 的瓶颈
          await (platform as dynamic).setProperty('vd-lavc-threads', '0');
          await (platform as dynamic).setProperty('ad-lavc-threads', '0');
          // 网络韧性：让 libavformat 在网络瞬断时透明重连，抖动在缓冲区内消化，
          // 不冒错误、不黑屏。
          //
          // 只开 reconnect_on_network_error，**不开** reconnect_on_http_error ——
          // 服务端 302 签名过期返回的 4xx/5xx 必须冒出来交给上层重新取流，
          // 让 ffmpeg 死磕过期链接的话错误永不上抛，上层反而没机会补救。
          //
          // ⚠️ 不要加 multiple_requests=1。本意是复用连接省握手，但对部分
          // Emby 服务器，libavformat 复用连接发 Range/seek 会灾难性变慢。
          await (platform as dynamic).setProperty(
            'stream-lavf-o',
            'timeout=10000000,reconnect=1,reconnect_streamed=1,'
                'reconnect_on_network_error=1,reconnect_delay_max=30',
          );
          AppLog.i('MpvEngine', 'MPV 配置完成 (HDR auto + 10bit + 磁盘缓存 + 断流重连)');
        } catch (e) {
          AppLog.e('MpvEngine', 'MPV 配置失败: $e');
        }
      }
    });

    _playingSub = _player.stream.playing.listen((playing) {
      _updateState(_state.copyWith(isPlaying: playing));
    });

    _positionSub = _player.stream.position.listen((pos) {
      _updateState(_state.copyWith(position: pos));
    });

    _durationSub = _player.stream.duration.listen((dur) {
      _updateState(_state.copyWith(duration: dur));
    });

    _bufferSub = _player.stream.buffer.listen((buf) {
      _updateState(_state.copyWith(buffer: buf));
    });

    _errorSub = _player.stream.error.listen((err) {
      AppLog.e('MpvEngine', '播放错误: $err');
      _updateState(_state.copyWith(error: err.toString()));
    });

    // 监听视频轨道变化，检测是否有视频流
    _player.stream.tracks.listen((tracks) {
      final videoCount = tracks.video.where((t) => t.id != 'no').length;
      final audioCount = tracks.audio.where((t) => t.id != 'no').length;
      AppLog.i('MpvEngine', '视频轨道数: $videoCount, 音频轨道数: $audioCount');
      if (videoCount == 0) {
        AppLog.w('MpvEngine', '未检测到视频轨道，可能无法显示画面');
      }
      // 更新视频尺寸
      final vw = _player.state.width;
      final vh = _player.state.height;
      if (vw != null && vw > 0 && vh != null && vh > 0) {
        _videoSizeNotifier.value = Size(vw.toDouble(), vh.toDouble());
      }
    });

    // 监听视频尺寸变化
    _player.stream.width.listen((width) {
      final w = width ?? 0;
      final h = _player.state.height ?? 0;
      if (w > 0 && h > 0) {
        _videoSizeNotifier.value = Size(w.toDouble(), h.toDouble());
        AppLog.i('MpvEngine', '视频尺寸: ${w}x$h');
      }
    });
  }

  void _updateState(PlayerState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  @override
  Future<void> open({
    required String url,
    Map<String, String>? httpHeaders,
    bool autoPlay = true,
  }) async {
    _guardDisposed();
    if (_disposed) return;
    try {
      await _player.open(
        mk.Media(url, httpHeaders: httpHeaders ?? {}),
        play: autoPlay,
      );
    } catch (e) {
      AppLog.e('MpvEngine', '打开失败: $e');
      _updateState(_state.copyWith(error: e.toString()));
    }
  }

  @override
  Future<void> play() async {
    _guardDisposed();
    if (_disposed) return;
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _guardDisposed();
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _guardDisposed();
    if (_disposed) return;
    await _player.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _guardDisposed();
    if (_disposed) return;
    await _player.setRate(speed);
    _updateState(_state.copyWith(speed: speed));
  }

  @override
  Future<void> setVolume(double volume) async {
    _guardDisposed();
    if (_disposed) return;
    await _player.setVolume(volume * 100);
    _updateState(_state.copyWith(volume: volume));
  }

  @override
  Future<void> stop() async {
    _guardDisposed();
    if (_disposed) return;
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _playingSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _bufferSub?.cancel();
    await _errorSub?.cancel();
    await _player.dispose();
    await _stateController.close();
  }

  @override
  Future<List<Map<String, dynamic>>> getAudioTracks() async {
    try {
      final tracks = _player.state.tracks;
      // 过滤掉 'no'（禁用）轨道，避免索引错位导致无法正确切换
      return tracks.audio
          .where((t) => t.id != 'no')
          .map((t) => {
                'id': t.id,
                // 不要在这里伪造 '音轨 N'：那个占位串会把 trackDisplayTitle
                // 拼可读名（语言 + 编码 + 声道）的机会挡掉。缺就给空串，
                // 由展示层统一决定怎么兜底。
                'title': t.title ?? '',
                'language': t.language ?? '',
                'codec': t.codec ?? '',
                'channels': t.channels ?? '',
                'bitrate': t.bitrate,
                'audiochannels': t.audiochannels,
                'samplerate': t.samplerate,
                'isDefault': t.isDefault ?? false,
              })
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 位图字幕编解码器集合（PGS/DVDsub/VobSub/DVB 等），这些格式是预渲染图片，
  /// 不支持字号/颜色等样式调整，且部分 MPV 构建可能缺少解码器
  static const _bitmapSubCodecs = {'pgs_sub', 'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'vobsub', 'subrip_bitmap'};

  @override
  Future<List<Map<String, dynamic>>> getSubtitleTracks() async {
    try {
      final tracks = _player.state.tracks;
      final filtered = tracks.subtitle
          .where((t) => t.id != 'no' && t.id != 'auto')
          .toList();
      AppLog.i('MpvEngine', '字幕轨道数: ${filtered.length}');
      for (var i = 0; i < filtered.length; i++) {
        final t = filtered[i];
        AppLog.i(
          'MpvEngine',
          '字幕轨道[$i]: id=${t.id}, title=${t.title ?? ''}, '
          'language=${t.language ?? ''}, codec=${t.codec ?? ''}, '
          'default=${t.isDefault ?? false}',
        );
      }
      return filtered.map((t) {
        final codec = t.codec ?? '';
        final isBitmap = _bitmapSubCodecs.contains(codec.toLowerCase());
        if (isBitmap) {
          AppLog.w('MpvEngine', '检测到字幕轨道 [${t.id}] 为位图格式 ($codec)，可能无法渲染');
        }
        return {
          'id': t.id,
          'title': t.title ?? '',
          'language': t.language ?? '',
          'codec': codec,
          'isDefault': t.isDefault ?? false,
          'isBitmap': isBitmap,
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> setAudioTrack(int index) async {
    try {
      // 与 getAudioTracks 保持一致的过滤，确保索引对齐
      final tracks = _player.state.tracks.audio.where((t) => t.id != 'no').toList();
      if (index >= 0 && index < tracks.length) {
        await _player.setAudioTrack(tracks[index]);
        AppLog.i('MpvEngine', '切换音轨: index=$index, id=${tracks[index].id}');
      }
    } catch (e) {
      AppLog.e('MpvEngine', '切换音轨失败: $e');
    }
  }

  @override
  Future<void> setSubtitleTrack(int index) async {
    try {
      // index == -1 表示关闭字幕
      if (index == -1) {
        await _player.setSubtitleTrack(mk.SubtitleTrack.no());
        AppLog.i('MpvEngine', '字幕已关闭');
        return;
      }
      // 与 getSubtitleTracks 保持一致的过滤，确保索引对齐
      final tracks = _player.state.tracks.subtitle.where((t) => t.id != 'no' && t.id != 'auto').toList();
      if (index >= 0 && index < tracks.length) {
        final track = tracks[index];
        AppLog.i(
          'MpvEngine',
          '准备切换字幕: index=$index, id=${track.id}, title=${track.title ?? ''}, '
          'language=${track.language ?? ''}, codec=${track.codec ?? ''}, '
          'default=${track.isDefault ?? false}',
        );
        await _player.setSubtitleTrack(track);
        AppLog.i('MpvEngine', '字幕切换完成: index=$index, id=${track.id}');

        // MPV 在媒体/字幕轨道加载时可能重置字幕渲染属性。
        // 选轨完成后重新应用用户样式，确保当前 SUBRIP/ASS 轨道字号生效。
        await applySubtitleStyle(_subtitleSettings);
        final platform = _player.platform;
        if (platform != null) {
          await (platform as dynamic).setProperty('sub-visibility', 'yes');
        }
        await _logSubtitleProperties(trackId: track.id, codec: track.codec ?? '');
      }
    } catch (e) {
      AppLog.e('MpvEngine', '切换字幕失败: $e');
    }
  }

  @override
  Future<void> applySubtitleStyle(PlayerSettings s) async {
    _subtitleSettings = s;
    final platform = _player.platform;
    if (platform == null) {
      AppLog.w('MpvEngine', '字幕样式未应用: platform=null');
      return;
    }
    try {
      const fontSize = 200;
      final marginY = (s.subtitleBottomMargin * 100).round();
      AppLog.i(
        'MpvEngine',
        '应用字幕样式: fontSize=$fontSize, scale=${s.subtitleFontSizeScale}, '
        'family=${s.subtitleFontFamily}, bold=${s.subtitleBold}, '
        'borderWidth=${s.subtitleBorderWidth}, marginY=$marginY, '
        'assOverride=${s.subtitleAssOverride ? 'force' : 'no'}',
      );
      // 字号：基准 200（MPV 归一化到 ~1000px 视频高度），通过 sub-scale 用户缩放
      // TV 观看距离远，需要更大字号；200 ≈ 视频高度 20%
      await (platform as dynamic).setProperty('sub-font-size', fontSize.toString());
      await (platform as dynamic).setProperty('sub-scale', s.subtitleFontSizeScale.toString());
      // 字幕延迟（秒，正=延后，负=提前），MPV 原生属性
      if (s.subtitleDelaySeconds != 0) {
        await (platform as dynamic).setProperty('sub-delay', s.subtitleDelaySeconds.toString());
      }
      // 底部边距：视频高度百分比转换为像素（假设视频高度 100 单位）
      await (platform as dynamic).setProperty('sub-margin-y', marginY.toString());
      // 文字颜色与描边
      await (platform as dynamic).setProperty('sub-color', _argbToMpvHex(s.subtitleColor));
      await (platform as dynamic).setProperty('sub-border-color', _argbToMpvHex(s.subtitleBorderColor));
      await (platform as dynamic).setProperty('sub-border-size', s.subtitleBorderWidth.toString());
      // 阴影
      await (platform as dynamic).setProperty('sub-shadow-offset', s.subtitleShadowOffset.toString());
      await (platform as dynamic).setProperty('sub-shadow-color', _argbToMpvHex(s.subtitleShadowColor));
      // 加粗
      await (platform as dynamic).setProperty('sub-bold', s.subtitleBold ? 'yes' : 'no');
      // 字体
      if (s.subtitleFontFamily != 'system') {
        await (platform as dynamic).setProperty('sub-font', s.subtitleFontFamily);
      }
      // ASS/SSA 特效字幕：强制使用 force 统一样式，确保 sub-font-size 对所有字幕类型生效
      // （'no' 模式下 ASS 文件内部样式会覆盖 sub-font-size，导致 TV 上字幕过小）
      await (platform as dynamic).setProperty(
        'sub-ass-override',
        s.subtitleAssOverride ? 'force' : 'no',
      );
      // 原盘(m2ts)选轨偏好：mpv 按蓝光惯例自动选 default/forced 标记轨，
      // alang/slang 给出语言优先序，让 ISO 直连时自动命中用户偏好的音轨/字幕。
      // 对普通文件无副作用——mpv 在无匹配语言时保持默认选择行为。
      if (s.defaultAudioLang?.isNotEmpty == true) {
        await (platform as dynamic).setProperty('alang', s.defaultAudioLang!);
      }
      if (s.defaultSubtitleLang?.isNotEmpty == true) {
        await (platform as dynamic).setProperty('slang', s.defaultSubtitleLang!);
      }
      AppLog.i(
        'MpvEngine',
        '字幕样式应用完成: fontSize=$fontSize, scale=${s.subtitleFontSizeScale}, '
        'effectiveBase=${fontSize * s.subtitleFontSizeScale}',
      );
    } catch (e) {
      AppLog.e('MpvEngine', '应用字幕样式失败: $e');
    }
  }

  Future<void> _logSubtitleProperties({required String trackId, required String codec}) async {
    final platform = _player.platform;
    if (platform == null) return;
    try {
      final native = platform as dynamic;
      final fontSize = await native.getProperty('sub-font-size');
      final scale = await native.getProperty('sub-scale');
      final visibility = await native.getProperty('sub-visibility');
      final marginY = await native.getProperty('sub-margin-y');
      final assOverride = await native.getProperty('sub-ass-override');
      AppLog.i(
        'MpvEngine',
        '字幕样式回读: track=$trackId, codec=$codec, fontSize=$fontSize, '
        'scale=$scale, visibility=$visibility, marginY=$marginY, '
        'assOverride=$assOverride',
      );
    } catch (e) {
      // 某些 media_kit/libmpv 构建不暴露 getProperty；不影响样式设置。
      AppLog.w('MpvEngine', '字幕样式属性回读失败: $e');
    }
  }

  /// ARGB 整数转 MPV 十六进制字符串（#RRGGBBAA 或 #AARRGGBB）
  /// MPV 使用 #AARRGGBB 格式（AA 在前）
  String _argbToMpvHex(int argb) {
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${a.toRadixString(16).padLeft(2, '0')}${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  @override
  Future<bool> loadExternalSubtitle(String path) async {
    final platform = _player.platform;
    if (platform == null) return false;
    try {
      // libmpv sub-add 命令：加载外挂字幕文件
      // 参数：sub-add <filename> [flags] [title] [lang]
      final before = _player.state.tracks.subtitle.map((t) => t.id).toSet();
      await (platform as dynamic).setProperty('sub-files', path);
      AppLog.i('MpvEngine', '加载外挂字幕: $path');
      // sub-add 默认不会切换选中轨（sid=auto 时可能仍显示内嵌轨），
      // 需要显式选中刚添加的外挂轨，否则用户选的服务端字幕不会显示。
      // 轨道列表刷新是异步的，先立刻查一次，查不到则短延时后再查一次。
      List<mk.SubtitleTrack> added = _player.state.tracks.subtitle
          .where((t) => !before.contains(t.id))
          .toList();
      if (added.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 300));
        added = _player.state.tracks.subtitle
            .where((t) => !before.contains(t.id))
            .toList();
      }
      if (added.isNotEmpty) {
        await _player.setSubtitleTrack(added.last);
        AppLog.i('MpvEngine', '已选中外挂字幕轨: id=${added.last.id}');
      } else {
        AppLog.w('MpvEngine', '外挂字幕轨未出现在轨道列表，可能未选中');
      }
      return true;
    } catch (e) {
      AppLog.e('MpvEngine', '加载外挂字幕失败: $e');
      return false;
    }
  }

  @override
  dynamic get externalSubtitleManager => null; // MPV 字幕由原生层渲染，不需要 Flutter 层叠加

  @override
  double get videoScale => _videoScale;

  @override
  void setVideoScale(double scale) {
    _videoScale = scale.clamp(1.0, 2.0);
  }

  @override
  BoxFit get fitMode => _fitModeNotifier.value;

  @override
  ValueNotifier<BoxFit> get fitModeNotifier => _fitModeNotifier;

  @override
  void setFitMode(BoxFit mode) {
    _fitModeNotifier.value = mode;
  }

  // ===== Anime4K GLSL 着色器管理 =====

  /// 当前已加载的着色器文件路径列表
  final List<String> _loadedShaders = [];

  /// 加载 Anime4K 着色器（GLSL 文件路径列表）
  ///
  /// 通过 mpv 的 `glsl-shaders` 属性加载着色器链。
  /// 路径必须是设备上可访问的绝对路径。
  ///
  /// 常用 Anime4K 配置：
  /// - Mode A (高质量): Anime4K_Clamp_Highlights.glsl + Restore_CNN_M.glsl + Upscale_CNN_x2_M.glsl
  /// - Mode B (平衡):   Clamp_Highlights + Restore_CNN_S + Upscale_CNN_x2_S
  /// - Mode C (性能):   Clamp_Highlights + Upscale_Denoise_CNN_x2_S
  Future<bool> loadShaders(List<String> shaderPaths) async {
    try {
      final platform = _player.platform;
      if (platform == null) return false;

      // mpv 使用 : 分隔多个着色器路径（Linux/Android）
      final shaderString = shaderPaths.join(':');

      await (platform as dynamic).setProperty('glsl-shaders', shaderString);
      _loadedShaders
        ..clear()
        ..addAll(shaderPaths);

      AppLog.i('MpvEngine', 'Anime4K 着色器加载成功: ${shaderPaths.length} 个');
      return true;
    } catch (e) {
      AppLog.e('MpvEngine', 'Anime4K 着色器加载失败: $e');
      return false;
    }
  }

  /// 卸载所有着色器（恢复默认渲染）
  Future<void> clearShaders() async {
    try {
      final platform = _player.platform;
      if (platform == null) return;
      await (platform as dynamic).setProperty('glsl-shaders', '');
      _loadedShaders.clear();
      AppLog.i('MpvEngine', '着色器已清除');
    } catch (e) {
      AppLog.e('MpvEngine', '着色器清除失败: $e');
    }
  }

  /// 当前已加载的着色器列表
  List<String> get loadedShaders => List.unmodifiable(_loadedShaders);

  /// 是否有着色器在运行
  bool get hasShaders => _loadedShaders.isNotEmpty;

  /// 设置 mpv 自定义属性（高级用户接口）
  Future<void> setMpvProperty(String key, String value) async {
    try {
      final platform = _player.platform;
      if (platform == null) return;
      await (platform as dynamic).setProperty(key, value);
    } catch (e) {
      AppLog.e('MpvEngine', 'setProperty($key=$value) 失败: $e');
    }
  }

  @override
  Future<Uint8List?> captureFrame() async {
    // media_kit 暂不支持 libmpv 截图命令，能力表声明为不支持，UI 会降级提示
    return null;
  }

  @override
  PlayerEngineCapabilities get capabilities => const PlayerEngineCapabilities(
        supportsFrameCapture: false,
        supportsHardwareDecode: true,
        supportsExternalSubtitle: true,
        supportsTrackSwitching: true,
      );

  /// 获取原始 Player 实例（兼容旧代码）
  mk.Player get rawPlayer => _player;

  /// 获取原始 VideoController 实例
  VideoController get rawController => _videoController;
}
