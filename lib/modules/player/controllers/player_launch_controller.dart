import 'package:get/get.dart';
import 'package:lanplayer_player/lanplayer_player.dart' as kit;

import '../../../applog/app_log.dart';
import '../../../services/api_client.dart';
import '../../../services/app_service.dart';
import '../../../utils/open_url.dart';
import '../../../utils/toast_util.dart';
import '../../mediaserver/models/mediaserver_model.dart';

/// exists 映射结果:MoviePilot 媒体身份 → 媒体服务器条目
class PlayProbe {
  final String serverName;
  final String itemId;
  final bool isSeries;

  const PlayProbe({
    required this.serverName,
    required this.itemId,
    required this.isSeries,
  });
}

/// 首页「继续观看」卡片携带的续播上下文
class ResumeContext {
  final String itemId;
  final String? serverName;
  final String? serverType;
  final double? percent;
  final String? label;
  final bool isSeries;

  const ResumeContext({
    required this.itemId,
    this.serverName,
    this.serverType,
    this.percent,
    this.label,
    this.isSeries = false,
  });
}

/// 内嵌播放接入层:把 MoviePilot 侧媒体身份映射到媒体服务器条目并拉起播放。
/// 原生播放需要媒体服务器凭据(仅管理员可读系统设置);普通用户回退网页播放。
class PlayerLaunchController extends GetxService {
  PlayerLaunchController._();

  static final PlayerLaunchController to = PlayerLaunchController._();

  final ApiClient _api = Get.find<ApiClient>();
  final AppService _app = Get.find<AppService>();
  final AppLog _log = Get.find<AppLog>();

  List<MediaServer>? _enabledCache;
  final Map<String, Map<String, dynamic>> _rawConfigByName = {};
  DateTime? _cacheAt;
  static const Duration _cacheTtl = Duration(minutes: 5);
  final Map<String, kit.MediaServerService> _serviceCache = {};

  /// 详情页条目上下文缓存,键为媒体标识(如 tmdb:24516)。
  /// 由卡片/浏览入口写入;详情页播放区按自身媒体标识读取,
  /// 不做一次性消费(页面反复进出结果稳定)。
  final Map<String, ResumeContext> resumeContexts = {};

  /// 探测结果缓存,键为 mtype|tmdb|season|title
  final Map<String, PlayProbe?> _probeCache = {};

  ResumeContext? resumeContextFor(String? pathKey) =>
      pathKey == null ? null : resumeContexts[pathKey];

  bool get canNativePlay => _app.isSuperuser;

  /// 所有 kit 交互前必须确保包内存储已初始化
  Future<void> _ensureKit() => kit.LanPlayerKit.ensureInitialized();


  /// 拉取已启用的媒体服务器配置(GET /api/v1/system/setting/MediaServers,
  /// Swagger:仅管理员),带短缓存。
  Future<List<MediaServer>> enabledServers({bool force = false}) async {
    if (!force && _enabledCache != null && _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _cacheTtl) {
      return _enabledCache!;
    }
    final response = await _api.get<dynamic>(
      '/api/v1/system/setting/MediaServers',
    );
    dynamic data = response.data;
    // 兼容三种包装:{success,data:[...]}, {success,data:{value:[...]}}, 直接 [...]
    if (data is Map) {
      final d = data['data'];
      if (d is List) {
        data = d;
      } else if (d is Map && d['value'] is List) {
        data = d['value'];
      }
    }
    if (data is! List) return _empty();
    _rawConfigByName.clear();
    final servers = <MediaServer>[];
    for (final item in data.whereType<Map>()) {
      final raw = Map<String, dynamic>.from(item);
      final server = MediaServer.fromJson(raw);
      if (!server.enabled) continue;
      _rawConfigByName[server.name] =
          raw['config'] is Map ? Map<String, dynamic>.from(raw['config'] as Map) : <String, dynamic>{};
      servers.add(server);
    }
    _enabledCache = servers;
    _cacheAt = DateTime.now();
    return servers;
  }

  List<MediaServer> _empty() {
    _enabledCache = [];
    _cacheAt = DateTime.now();
    return _enabledCache!;
  }

  void invalidateCache() {
    _enabledCache = null;
  }

  /// MP 服务器配置 → kit MediaServer(优先外网播放地址)
  kit.MediaServer? toKitServer(MediaServer s, {bool isDefault = false}) {
    final raw = _rawConfigByName[s.name] ?? const <String, dynamic>{};
    String cfgOf(List<String> keys) {
      for (final k in keys) {
        final v = raw[k]?.toString() ?? '';
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    // MP 服务端的键名是 api_key;兼容 apikey 与 token 变体
    final apiKey = cfgOf(['api_key', 'apikey', 'token']);
    final username = cfgOf(['username', 'user']);
    final password = cfgOf(['password']);
    final playHost = cfgOf(['play_host', 'play_url']);
    final host = cfgOf(['host', 'url']);
    final url = playHost.isNotEmpty ? playHost : host;
    if (url.isEmpty) return null;
    _log.warning(
        'MediaServers[${s.name}] keys=${raw.keys.toList()} hasKey=${apiKey.isNotEmpty}');
    return kit.MediaServer(
      id: s.name,
      name: s.name,
      url: url,
      type: mapKitType(s.type),
      apiKey: apiKey,
      username: username.isEmpty ? null : username,
      password: password.isEmpty ? null : password,
      isDefault: isDefault,
    );
  }

  /// 公开的服务工厂(详情页选集等处使用);内部带缓存与免迁移构造
  kit.MediaServerService? serviceFor(kit.MediaServer server) =>
      _serviceFor(server);

  kit.MediaServerService? _serviceFor(kit.MediaServer server) {
    final cacheKey = '${server.id}_${server.url}_${server.apiKey ?? ''}';
    final cached = _serviceCache[cacheKey];
    if (cached != null) return cached;
    kit.MediaServerService? service;
    switch (server.type) {
      case kit.ServerType.emby:
        service = kit.EmbyService(
          baseUrl: server.url,
          apiKey: server.apiKey ?? '',
          username: server.username,
          password: server.password,
        );
        break;
      case kit.ServerType.jellyfin:
        service = kit.JellyfinService(
          baseUrl: server.url,
          apiKey: server.apiKey ?? '',
          username: server.username,
          password: server.password,
        );
        break;
      case kit.ServerType.fnos:
        // 飞牛需要真实账号密码登录;MP 配置无密码时无法直连
        if ((server.password ?? '').isNotEmpty &&
            (server.username ?? '').isNotEmpty) {
          service = kit.FnOSService(
            baseUrl: server.url,
            username: server.username ?? '',
            password: server.password ?? '',
          );
        }
        break;
      default:
        service = null;
    }
    if (service != null) _serviceCache[cacheKey] = service;
    return service;
  }

  kit.ServerType mapKitType(String type) {
    switch (type.toLowerCase()) {
      case 'jellyfin':
        return kit.ServerType.jellyfin;
      case 'fnos':
        return kit.ServerType.fnos;
      case 'plex':
        return kit.ServerType.plex;
      case 'emby':
      default:
        return kit.ServerType.emby;
    }
  }

  /// exists 映射(GET /api/v1/mediaserver/exists,按 tmdbid/标题/年份)。
  /// 返回命中的服务器名与条目 id;未收录返回 null。
  Future<PlayProbe?> probeExists({
    required String title,
    String? year,
    String? mtype,
    int? tmdbId,
    int? season,
  }) async {
    await _ensureKit();
        final isTv = (mtype ?? '').contains('剧') ||
        (mtype ?? '').toLowerCase().contains('tv');
    final cacheKey = '$mtype|$tmdbId|$season|$title';
    if (_probeCache.containsKey(cacheKey)) {
      return _probeCache[cacheKey];
    }
    final servers = await enabledServers();
    for (final s in servers) {
      final kitServer = toKitServer(s);
      if (kitServer == null) continue;
      final service = _serviceFor(kitServer);
      if (service == null) continue;
      try {
        // 按 TMDB ProviderId 直查媒体服务器(电影/剧集通吃)
        // 仅 Emby/Jellyfin 服务支持(飞牛无密钥认证,已在 _serviceFor 拦截)
        final embyLike = service is kit.EmbyService ? service as kit.EmbyService : null;
        final item = embyLike == null
            ? null
            : await embyLike
                .findItemByTmdb(
                  tmdbId: tmdbId ?? 0,
                  isTv: isTv,
                  title: title,
                )
                .timeout(const Duration(seconds: 12));
        if (item != null && item.id.isNotEmpty) {
          final probe = PlayProbe(
            serverName: s.name,
            itemId: item.id,
            isSeries: isTv || item.type == kit.MediaType.series,
          );
          _probeCache[cacheKey] = probe;
          return probe;
        }
      } catch (e) {
        _log.warning('probeExists[${s.name}] 查询失败: $e');
      }
    }
    _probeCache[cacheKey] = null;
    return null;
  }

  /// 网页播放回退:GET /api/v1/mediaserver/play/{itemid} 取播放页地址
  /// 首页「继续观看 / 最近添加」卡片直连播放(媒体服务器条目 id 已知)。
  /// 剧集自动定位「下一集未看完的」;续播位置由媒体服务器观看进度决定。
  Future<void> playByItemId({
    required String itemId,
    String? serverName,
    String? serverType,
  }) async {
    await _ensureKit();
        final server = await _pickServer(serverName: serverName, serverType: serverType);
    if (server == null) {
      ToastUtil.info('未找到可用的媒体服务器配置');
      return;
    }
    final service = _serviceFor(server);
    if (service == null) {
      ToastUtil.info('媒体服务器配置不完整');
      return;
    }
    try {
      final item = await service.getItemDetails(itemId);
      List<kit.MediaItem>? episodes;
      var targetId = itemId;
      if (item.type == kit.MediaType.series) {
        episodes = await service.getEpisodes(item.id);
        if (episodes.isNotEmpty) {
          final next = episodes.firstWhere(
            (e) => (e.watchProgress ?? 0) < 1,
            orElse: () => episodes!.first,
          );
          targetId = next.id;
        }
      }
      final session = await kit.PlaybackResolver.resolve(
        service: service,
        server: server,
        itemId: targetId,
        episodes: episodes,
      );
      _push(session);
    } catch (e) {
      _log.warning('直接起播失败: $e');
      ToastUtil.error('起播失败,请检查媒体服务器');
    }
  }

  /// 从媒体服务器拉取条目详情(用于反查 TMDB 身份)
  Future<kit.MediaItem?> fetchKitItem({
    required String itemId,
    String? serverName,
    String? serverType,
  }) async {
    final server = await _pickServer(serverName: serverName, serverType: serverType);
    if (server == null) return null;
    final service = _serviceFor(server);
    if (service == null) return null;
    return service.getItemDetails(itemId);
  }

  /// 详情页播放入口(电影直连 / 剧集默认播下一集未看完的)
  Future<void> playProbe({
    required PlayProbe probe,
    bool fromStart = false,
  }) async {
    await _ensureKit();
        final server = await _pickServer(serverName: probe.serverName);
    if (server == null) {
      ToastUtil.info('未找到可用的媒体服务器配置');
      return;
    }
    final service = _serviceFor(server);
    if (service == null) {
      ToastUtil.info('媒体服务器配置不完整');
      return;
    }
    try {
      List<kit.MediaItem>? episodes;
      var targetId = probe.itemId;
      if (probe.isSeries) {
        episodes = await service.getEpisodes(probe.itemId);
        if (episodes.isNotEmpty) {
          // 下一集未看完的:进度为空或 <100% 的第一集
          final next = episodes.firstWhere(
            (e) => (e.watchProgress ?? 0) < 1,
            orElse: () => episodes!.first,
          );
          targetId = next.id;
        }
      }
      final session = await kit.PlaybackResolver.resolve(
        service: service,
        server: server,
        itemId: targetId,
        episodes: episodes,
        // fromStart=true 由「从头看」触发:续播位置清零
      );
      _push(fromStart ? _sessionFromStart(session) : session);
    } catch (e) {
      _log.warning('起播失败: $e');
      ToastUtil.error('起播失败,请检查媒体服务器');
    }
  }

  /// 选集播放(详情页选集弹层 / 浏览详情页)
  Future<void> playEpisodeItem({
    required kit.MediaServerService service,
    required kit.MediaServer server,
    required kit.MediaItem episode,
    List<kit.MediaItem>? episodes,
    bool fromStart = false,
  }) async {
    await _ensureKit();
        try {
      final session = await kit.PlaybackResolver.resolve(
        service: service,
        server: server,
        itemId: episode.id,
        episodes: episodes,
      );
      _push(fromStart ? _sessionFromStart(session) : session);
    } catch (e) {
      _log.warning('选集起播失败: $e');
      ToastUtil.error('起播失败,请检查媒体服务器');
    }
  }

  /// 首页「继续观看」卡片带上下文的播放(续播/从头看)。
  /// 统一走 playByItemId:剧集自动定位「下一集未看完的单集」,
  /// 避免把剧集 ID 直接当单集丢给流接口(Emby 会 500)。
  Future<void> playLatestItem({
    required String itemId,
    String? serverName,
    String? serverType,
    bool fromStart = false,
  }) {
    return playByItemId(
      itemId: itemId,
      serverName: serverName,
      serverType: serverType,
    );
  }

  kit.PlayerSession _sessionFromStart(kit.PlayerSession session) {
    return kit.PlayerSession(
      media: session.media,
      streamUrl: session.streamUrl,
      httpHeaders: session.httpHeaders,
      transcodeUrl: session.transcodeUrl,
      episodes: session.episodes,
      service: session.service,
      server: session.server,
      resumePositionMs: 0,
    );
  }

  Future<void> webPlay(String itemId) async {
    try {
      final response = await _api.get<dynamic>(
        '/api/v1/mediaserver/play/$itemId',
      );
      dynamic data = response.data;
      if (data is Map && data.containsKey('data')) data = data['data'];
      final url = data?.toString() ?? '';
      if (url.isEmpty || !url.startsWith('http')) {
        ToastUtil.info('媒体服务器未收录该影片');
        return;
      }
      await WebUtil.open(url: url);
    } catch (e) {
      _log.warning('网页播放回退失败: $e');
      ToastUtil.error('无法打开播放页');
    }
  }

  Future<kit.MediaServer?> _pickServer({
    String? serverName,
    String? serverType,
  }) async {
    final servers = await enabledServers();
    if (servers.isEmpty) return null;
    MediaServer? picked;
    for (final s in servers) {
      if (serverName != null && serverName.isNotEmpty && s.name == serverName) {
        picked = s;
        break;
      }
      if ((serverType ?? '').isNotEmpty &&
          s.type.toLowerCase() == serverType!.toLowerCase()) {
        picked = s;
        break;
      }
    }
    picked ??= servers.first;
    return toKitServer(picked, isDefault: picked == servers.first);
  }

  void _push(kit.PlayerSession session) {
    Get.toNamed<void>('/player', arguments: session);
  }
}
