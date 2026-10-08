import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock.dart';
import 'comic_settings.dart';

/// 「阅读设置」二级页（用户口径）：把**不常用**的选项从底部面板搬到这里，
/// 底部面板只留阅读时真正会随手改的那几项。
///
/// 目前收在这里的：
/// - **双击放大**：开关一次就不再动（多数人一直开着或一直关着）；
/// - **保存本页**：把当前这一页的原图存到本板块的导出目录（长按图片也能存，
///   这里给一个显式入口，避免「不知道能长按」的用户找不到）。
///
/// 页面本身不持存储：改动通过 [onChanged] 立刻写回阅读器的设置（与底部面板
/// 共用同一份 `ComicReaderSettings`），因此在这里改完返回阅读页立即生效。
class ComicReaderSettingsPage extends StatefulWidget {
  const ComicReaderSettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onSavePage,
    this.canSavePage = false,
    this.bookmarkCount = 0,
    this.onOpenBookmarks,
  });

  final ComicReaderSettings settings;
  final ValueChanged<ComicReaderSettings> onChanged;

  /// 这本书当前的书签数（显示用）。
  final int bookmarkCount;

  /// 打开书签列表（顶栏不再放它的入口，挪到这里）。
  final Future<void> Function()? onOpenBookmarks;

  /// 保存当前页（阅读器提供；为 null 时按钮置灰）。
  final Future<void> Function()? onSavePage;

  /// 当前页是否可保存（没图 / 正在保存时为 false）。
  final bool canSavePage;

  @override
  State<ComicReaderSettingsPage> createState() =>
      _ComicReaderSettingsPageState();
}

class _ComicReaderSettingsPageState extends State<ComicReaderSettingsPage> {
  late ComicReaderSettings _settings = widget.settings;

  void _update(ComicReaderSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '阅读设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(
          EdgeInsets.fromLTRB(
            16,
            12,
            16,
            24 + ShellDockScope.bottomInset(context),
          ),
        ),
        children: <Widget>[
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '双击放大',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '双击画面放大到该点，再双击还原。'
                        '（与「点击行为」无关：开着才会响应双击。）',
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _settings.doubleTapZoom,
                  onChanged: (value) =>
                      _update(_settings.copyWith(doubleTapZoom: value)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '保存本页',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '把当前这一页的原图存进本板块的导出目录（不经相册权限）。'
                        '阅读时也可以直接长按图片保存。',
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: widget.canSavePage && widget.onSavePage != null
                      ? () => widget.onSavePage!()
                      : null,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '书签列表',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.bookmarkCount == 0
                            ? '还没有书签：阅读时点顶栏的书签图标就能加。'
                            : '共 ${widget.bookmarkCount} 个书签，点进去可跳页或删除。',
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: widget.onOpenBookmarks == null
                      ? null
                      : () => widget.onOpenBookmarks!(),
                  icon: const Icon(Icons.bookmarks_outlined, size: 18),
                  label: const Text('查看'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 说明面板与这里的分工，避免用户回到面板找不到刚改过的东西。
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              '排版模式、侧边距、页间距、背景、点击行为、翻页方向这些常用项仍在'
              '底部面板（阅读时点一下画面即可呼出）。',
              style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
            ),
          ),
        ],
      ),
    );
  }
}
