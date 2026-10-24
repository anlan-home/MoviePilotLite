import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/player_engine.dart';
import '../../models/player_settings.dart';
import '../../models/media_models.dart';
import '../../utils/app_log.dart';

/// iOS 原生内核：AetherEngine（FFmpeg 拆、Apple 播）。
///
/// 与安卓的 NativeSurfaceEngine 同一套语义：PlatformView 上屏，MethodChannel
/// 控制播放与轨道，EventChannel 回传状态；字幕（文本与 PGS 位图）由原生层
/// 叠加渲染，这里只负责把轨道列表与选择命令转过去。
class AetherIosEngine implements PlayerEngine {
  static const _viewType = 'lanplayer/aether';

  final _stateController = StreamController<PlayerState>.broadcast();
  final _fitNotifier = ValueNotifier<BoxFit>(BoxFit.contain);
  PlayerState _state = const PlayerState(engineType: PlayerEngineType.aether);

  MethodChannel? _channel;
  EventChannel? _events;
  StreamSubscription<dynamic>? _eventSub;
  int? _viewId;
  Map<String, dynamic>? _pendingOpen;
  bool _disposed = false;
  double _speed = 1.0;
  double _volume = 1.0;
  BoxFit _fit = BoxFit.contain;

  @override
  PlayerEngineType get engineType => PlayerEngineType.aether;

  @override
  Stream<PlayerState> get stateStream => _stateController.stream;

  @override
  PlayerState get currentState => _state;

  @override
  Widget buildVideoWidget() {
    return UiKitView(
      viewType: _viewType,
      creationParams: _pendingOpen ?? const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onViewCreated,
    );
  }

  void _onViewCreated(int id) {
    _viewId = id;
    _channel = MethodChannel('lanplayer/aether_$id');
    _events = EventChannel('lanplayer/aether_events_$id');
    _eventSub = _events!.receiveBroadcastStream().listen(_onEvent);
    final pending = _pendingOpen;
    if (pending != null) {
      _pendingOpen = null;
      _channel!.invokeMethod('load', pending);
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final m = Map<String, dynamic>.from(raw);
    final err = (m['error'] ?? '').toString();
    _state = _state.copyWith(
      isPlaying: m['isPlaying'] == true,
      isBuffering: m['isBuffering'] == true,
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      speed: (m['speed'] as num?)?.toDouble() ?? _speed,
      volume: (m['volume'] as num?)?.toDouble() ?? _volume,
      error: err.isEmpty ? null : err,
    );
    if (!_disposed) _stateController.add(_state);
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel?.invokeMethod<void>(method, args);
    } catch (e) {
      AppLog.w('Aether', '$method 失败: $e');
    }
  }

  @override
  Future<void> open({
    required String url,
    Map<String, String>? httpHeaders,
    bool autoPlay = true,
  }) async {
    // Android 侧把 AndroidManifest/请求头交给引擎；这里原样带给原生层。
    final headers = <String, String>{};
    if (httpHeaders != null) headers.addAll(httpHeaders);
    final playUrl = _convertHeadersUri(url, headers);
    final args = <String, dynamic>{
      'url': playUrl,
      'headers': headers,
      'startMs': 0,
      'autoPlay': autoPlay,
    };
    if (_channel == null) {
      _pendingOpen = args;
      return;
    }
    await _invoke('load', args);
  }

  /// MP 宿主对部分地址会用「URL 上的头」写法（headers://），安卓引擎自己解析；
  /// iOS 这边统一还原成裸地址 + 请求头，避免 AVFoundation 拿到伪造 scheme。
  String _convertHeadersUri(String url, Map<String, String> headers) {
    const prefix = 'headers://';
    if (!url.startsWith(prefix)) return url;
    final rest = url.substring(prefix.length);
    final sep = rest.indexOf('|');
    if (sep <= 0) return rest;
    final raw = Uri.decodeComponent(rest.substring(0, sep));
    for (final pair in raw.split('&')) {
      final i = pair.indexOf('=');
      if (i > 0) headers.putIfAbsent(pair.substring(0, i), () => pair.substring(i + 1));
    }
    return Uri.decodeComponent(rest.substring(sep + 1));
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seek(Duration position) =>
      _invoke('seek', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setSpeed(double speed) {
    _speed = speed;
    return _invoke('setSpeed', {'speed': speed});
  }

  @override
  Future<void> setVolume(double volume) {
    _volume = volume;
    return _invoke('setVolume', {'volume': volume});
  }

  @override
  Future<void> stop() async {
    await _invoke('pause');
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    await _invoke('dispose');
    await _stateController.close();
    _fitNotifier.dispose();
  }

  Future<List<Map<String, dynamic>>> _tracks(String key) async {
    try {
      final raw = await _channel?.invokeMethod<dynamic>('getTracks');
      if (raw is Map) {
        final list = raw[key];
        if (list is List) {
          return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
    } catch (e) {
      AppLog.w('Aether', 'getTracks 失败: $e');
    }
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> getAudioTracks() => _tracks('audio');

  @override
  Future<List<Map<String, dynamic>>> getSubtitleTracks() => _tracks('subtitle');

  @override
  Future<void> setAudioTrack(int index) => _invoke('selectAudio', {'index': index});

  @override
  Future<void> setSubtitleTrack(int index) => _invoke('selectSubtitle', {'index': index});

  @override
  Future<void> applySubtitleStyle(PlayerSettings settings) async {
    // 原生叠加层使用默认样式；字号/颜色等后续可扩展到通道参数。
  }

  @override
  Future<bool> loadExternalSubtitle(String path) async {
    // v1 未接外挂文件：服务端字幕由引擎内嵌轨覆盖，本地文件后续再加。
    return false;
  }

  @override
  dynamic get externalSubtitleManager => null;

  @override
  double get videoScale => 1.0;

  @override
  void setVideoScale(double scale) {}

  @override
  BoxFit get fitMode => _fit;

  @override
  ValueNotifier<BoxFit> get fitModeNotifier => _fitNotifier;

  @override
  void setFitMode(BoxFit mode) {
    _fit = mode;
    _fitNotifier.value = mode;
    final name = switch (mode) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
    _invoke('setFit', {'mode': name});
  }

  @override
  Future<Uint8List?> captureFrame() async => null;

  @override
  PlayerEngineCapabilities get capabilities => const PlayerEngineCapabilities(
        supportsFrameCapture: false,
        supportsHardwareDecode: true,
        supportsExternalSubtitle: false,
        supportsTrackSwitching: true,
      );

  /// 供上层判断是否需要服务端字幕下载/配对（iOS 由引擎自己渲染）。
  static bool get selfRenderedSubtitles => true;
}
