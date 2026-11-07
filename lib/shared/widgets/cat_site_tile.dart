import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import 'source_card_metrics.dart';

/// 猫源专用极简卡片：没有左侧图标、可选右侧三点菜单，文字单行居中。
///
/// 高度 / 圆角 / 描边与漫画 / 视频的源卡片共用
/// [SourceCardMetrics]：所有源选择卡片统一 55 高、10 圆角、1px 描边。
/// 长名字（例如「日期:20261017」）只允许省略号，不允许折行把卡片撑高；
/// 左右各留 16 的内边距，给省略号一点落点；上下由 [Center] 保持等距呼吸空间。
///
/// 视觉沿用全局卡片的圆角 + 紧凑轻阴影（[SourceCardMetrics.shadow]）。
/// 不透明底色保持卡片阴影清晰。
/// 未选中描边用 [SourceCardMetrics.unselectedBorder]，选中态改用
/// [Theme.primaryColor]（跟随当前主题，而不是写死紫色）。
/// 其它板块的源列表不受这里的尺寸影响。
class CatSiteTile extends StatelessWidget {
  const CatSiteTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.busy = false,
    this.onMore,
    this.moreKey,
    this.height = defaultHeight,
  });

  /// 猫源与其他源选择卡片共用同一高度。
  static const double compactHeight = SourceCardMetrics.height;
  static const double defaultHeight = compactHeight;

  final double height;

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// 源操作进行中：中间显示一个小转圈，仍然保持同样的高度与居中。
  final bool busy;
  final VoidCallback? onMore;
  final Key? moreKey;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? LumeTheme.surfaceAlt : LumeTheme.surface;
    final accent = Theme.of(context).primaryColor;
    final radius = SourceCardMetrics.borderRadius;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        key: const ValueKey('cat-site-card'),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(accent.withValues(alpha: .08), cardColor)
              : cardColor,
          borderRadius: radius,
          border: Border.all(
            color: selected ? accent : SourceCardMetrics.unselectedBorder,
            width: 1,
          ),
          boxShadow: SourceCardMetrics.shadow,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: onMore == null ? 16 : 40,
                  ),
                  child: Center(
                    child: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            children: <Widget>[
                              // Expanded + maxLines 1 + ellipsis：双列再窄也只显示一行，
                              // 绝不换行。textAlign.center 让文字在整行宽度里水平居中。
                              Expanded(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: LumeTheme.textPrimary,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                if (onMore != null)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: IconButton(
                      key: moreKey,
                      tooltip: '$label的更多操作',
                      onPressed: onMore,
                      icon: const Icon(Icons.more_vert, size: 18),
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
