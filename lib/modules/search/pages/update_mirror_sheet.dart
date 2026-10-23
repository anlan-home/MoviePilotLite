import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:moviepilot_mobile/modules/search/models/update_mirror.dart';
import 'package:moviepilot_mobile/modules/search/services/update_mirror_store.dart';
import 'package:moviepilot_mobile/modules/search/services/update_speed_tester.dart';
import 'package:moviepilot_mobile/theme/section.dart';
import 'package:moviepilot_mobile/utils/toast_util.dart';
import 'package:moviepilot_mobile/widgets/section_header.dart';

/// 打开自更新下载线路选择面板。
///
/// [sourceUrl] 为最新安装包的下载地址；为空时测速退回到仓库归档包。
Future<void> showUpdateMirrorSheet(
  BuildContext context, {
  String sourceUrl = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => UpdateMirrorSheet(sourceUrl: sourceUrl),
  );
}

/// 自更新下载线路选择面板：直连、内置加速源与用户自定义加速源。
class UpdateMirrorSheet extends StatefulWidget {
  const UpdateMirrorSheet({
    super.key,
    this.showHeader = true,
    this.sourceUrl = '',
  });

  final bool showHeader;
  final String sourceUrl;

  @override
  State<UpdateMirrorSheet> createState() => _UpdateMirrorSheetState();
}

class _UpdateMirrorSheetState extends State<UpdateMirrorSheet> {
  late final UpdateMirrorStore _store = Get.find<UpdateMirrorStore>();
  late final UpdateSpeedTester _tester = Get.isRegistered<UpdateSpeedTester>()
      ? Get.find<UpdateSpeedTester>()
      : Get.put(UpdateSpeedTester(), permanent: true);
  final _addController = TextEditingController();

  /// 测速结果按线路 id 缓存，面板重开时仍然可见。
  final Map<String, MirrorSpeedResult> _results = {};
  final Set<String> _testing = {};
  bool _testingAll = false;

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  /// 优先测真实安装包，拿不到地址时退回到仓库归档包。
  String get _probeUrl =>
      widget.sourceUrl.trim().isEmpty
          ? UpdateSpeedTester.fallbackProbeUrl
          : widget.sourceUrl.trim();

  Future<void> _testOne(UpdateMirror mirror) async {
    if (_testing.contains(mirror.id)) return;
    setState(() {
      _testing.add(mirror.id);
      _results.remove(mirror.id);
    });
    final result = await _tester.test(mirror, sourceUrl: _probeUrl);
    if (!mounted) return;
    setState(() {
      _testing.remove(mirror.id);
      _results[mirror.id] = result;
    });
  }

  Future<void> _testAll() async {
    if (_testingAll) return;
    final mirrors = _store.allMirrors;
    setState(() {
      _testingAll = true;
      for (final mirror in mirrors) {
        _testing.add(mirror.id);
        _results.remove(mirror.id);
      }
    });
    final results = await _tester.testAll(mirrors, sourceUrl: _probeUrl);
    if (!mounted) return;
    setState(() {
      _testingAll = false;
      _testing.clear();
      _results.addAll(results);
    });
  }

  /// 按实测速度排序后给出最快线路的提示文案。
  String? get _fastestHint {
    final successful = _results.values.where((result) => result.ok).toList();
    if (successful.length < 2) return null;
    successful.sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
    final fastest = successful.first;
    final mirror = _store.allMirrors.firstWhere(
      (item) => item.id == fastest.mirrorId,
      orElse: () => const UpdateMirror.direct(),
    );
    if (mirror.id == _store.selectedId.value) return null;
    return '当前最快：${mirror.label}（${fastest.displaySpeed}）';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SafeArea(
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: Obx(() {
            final mirrors = _store.allMirrors;
            final selectedId = _store.selectedId.value;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              shrinkWrap: true,
              children: [
                if (widget.showHeader) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '更新下载线路',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.all(6),
                        onPressed: Get.back,
                        child: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          color: colorScheme.onSurfaceVariant,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '国内网络访问 GitHub 较慢时，可选择加速源。加速源失败会自动回退直连。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildSpeedHeader(context),
                  const SizedBox(height: 12),
                ],
                Section(
                  padding: EdgeInsets.zero,
                  margin: const EdgeInsets.only(bottom: 16),
                  header: const SectionHeader(title: '下载线路'),
                  separatorBuilder: (context) => Divider(
                    height: 0.1,
                    indent: 16,
                    endIndent: 16,
                    color: theme.dividerColor,
                  ),
                  children: mirrors
                      .map(
                        (mirror) => _buildMirrorTile(
                          context,
                          mirror: mirror,
                          selected: mirror.id == selectedId,
                        ),
                      )
                      .toList(),
                ),
                _buildAddCard(context),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// 顶部测速入口：一键测全部线路，并给出最快线路提示。
  Widget _buildSpeedHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hint = _fastestHint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _testingAll ? '正在测速…' : '测速可帮你在当前网络下选出最快的线路',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            CupertinoButton(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: colorScheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              onPressed: _testingAll ? null : _testAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_testingAll)
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: colorScheme.primary,
                      ),
                    )
                  else
                    Icon(
                      Icons.speed_rounded,
                      size: 15,
                      color: colorScheme.primary,
                    ),
                  const SizedBox(width: 5),
                  Text(
                    '测速',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(
                  Icons.trending_up_rounded,
                  size: 14,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMirrorTile(
    BuildContext context, {
    required UpdateMirror mirror,
    required bool selected,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final canDelete = !mirror.builtin && !mirror.isDirect;
    return InkWell(
      onTap: () => _store.select(mirror.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(
              mirror.isDirect
                  ? Icons.link_rounded
                  : mirror.builtin
                  ? Icons.bolt_rounded
                  : Icons.tune_rounded,
              size: 20,
              color: selected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mirror.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                    ),
                  ),
                  if (!mirror.isDirect)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        mirror.template,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildSpeedBadge(context, mirror),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  CupertinoIcons.check_mark_circled_solid,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
            if (canDelete)
              CupertinoButton(
                minimumSize: Size.zero,
                padding: const EdgeInsets.only(left: 8),
                onPressed: () => _confirmDelete(context, mirror),
                child: Icon(
                  CupertinoIcons.delete,
                  size: 18,
                  color: colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 测速徽标：未测时显示「测速」，测完显示速度或失败原因，点击可单独重测。
  Widget _buildSpeedBadge(BuildContext context, UpdateMirror mirror) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final testing = _testing.contains(mirror.id);
    final result = _results[mirror.id];

    if (testing) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: colorScheme.primary,
        ),
      );
    }

    final Color foreground;
    final String text;
    if (result == null) {
      foreground = colorScheme.onSurfaceVariant;
      text = '测速';
    } else if (result.ok) {
      foreground = colorScheme.primary;
      text = result.displaySpeed;
    } else {
      foreground = colorScheme.error;
      text = result.error ?? '失败';
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _testOne(mirror),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  Widget _buildAddCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义加速源',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '支持前缀式（如 https://ghproxy.net/）或占位符式（如 https://x/{url}）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _addController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://your-proxy.example/',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: colorScheme.primary,
              onPressed: _addCustom,
              child: Text(
                '保存并使用',
                style: TextStyle(color: colorScheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addCustom() async {
    final raw = _addController.text.trim();
    final error = UpdateMirror.validateTemplate(raw);
    if (error != null) {
      ToastUtil.error(error);
      return;
    }
    final added = await _store.addCustom(raw);
    if (!mounted) return;
    if (added == null) {
      ToastUtil.info('该加速源已存在');
      return;
    }
    _addController.clear();
    ToastUtil.success('已添加并切换到 ${added.label}');
  }

  Future<void> _confirmDelete(
    BuildContext context,
    UpdateMirror mirror,
  ) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('删除加速源'),
        content: Text('确定删除「${mirror.label}」吗？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.removeCustom(mirror.id);
    }
  }
}
