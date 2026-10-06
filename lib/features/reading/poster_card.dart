import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/theme/lume_theme.dart';
import 'section_image.dart';

/// 海报卡：封面 + 标题，书架与探索的网格单元。
///
/// 刻意不用 [GlassCard]：磨砂模糊逐格算在几十张卡的网格里会明显掉帧，
/// 这里用纯白底 + 极浅描边 + 柔和阴影表达同一套分层，代价低得多。
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.badge,
    this.footnote,
  });

  /// 卡片主体（通常是封面图）。
  final Widget child;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右上角角标（漫画书架用它挂未读章节数）。
  final Widget? badge;

  /// 底部补充说明（进度文案等），为空时不占位。
  final Widget? footnote;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LumeTheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: LumeTheme.hairline),
                boxShadow: LumeTheme.cardShadow,
              ),
            ),
            child,
            if (footnote != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Colors.transparent, Color(0xCC000000)],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                    child: footnote,
                  ),
                ),
              ),
            if (badge != null)
              Positioned(top: 6, right: 6, child: badge!),
          ],
        ),
      ),
    );
  }
}

/// 未读章节角标：书架卡片右上角。
///
/// 只表达数量，不做点击——角标是提示，不是入口。数量为 0 时完全不占位。
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  static const Color _unreadColor = Color(0xFFE5484D);

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _unreadColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// 封面图：网格与列表共用，统一按目标宽度解码。
class PosterCover extends StatelessWidget {
  const PosterCover({
    super.key,
    required this.pipeline,
    required this.url,
    this.width = 300,
  });

  final SectionImagePipeline pipeline;

  final String? url;

  /// 解码目标宽度，按卡片实际显示宽度给。
  final int width;

  @override
  Widget build(BuildContext context) => SectionImage(
        pipeline: pipeline,
        url: url ?? '',
        targetWidth: width,
        fit: BoxFit.cover,
      );
}

/// 书架空态卡片（两个板块共用文案结构）。
class ShelfEmptyHint extends StatelessWidget {
  const ShelfEmptyHint({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.collections_bookmark_outlined,
              size: 34,
              color: LumeTheme.muted,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: LumeTheme.muted),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
