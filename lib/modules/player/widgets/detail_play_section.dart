import 'package:flutter/material.dart';
import 'package:lanplayer_player/lanplayer_player.dart' as kit;

import '../../media_detail/models/media_detail_model.dart';
import '../../mediaserver/models/mediaserver_model.dart';
import '../../../utils/toast_util.dart';
import '../controllers/player_launch_controller.dart';
import '../pages/episode_picker_sheet.dart';

/// 详情页播放区(定稿 UI):播放胶囊置于操作行第一顺位,原「搜索资源」
/// 降为圆形次级按钮;剧集追加「☰」选集圆钮;继续观看上下文时按钮文案为
/// 「继续播放」,集数与进度放在下方续播进度行,任何屏宽都不溢出。
/// 命中媒体服务器条目才显示播放入口;未收录(管理员)灰色禁用;非管理员不显示。
class DetailPlaySection extends StatefulWidget {
  final MediaDetail detail;
  final bool isLoading;
  final bool canSearch;
  final bool canSubscribe;
  final bool isSubscribed;
  final bool subscribeLoading;
  final VoidCallback onSearch;
  final VoidCallback onSubscribe;
  final VoidCallback onSubtitleSearch;

  const DetailPlaySection({
    super.key,
    required this.detail,
    required this.isLoading,
    required this.canSearch,
    required this.canSubscribe,
    required this.isSubscribed,
    required this.subscribeLoading,
    required this.onSearch,
    required this.onSubscribe,
    required this.onSubtitleSearch,
  });

  @override
  State<DetailPlaySection> createState() => _DetailPlaySectionState();
}

class _DetailPlaySectionState extends State<DetailPlaySection> {
  bool _probeDone = false;
  PlayProbe? _probe;
  String? _probedTitle;

  /// 实时观看进度(从媒体服务器单条目接口刷新),优先于上下文快照
  double? _livePercent;
  String? _livePercentItemId;

  /// 剧集续播集标签(如 S01E03 · 剧集名),与首页继续观看同源(Emby Resume)
  String? _liveResumeLabel;

  /// 剧集集数统计兜底(如 已看 3/12 集):没有看了一半的单集时显示
  String? _episodeStatsLabel;
  double? _statsValue;

  /// 条目上下文:按详情的媒体标识(tmdb:xxx)从控制器缓存读取,
  /// 非一次性消费——页面反复进出结果一致,首次进入也立即可用
  ResumeContext? get _resume {
    final tmdbId = widget.detail.tmdb_id;
    if (tmdbId == null || tmdbId <= 0) return null;
    return PlayerLaunchController.to.resumeContexts['tmdb:$tmdbId'];
  }

  /// 进度行的真实数据源:实时值优先,退回上下文快照
  double get _resumePercent => _livePercent ?? _resume?.percent ?? 0;

  /// 进度条比例:集数统计模式用「已看集数 / 总集数」,其余用观看百分比
  double get _barValue {
    if (_episodeStatsLabel != null && _liveResumeLabel == null) {
      return (_statsValue ?? 0).clamp(0.0, 1.0);
    }
    return _resumePercent.clamp(0.0, 1.0);
  }

  /// 进度行文案:续播集 > 集数统计 > 上下文快照
  String get _resumeText {
    if (_liveResumeLabel != null) {
      return '$_liveResumeLabel · 已看 ${(_resumePercent * 100).round()}%';
    }
    if (_episodeStatsLabel != null) {
      return _episodeStatsLabel!;
    }
    return '${_resume?.label ?? '上次观看'} · 已看 ${(_resumePercent * 100).round()}%';
  }

  @override
  void initState() {
    super.initState();
    if (PlayerLaunchController.to.canNativePlay) {
      _runProbe();
      _maybeRefreshResumeProgress();
    }
  }

  /// 用条目 ID 拉一次单条目详情(带 UserData),刷新进度显示;
  /// 上下文快照可能来自几分钟前的列表数据,这里保证进度是最新的
  void _maybeRefreshResumeProgress() {
    final resume = _resume;
    if (resume == null) return;
    if (_livePercentItemId == resume.itemId) return;
    _livePercentItemId = resume.itemId;
    _refreshResumeProgress(resume);
  }

  Future<void> _refreshResumeProgress(ResumeContext resume) async {
    try {
      final launch = PlayerLaunchController.to;
      final servers = await launch.enabledServers();
      MediaServer? match;
      for (final s in servers) {
        if (s.name == resume.serverName) {
          match = s;
          break;
        }
      }
      match ??= servers.isNotEmpty ? servers.first : null;
      if (match == null) return;
      final kitServer = launch.toKitServer(match, isDefault: true);
      if (kitServer == null) return;
      final service = launch.serviceFor(kitServer);
      if (service == null) return;
      if (resume.isSeries) {
        await _refreshSeriesProgress(service, resume);
        return;
      }
      final item = await service
          .getItemDetails(resume.itemId)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final progress = item.watchProgress;
      if (progress != null) {
        setState(() => _livePercent = progress);
      }
    } catch (_) {
      // 刷新失败时保留上下文快照值,不影响其他功能
    }
  }

  /// 剧集进度:进度记在单集上,剧集条目本身没有播放位置。
  /// 1) 先查 Emby 续播列表(与首页继续观看同源)找该剧正在看的单集;
  /// 2) 没有看了一半的单集时,退回「已看 A/B 集」集数统计。
  Future<void> _refreshSeriesProgress(
    kit.MediaServerService service,
    ResumeContext resume,
  ) async {
    try {
      final resumeItems = await service
          .getResumeItems(limit: 50)
          .timeout(const Duration(seconds: 12));
      kit.MediaItem? current;
      for (final ep in resumeItems) {
        if (ep.seriesId == resume.itemId && (ep.watchProgress ?? 0) > 0) {
          current = ep;
          break;
        }
      }
      if (current != null) {
        final label = _episodeLabel(current);
        if (!mounted) return;
        setState(() {
          _livePercent = current!.watchProgress;
          _liveResumeLabel = label;
        });
        return;
      }
    } catch (_) {
      // 续播查询失败继续走集数统计
    }
    try {
      final series = await service
          .getItemDetails(resume.itemId)
          .timeout(const Duration(seconds: 10));
      final total = series.totalEpisodes ?? 0;
      if (total <= 0) return;
      final unplayed = (series.unplayedItemCount ?? 0).clamp(0, total);
      final watched = total - unplayed;
      if (!mounted) return;
      setState(() {
        _episodeStatsLabel = '已看 $watched/$total 集';
        _statsValue = watched / total;
      });
    } catch (_) {}
  }

  /// 续播集标签:S01E03 · 剧集名(季集缺失时退回单集名)
  String _episodeLabel(kit.MediaItem ep) {
    final season = ep.seasonNumber ?? 0;
    final number = ep.episodeNumber ?? 0;
    if (season > 0 || number > 0) {
      final code = 'S${season.toString().padLeft(2, '0')}'
          'E${number.toString().padLeft(2, '0')}';
      return ep.title.isNotEmpty ? '$code · ${ep.title}' : code;
    }
    return ep.title;
  }

  @override
  void didUpdateWidget(covariant DetailPlaySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!PlayerLaunchController.to.canNativePlay) return;
    // 详情异步加载:标题就绪(或变化)后重新探测,避免用空标题白探测一次
    final newTitle = widget.detail.title;
    if (newTitle != null && newTitle.isNotEmpty && newTitle != _probedTitle) {
      _runProbe();
    }
    // 详情加载完成后媒体标识(tmdb)才可用,此时才能取上下文并刷新进度
    _maybeRefreshResumeProgress();
  }

  Future<void> _runProbe() async {
    final detail = widget.detail;
    final title = detail.title ?? '';
    if (title.isEmpty) return;
    _probedTitle = title;
    final probe = await PlayerLaunchController.to.probeExists(
      title: title,
      year: detail.year,
      mtype: detail.type,
      tmdbId: detail.tmdb_id,
      season: detail.season,
    );
    if (!mounted) return;
    setState(() {
      _probe = probe;
      _probeDone = true;
    });
  }

  bool get _showPlay =>
      (PlayerLaunchController.to.canNativePlay && _probeDone && _probe != null) ||
      (PlayerLaunchController.to.canNativePlay && _resume != null);

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final children = <Widget>[];

    if (_showPlay) {
      final probe = _probe;
      final hasResume = _resume != null;
      final isSeries = (probe?.isSeries ?? false) ||
          (hasResume && (_resume!.isSeries || (_resume!.percent ?? 0) > 0));
      // 按钮文案跟随实时进度:有进度或集数统计都算「继续播放」
      final hasHistory = _resumePercent > 0 || _episodeStatsLabel != null;
      final pillText = hasResume
          ? (hasHistory
              ? '继续播放'
              : (_resume!.isSeries ? '播放' : '立即播放'))
          : ((probe?.isSeries ?? false) ? '播放' : '立即播放');
      children.add(
        Expanded(
          child: _PillButton(
            icon: Icons.play_arrow_rounded,
            text: pillText,
            onPressed: widget.isLoading
                ? null
                : () {
                    if (hasResume) {
                      PlayerLaunchController.to.playByItemId(
                        itemId: _resume!.itemId,
                        serverName: _resume!.serverName,
                        serverType: _resume!.serverType,
                      );
                      return;
                    }
                    if (probe != null) {
                      PlayerLaunchController.to.playProbe(probe: probe);
                    } else if (_resume != null) {
                      PlayerLaunchController.to.playByItemId(
                        itemId: _resume!.itemId,
                        serverName: _resume!.serverName,
                        serverType: _resume!.serverType,
                      );
                    }
                  },
          ),
        ),
      );
      children.add(const SizedBox(width: 10));
      // 选集入口:上下文或探测确认是剧集时可用
      if ((probe != null && probe.isSeries) ||
          (hasResume && (_resume!.isSeries || (probe == null && _probeDone)))) {
        children.add(_CircleButton(
          icon: Icons.list_rounded,
          tooltip: '选集',
          onPressed: _openEpisodeSheet,
        ));
        children.add(const SizedBox(width: 8));
      }
      if (widget.canSearch) {
        children.add(_CircleButton(
          icon: Icons.search_rounded,
          tooltip: '搜索资源',
          onPressed: widget.onSearch,
        ));
        children.add(const SizedBox(width: 8));
      }
      if (widget.canSubscribe) {
        children.add(_CircleButton(
          icon: widget.subscribeLoading
              ? Icons.sync_rounded
              : (widget.isSubscribed
                  ? Icons.notifications_rounded
                  : Icons.notifications_none_rounded),
          color: widget.isSubscribed ? const Color(0xFFFF6B6B) : Colors.white,
          onPressed: widget.subscribeLoading ? null : widget.onSubscribe,
        ));
        children.add(const SizedBox(width: 8));
      }
      children.add(_CircleButton(
        icon: Icons.chat_bubble_outline_rounded,
        onPressed: widget.onSubtitleSearch,
      ));
    } else if (PlayerLaunchController.to.canNativePlay && _probeDone) {
      // 管理员但媒体服务器未收录:灰色禁用态
      children.add(const Expanded(
        child: _PillButton(
          icon: Icons.play_arrow_rounded,
          text: '媒体库未收录',
          enabled: false,
        ),
      ));
      if (widget.canSearch) {
        children.add(const SizedBox(width: 10));
        children.add(_CircleButton(
          icon: Icons.search_rounded,
          onPressed: widget.onSearch,
        ));
        children.add(const SizedBox(width: 8));
      }
      if (widget.canSubscribe) {
        children.add(_CircleButton(
          icon: widget.isSubscribed
              ? Icons.notifications_rounded
              : Icons.notifications_none_rounded,
          color: widget.isSubscribed ? const Color(0xFFFF6B6B) : Colors.white,
          onPressed: widget.onSubscribe,
        ));
        children.add(const SizedBox(width: 8));
      }
      children.add(_CircleButton(
        icon: Icons.chat_bubble_outline_rounded,
        onPressed: widget.onSubtitleSearch,
      ));
    } else {
      // 原始布局:搜索胶囊 + 圆钮(非管理员/探测中)
      if (widget.canSearch) {
        children.add(Expanded(
          child: _PillButton(
            icon: Icons.search_rounded,
            text: '搜索资源',
            onPressed: widget.isLoading ? null : widget.onSearch,
          ),
        ));
      } else {
        children.add(const Spacer());
      }
      if (widget.canSubscribe) {
        if (widget.canSearch) children.add(const SizedBox(width: 10));
        children.add(_CircleButton(
          icon: widget.subscribeLoading
              ? Icons.sync_rounded
              : (widget.isSubscribed
                  ? Icons.notifications_rounded
                  : Icons.notifications_none_rounded),
          color: widget.isSubscribed ? const Color(0xFFFF6B6B) : Colors.white,
          onPressed: widget.subscribeLoading ? null : widget.onSubscribe,
        ));
      }
      if (widget.canSearch) {
        children.add(const SizedBox(width: 8));
        children.add(_CircleButton(
          icon: Icons.chat_bubble_outline_rounded,
          onPressed: widget.onSubtitleSearch,
        ));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: children),
        if (_showPlay && _resume != null) _buildResumeLine(primary),
      ],
    );
  }

  Widget _buildResumeLine(Color primary) {
    final liveValue = _barValue;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: liveValue.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.white.withOpacity(0.18),
              valueColor: AlwaysStoppedAnimation<Color>(primary),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _resumeText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.75),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  final r = _resume;
                  if (r == null) return;
                  PlayerLaunchController.to.playLatestItem(
                    itemId: r.itemId,
                    serverName: r.serverName,
                    serverType: r.serverType,
                    fromStart: true,
                  );
                },
                child: Text('从头看',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: primary)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openEpisodeSheet() async {
    final launch = PlayerLaunchController.to;
    // 探测未命中时回退用卡片携带的上下文条目 ID(两者至少有一个可用)
    final probe = _probe;
    final resume = _resume;
    if (probe == null && resume == null) {
      ToastUtil.error('选集打开失败: 缺少媒体服务器条目');
      return;
    }
    final serverName = probe?.serverName ?? resume?.serverName ?? '';
    final seriesId = probe?.itemId ?? resume?.itemId ?? '';
    try {
      final servers = await launch.enabledServers();
      MediaServer? match;
      for (final s in servers) {
        if (s.name == serverName) {
          match = s;
          break;
        }
      }
      match ??= servers.isNotEmpty ? servers.first : null;
      final kit.MediaServer? server =
          match == null ? null : launch.toKitServer(match, isDefault: true);
      final service =
          server == null ? null : launch.serviceFor(server);
      if (server == null || service == null) {
        ToastUtil.error('选集打开失败: 媒体服务器配置不完整');
        return;
      }
      final seriesItem = await service
          .getItemDetails(seriesId)
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      await showEpisodePickerSheet(
        context: context,
        service: service,
        server: server,
        series: seriesItem,
        currentSeason: widget.detail.season,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[DetailPlay] 选集打开失败: $e');
      if (mounted) ToastUtil.error('选集打开失败: $e');
    }
  }
}

/// 主题色胶囊主按钮(与原「搜索资源」同规格:48 高、圆角 999)
class _PillButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onPressed;
  final bool enabled;

  const _PillButton({
    required this.icon,
    required this.text,
    this.onPressed,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final enabled = this.enabled && onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.52,
      child: Material(
        color: enabled ? primary : Colors.white24,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形次级按钮(与原订阅/字幕按钮同规格:48 圆、白 14% 底)
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final String? tooltip;

  const _CircleButton({
    required this.icon,
    this.onPressed,
    this.color = Colors.white,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.white.withOpacity(0.14),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: () {
          // ignore: avoid_print
          print('[DetailPlay] circle tapped: $icon');
          onPressed?.call();
        },
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}
