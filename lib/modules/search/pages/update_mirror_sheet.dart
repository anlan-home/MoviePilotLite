import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:moviepilot_mobile/modules/search/models/update_mirror.dart';
import 'package:moviepilot_mobile/modules/search/services/update_mirror_store.dart';
import 'package:moviepilot_mobile/theme/section.dart';
import 'package:moviepilot_mobile/utils/toast_util.dart';
import 'package:moviepilot_mobile/widgets/section_header.dart';

/// 打开自更新下载线路选择面板。
Future<void> showUpdateMirrorSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const UpdateMirrorSheet(),
  );
}

/// 自更新下载线路选择面板：直连、内置加速源与用户自定义加速源。
class UpdateMirrorSheet extends StatefulWidget {
  const UpdateMirrorSheet({super.key, this.showHeader = true});

  final bool showHeader;

  @override
  State<UpdateMirrorSheet> createState() => _UpdateMirrorSheetState();
}

class _UpdateMirrorSheetState extends State<UpdateMirrorSheet> {
  late final UpdateMirrorStore _store = Get.find<UpdateMirrorStore>();
  final _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
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
            if (selected)
              Icon(
                CupertinoIcons.check_mark_circled_solid,
                size: 20,
                color: colorScheme.primary,
              ),
            if (canDelete)
              CupertinoButton(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
