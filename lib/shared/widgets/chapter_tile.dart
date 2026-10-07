import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import 'glass_card.dart';

/// 章节 / 集数列表为空时的统一文案（用户口径：不要显示残缺空白条目）。
const String kNoChaptersHint = '暂未获取到章节列表';

/// 章节 / 集数列表行：**三个板块共用这一套**（小说 / 漫画的章节、视频的剧集）。
///
/// 真机出过的问题（用户报「章节项被渲染成短小浅白预览条，文字不清晰，也无法
/// 正常点击」）：行内垂直内边距只有 2、标题颜色用的是最浅的 `muted`，再加上
/// 单行截断——整行只有 20 来 pt 高，系统把字体放大后标题直接被卡片裁掉。
///
/// 因此这里的硬性口径：
/// - 行高至少 44pt（iOS 最小触摸目标），字号 14、标题最多两行；
/// - 标题一律用可读色（未读 `textPrimary`、已读 `textSecondary`），**不用**最浅的
///   `muted`——「浅白看不清」正是这么来的；
/// - 右侧统一一个进入箭头（`chevron_right`），让人一眼知道点了会进去；
/// - 已读 / 在读只做「轻微区分」：在读加一条浅色底 + 「在读」标签，已读给一个
///   对勾，都不动标题的字号与对比度。
class ChapterTile extends StatelessWidget {
  const ChapterTile({
    super.key,
    required this.title,
    required this.onTap,
    this.current = false,
    this.read = false,
    this.trailing,
  });

  /// 章节 / 剧集标题（图源给什么显示什么）。
  final String title;

  /// 当前所读 / 所播的那一章。
  final bool current;

  /// 已读过（当前章之后的都不算已读，由调用方判断）。
  final bool read;

  /// 右侧额外内容（如视频的时长、加载中的转圈）；为空时只显示进入箭头。
  final Widget? trailing;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 行与行之间的间隔：挨太近时手指容易点错行，拉开间距比放大文字更管用。
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        color: current ? LumeTheme.accent.withValues(alpha: 0.10) : null,
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                // 两行：长标题（「第一百二十三章 某某某（下）」）不用省略号也能看清。
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.3,
                  color: read && !current
                      ? LumeTheme.textSecondary
                      : LumeTheme.textPrimary,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (current)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '在读',
                  style: TextStyle(fontSize: 11, color: LumeTheme.accent),
                ),
              )
            else if (read)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.done, size: 14, color: LumeTheme.textSecondary),
              ),
            ?trailing,
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: LumeTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
