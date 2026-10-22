import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:moviepilot_mobile/modules/dashboard/controllers/dashboard_controller.dart';
import 'package:moviepilot_mobile/modules/dashboard/widgets/dashboard_skeletons.dart';
import 'package:moviepilot_mobile/modules/dashboard/widgets/dashboard_widget_styles.dart';
import 'package:moviepilot_mobile/modules/dashboard/widgets/mixed_img_widget.dart';
import 'package:moviepilot_mobile/modules/mediaserver/controllers/mediaserver_controller.dart';
import 'package:moviepilot_mobile/modules/mediaserver/models/library_model.dart';
import 'package:moviepilot_mobile/utils/image_util.dart';

/// 我的媒体库组件
class MyMediaLibraryWidget extends StatelessWidget {
  const MyMediaLibraryWidget({super.key, this.onTap});
  final Function(MediaLibrary library)? onTap;

  Widget _buildInfo(BuildContext context) {
    final mediaServerController = Get.find<MediaServerController>();
    return Obx(() {
      final libraries = mediaServerController.mediaLibraries.value;

      if (libraries.isEmpty) {
        final dashboardController = Get.find<DashboardController>();
        if (dashboardController.isWidgetLoading('我的媒体库')) {
          return const DashboardPosterRailSkeleton();
        }
        return const _EmptyState(
          icon: CupertinoIcons.collections,
          title: '暂无媒体库数据',
          subtitle: '连接媒体服务器后会显示在这里',
        );
      }

      return SizedBox(
        height: 202,
        width: double.infinity,
        child: ListView.separated(
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          scrollDirection: Axis.horizontal,
          shrinkWrap: true,
          itemCount: libraries.length,
          separatorBuilder: (context, index) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final library = libraries[index];
            return SizedBox(
              width: 280,
              child: _LibraryCard(library: library, onTap: onTap),
            );
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _buildInfo(context);
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.library, this.onTap});

  final MediaLibrary library;
  final Function(MediaLibrary library)? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context);

    return Semantics(
      button: true,
      label: '${library.name}，媒体库',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => onTap?.call(library),
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: palette.shadow.withValues(alpha: 0.36),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(color: palette.surfaceAlt),
                  ),
                  _buildLibraryImage(library),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.02),
                          Colors.black.withValues(alpha: 0.06),
                          Colors.black.withValues(alpha: 0.5),
                        ],
                        stops: const [0.0, 0.56, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Row(
                      children: [
                        if (library.type.isNotEmpty)
                          Flexible(
                            child: _GlassPill(
                              text: library.type.toUpperCase(),
                              icon: CupertinoIcons.rectangle_stack_fill,
                            ),
                          ),
                        const Spacer(),
                        if (library.server_type.isNotEmpty)
                          _AccentPill(text: library.server_type.toUpperCase()),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 14,
                    bottom: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                library.name,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  height: 1.12,
                                  color: Colors.white,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              _LibraryMetaLine(library: library),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        _CircleButton(
                          icon: CupertinoIcons.chevron_right,
                          size: 32,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryImage(MediaLibrary library) {
    final imageUrls = library.image_list?.isNotEmpty == true
        ? library.image_list!
        : [library.image ?? ''];
    final normalizedUrls = imageUrls
        .map((e) => ImageUtil.convertInternalImageUrl(e))
        .where((e) => e.trim().isNotEmpty)
        .toList();

    if (normalizedUrls.isEmpty) {
      final palette = DashboardPalette.of(Get.context!);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              palette.surfaceAlt,
              Color.alphaBlend(
                palette.primary.withValues(alpha: 0.16),
                palette.surfaceAlt,
              ),
              Color.alphaBlend(
                palette.coolAccent.withValues(alpha: 0.12),
                palette.surfaceAlt,
              ),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            CupertinoIcons.collections,
            color: Colors.white.withValues(alpha: 0.55),
            size: 40,
          ),
        ),
      );
    }

    return MixedImgWidget(
      imageUrls: normalizedUrls,
      borderRadius: BorderRadius.zero,
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentPill extends StatelessWidget {
  const _AccentPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: palette.warningAccent.withValues(alpha: 0.28),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: palette.warningAccent,
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, this.size = 36});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.48),
    );
  }
}

class _LibraryMetaLine extends StatelessWidget {
  const _LibraryMetaLine({required this.library});

  final MediaLibrary library;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (library.type.isNotEmpty) library.type,
      if (library.server_type.isNotEmpty) library.server_type,
    ].join(' · ');

    if (meta.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        Icon(
          CupertinoIcons.rectangle_stack,
          size: 12,
          color: Colors.white.withValues(alpha: 0.68),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            meta,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.7),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = DashboardPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: palette.tileSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: palette.tileBorder),
              ),
              child: Icon(icon, color: palette.mutedText, size: 22),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: palette.titleText,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(fontSize: 12, color: palette.mutedText),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
