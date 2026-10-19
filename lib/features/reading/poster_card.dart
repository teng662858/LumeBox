import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/missing_cover.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import 'section_image.dart';

/// 全局封面圆角：网格、单列 / 双列列表缩略图统一用这一档。
///
/// 图片和承载它的卡片必须用**同一个**半径，否则去掉文字白底后，图片下方
/// 两角会露出卡片底色，看起来仍然是直角。
const BorderRadius kPosterCoverRadius = BorderRadius.all(Radius.circular(10));

/// 首页三列网格共用的尺寸，避免首页与分类页出现两套间距。
abstract final class ThreeColumnPosterLayout {
  static const double sidePadding = 10;
  static const double spacing = 8;
  static const double rowSpacing = 10;
  static const double titleGap = 4;
  static const double titleSize = 13;
}

/// Shares the current poster margins; cover and row height follow cell width.
abstract final class TwoColumnSourceLayout {
  static const sidePadding = ThreeColumnPosterLayout.sidePadding;
  static const spacing = ThreeColumnPosterLayout.spacing;
  static const rowSpacing = ThreeColumnPosterLayout.rowSpacing;
  static double cellWidth(double width) =>
      (width - sidePadding * 2 - spacing) / 2;
  static double coverWidth(double cellWidth) =>
      (cellWidth * .32).clamp(44.0, 80.0);
  static double coverHeight(double cellWidth) => coverWidth(cellWidth) * 4 / 3;
  static double itemExtent(BuildContext context, double cellWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final textHeight =
        scaler.scale(LumeTypography.bodySize) * 1.25 * 2 +
        scaler.scale(LumeTypography.captionSize) * 1.25 * 2 +
        6;
    final cover = coverHeight(cellWidth);
    return (cover > textHeight ? cover : textHeight) + 16;
  }
}

class TwoColumnSourceItemTile extends StatelessWidget {
  const TwoColumnSourceItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.pipeline,
    this.meta,
  });
  final SourceItem item;
  final VoidCallback onTap;
  final SectionImagePipeline? pipeline;
  final String? meta;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CompactSourceItemTile(
      item: item,
      pipeline: pipeline,
      onTap: onTap,
      meta: meta,
      uniformList: true,
      columns: 2,
      coverWidth: TwoColumnSourceLayout.coverWidth(constraints.maxWidth),
      coverHeight: TwoColumnSourceLayout.coverHeight(constraints.maxWidth),
      showMenu: false,
    ),
  );
}

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
    this.footnoteGap = 6,
    this.footnotePadding = const EdgeInsets.fromLTRB(2, 0, 2, 2),
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
  final double footnoteGap;
  final EdgeInsets footnotePadding;

  @override
  Widget build(BuildContext context) {
    final flat = footnoteBelow && footnote != null;
    return Material(
      // 外置标题的网格卡片**不再铺白底**：文字直接落在页面浅灰底上，
      // 只有封面本身是圆角卡片（用户口径：去掉底部巨大的白色文字底板）。
      color: flat ? Colors.transparent : LumeTheme.surface,
      borderRadius: kPosterCoverRadius,
      clipBehavior: flat ? Clip.none : Clip.antiAlias,
      child: InkWell(
        borderRadius: kPosterCoverRadius,
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
                            borderRadius: kPosterCoverRadius,
                            boxShadow: LumeTheme.cardShadow,
                          ),
                        ),
                        // 外置标题时卡片本身不铺底色，必须在这里单独裁封面：
                        // 否则封面四角（尤其下方两角）会直接顶成直角。
                        ClipRRect(
                          borderRadius: kPosterCoverRadius,
                          child: child,
                        ),
                        if (badge != null)
                          Positioned(top: 6, right: 6, child: badge!),
                      ],
                    ),
                  ),
                  // 图片与文字之间留一小段空白（用户要求）。
                  SizedBox(height: footnoteGap),
                  Padding(padding: footnotePadding, child: footnote),
                ],
              )
            : Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: kPosterCoverRadius,
                      boxShadow: LumeTheme.cardShadow,
                    ),
                  ),
                  // Material 已按同一半径裁剪整张卡；这里再包一层让封面
                  // 的裁切半径与卡片半径显式一致，后续改卡片底色也不会露出直角。
                  ClipRRect(borderRadius: kPosterCoverRadius, child: child),
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
            fontSize: LumeTypography.captionSize,
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
    this.headers = const {},
    this.title = 'LumeBox',
    this.borderRadius = kPosterCoverRadius,
  });

  final SectionImagePipeline pipeline;
  final Map<String, String> headers;

  final String? url;
  final String title;

  /// 解码目标宽度，按卡片实际显示宽度给。
  final int width;

  /// 封面自身圆角；默认与网格卡片共用 10px。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => SectionImage(
    pipeline: pipeline,
    placeholder: MissingCover(title: title, section: pipeline.section),
    url: url ?? '',
    headers: headers,
    targetWidth: width,
    fit: BoxFit.cover,
    borderRadius: borderRadius,
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
            LumeIcon(
              Icons.collections_bookmark_outlined,
              slot: 'poster_card.1',
              size: 34,
              color: LumeTheme.muted,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: LumeTypography.titleSize,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                color: LumeTheme.muted,
              ),
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
    this.horizontal = false,
    this.compactGrid = false,
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;

  /// 额外的元信息行（搜索结果页用它显示时长 / 来源 / 更新时间）。
  final String? meta;
  final bool horizontal;
  final bool compactGrid;

  @override
  Widget build(BuildContext context) {
    if (horizontal) {
      return TwoColumnSourceItemTile(
        item: item,
        pipeline: pipeline,
        onTap: onTap,
        meta: this.meta,
      );
    }
    final meta = this.meta;
    // 标题风格是全局偏好（设置页可切），这里按当前值渲染。
    final style = BrowseLayoutSettings.instance.gridTitleStyle;
    final singleLine = compactGrid && style == GridTitleStyle.below;
    final titleSize = singleLine
        ? ThreeColumnPosterLayout.titleSize
        : LumeTypography.bodySize;
    return PosterCard(
      onTap: onTap,
      // 标题风格：遮罩内置（白字压在封面上）/ 外置独立（黑字在封面下方）。
      // 外置时封面不画任何遮罩，文字落在卡片浅色底上，因此用主题主文字色。
      footnoteBelow: style == GridTitleStyle.below,
      footnoteGap: singleLine ? ThreeColumnPosterLayout.titleGap : 6,
      footnotePadding: singleLine
          ? const EdgeInsets.symmetric(horizontal: 2)
          : const EdgeInsets.fromLTRB(2, 0, 2, 2),
      footnote: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 三列外置标题仅占一行；其他布局保留原有的两行标题。
          SizedBox(
            height: singleLine
                ? MediaQuery.textScalerOf(context).scale(titleSize) * 1.25
                : LumeTypography.bodySize * 1.25 * 2,
            child: Align(
              alignment: Alignment.topLeft,
              child: Text(
                item.title,
                maxLines: singleLine ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                // 内置：压在封面底部的深色遮罩上 → **一律白字 + 加粗 + 浅描边**
                //（原来用 LumeTheme.textPrimary，浅色主题下深色字压深色遮罩，
                //  真机反馈「标题看着很淡」）；外置：封面外的浅色底 → 主题主文字色。
                style: style == GridTitleStyle.below
                    ? TextStyle(
                        fontSize: titleSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      )
                    : const TextStyle(
                        fontSize: LumeTypography.bodySize,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        shadows: <Shadow>[
                          Shadow(color: Color(0xB3000000), blurRadius: 4),
                        ],
                      ),
              ),
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
                  ? TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.captionSize,
                      color: LumeTheme.muted,
                    )
                  : TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.captionSize,
                      color: Colors.white,
                    ),
            ),
          ],
        ],
      ),
      child: CoverThumb(
        title: item.title,
        pipeline: pipeline,
        url: item.cover,
        width: 300,
        headers: item.coverHeaders,
      ),
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
    this.headers = const {},
    this.title = 'LumeBox',
  });

  final SectionImagePipeline? pipeline;
  final String? url;
  final String title;
  final int width;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final pipeline = this.pipeline;
    if (pipeline == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: LumeTheme.fillStrong,
          borderRadius: kPosterCoverRadius,
        ),
        child: LumeIcon(
          Icons.image_outlined,
          slot: 'poster_card.2',
          size: 18,
          color: LumeTheme.muted,
        ),
      );
    }
    return PosterCover(
      pipeline: pipeline,
      url: url,
      title: title,
      width: width,
      headers: headers,
    );
  }
}

/// Two-column list item: horizontal cover and text, independent of grid title style.
class CompactSourceItemTile extends StatelessWidget {
  const CompactSourceItemTile({
    super.key,
    required this.item,
    this.pipeline,
    required this.onTap,
    this.meta,
    this.uniformList = false,
    this.columns = 1,
    this.coverWidth = 60,
    this.coverHeight = 80,
    this.flat = false,
    this.showMenu = true,
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;
  final String? meta;
  final bool uniformList;
  final int columns;

  /// 左侧封面尺寸：双列 60×80，单列 80×100（用户口径：不要像邮票那么小）。
  final double coverWidth;
  final double coverHeight;

  /// 单列列表用 flat：不铺白色卡片，行与行之间靠分隔线，压缩整体高度。
  final bool flat;

  /// 三点菜单只放单列；双列列宽不够（会挤压标题与简介）。
  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = kPosterCoverRadius;
    final subtitle = (meta ?? item.subtitle ?? '').trim();
    final duration = item.duration;
    final cardColor = flat
        ? Colors.transparent
        : uniformList
        ? (columns == 1
              ? Colors.transparent
              : dark
              ? LumeTheme.surfaceAlt
              : const Color(0xFFF7F8FA))
        : LumeTheme.surface;
    return Material(
      color: cardColor,
      borderRadius: radius,
      clipBehavior: flat ? Clip.none : Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: <Widget>[
              SizedBox(
                key: const ValueKey('source-tile-cover'),
                width: coverWidth,
                height: coverHeight,
                child: ClipRRect(
                  borderRadius: kPosterCoverRadius,
                  child: CoverThumb(
                    pipeline: pipeline,
                    url: item.cover,
                    title: item.title,
                    headers: item.coverHeaders,
                    width: (coverWidth * 2.5).round(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: columns > 1
                            ? LumeTypography.bodySize
                            : LumeTypography.titleSize,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                        height: 1.25,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: columns > 1 ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: LumeTypography.captionSize,
                          color: LumeTheme.descriptionColor,
                          height: 1.25,
                        ),
                      ),
                    ],
                    if (duration != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        _clock(duration),
                        maxLines: 1,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: LumeTypography.captionSize,
                          color: LumeTheme.descriptionColor,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showMenu && columns <= 1)
                SizedBox(
                  key: const ValueKey('source-tile-menu'),
                  width: 28,
                  height: 40,
                  child: PopupMenuButton<String>(
                    tooltip: '更多',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: LumeIcon(
                      Icons.more_vert,
                      slot: 'poster_card.3',
                      size: 18,
                      color: LumeTheme.muted,
                    ),
                    onSelected: (value) async {
                      if (value == 'open') {
                        onTap();
                        return;
                      }
                      if (value == 'copy') {
                        await Clipboard.setData(
                          ClipboardData(text: item.title),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(
                          context,
                        )?.showSnackBar(const SnackBar(content: Text('已复制标题')));
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      const PopupMenuItem<String>(
                        value: 'open',
                        child: Text('打开详情'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'copy',
                        child: Text('复制标题'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `12:34` / `1:02:03`：列表里的时长信息（可选能力，没有就不显示）。
String _clock(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
