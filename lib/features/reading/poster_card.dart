import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
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
    this.footnoteBelow = false,
  });

  /// 卡片主体（通常是封面图）。
  final Widget child;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右上角角标（漫画书架用它挂未读章节数）。
  final Widget? badge;

  /// 底部补充说明（进度文案等），为空时不占位。
  final Widget? footnote;

  /// 说明文字放在**封面之外的正下方**（用户要求的「标题外置」网格风格）：
  /// 封面不再画任何渐变遮罩，标题落在浅色底的卡片上（黑字）。默认 false =
  /// 原有的「遮罩内置」样式。
  final bool footnoteBelow;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LumeTheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: footnoteBelow && footnote != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
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
                        if (badge != null)
                          Positioned(top: 6, right: 6, child: badge!),
                      ],
                    ),
                  ),
                  // 图片与文字之间留一小段空白（用户要求）。
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                    child: footnote,
                  ),
                ],
              )
            : Stack(
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
                    // 真机反馈「卡片底部标题看不清」：原来的遮罩又短又浅
                    //（0xCC），浅色封面上压不住文字。这里把暗色区拉长、加深，
                    // 并在中段补一档，标题那两行始终落在**深底**上。
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: <double>[0.0, 0.45, 1.0],
                      colors: <Color>[
                        Colors.transparent,
                        Color(0x8A000000),
                        Color(0xE6000000),
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 22, 8, 7),
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

/// 海报网格单元：封面 + 标题（底部渐变压字），与书架卡片同一套视觉。
///
/// 三个板块的探索网格与**搜索结果页**共用它：标题风格（内置遮罩 / 外置独立）
/// 是全局偏好，两处必须按同一个口径渲染，否则切了风格会出现两种样子。
class PosterTile extends StatelessWidget {
  const PosterTile({
    super.key,
    required this.item,
    this.pipeline,
    required this.onTap,
    this.meta,
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;

  /// 额外的元信息行（搜索结果页用它显示时长 / 来源 / 更新时间）。
  final String? meta;

  @override
  Widget build(BuildContext context) {
    final meta = this.meta;
    // 标题风格是全局偏好（设置页可切），这里按当前值渲染。
    final style = BrowseLayoutSettings.instance.gridTitleStyle;
    return PosterCard(
      onTap: onTap,
      // 标题风格：遮罩内置（白字压在封面上）/ 外置独立（黑字在封面下方）。
      // 外置时封面不画任何遮罩，文字落在卡片浅色底上，因此用主题主文字色。
      footnoteBelow: style == GridTitleStyle.below,
      footnote: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // 内置：压在封面底部的深色遮罩上 → **一律白字 + 加粗 + 浅描边**
            //（原来用 LumeTheme.textPrimary，浅色主题下深色字压深色遮罩，
            //  真机反馈「标题看着很淡」）；外置：封面外的浅色底 → 主题主文字色。
            style: style == GridTitleStyle.below
                ? TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  )
                : const TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: <Shadow>[
                      Shadow(color: Color(0xB3000000), blurRadius: 4),
                    ],
                  ),
          ),
          if (meta != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 内置：白字降透明度做层级；外置：主题辅助色。
              style: style == GridTitleStyle.below
                  ? TextStyle(fontSize: 10, color: LumeTheme.muted)
                  : TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
            ),
          ],
        ],
      ),
      child: CoverThumb(pipeline: pipeline, url: item.cover, width: 300),
    );
  }
}

/// 小尺寸封面（列表行里用）：没有图片管线时退回占位图标，不让整行看起来空着。
class CoverThumb extends StatelessWidget {
  const CoverThumb({
    super.key,
    required this.pipeline,
    required this.url,
    required this.width,
  });

  final SectionImagePipeline? pipeline;
  final String? url;
  final int width;

  @override
  Widget build(BuildContext context) {
    final pipeline = this.pipeline;
    if (pipeline == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: LumeTheme.fillStrong,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.image_outlined, size: 18, color: LumeTheme.muted),
      );
    }
    return PosterCover(pipeline: pipeline, url: url, width: width);
  }
}
