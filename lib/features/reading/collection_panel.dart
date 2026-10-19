import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/column_list.dart';

import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';

/// 历史与收藏共用的显示和批量操作；存储键由调用方隔离。
class CollectionPanel extends StatefulWidget {
  const CollectionPanel({
    super.key,
    required this.title,
    required this.ids,
    required this.itemBuilder,
    required this.onDelete,
    required this.storageKey,
    this.library,
    this.gridBuilder,
  });
  final String title;
  final List<String> ids;
  final Widget Function(int index) itemBuilder;
  final Widget Function(int index)? gridBuilder;
  final Future<void> Function(Set<String> ids) onDelete;
  final ReadingLibrary? library;
  final String storageKey;
  @override
  State<CollectionPanel> createState() => _CollectionPanelState();
}

class _CollectionPanelState extends State<CollectionPanel> {
  /// 历史 / 收藏只保留三种手机能放下的模式：单列、双列、三列网格。
  ///
  /// 四列 / 五列在手机上标题会被截断（用户口径：砍掉）；旧配置里的 grid2 /
  /// grid4 / grid5 分别并到最接近的受支持档位，不让页面停在不可选的状态。
  static const List<BrowseLayoutMode> _supportedModes = <BrowseLayoutMode>[
    BrowseLayoutMode.list,
    BrowseLayoutMode.list2,
    BrowseLayoutMode.grid3,
  ];

  static BrowseLayoutMode _supportedMode(BrowseLayoutMode? value) =>
      switch (value) {
        BrowseLayoutMode.list2 => BrowseLayoutMode.list2,
        BrowseLayoutMode.grid3 ||
        BrowseLayoutMode.grid4 ||
        BrowseLayoutMode.grid5 => BrowseLayoutMode.grid3,
        BrowseLayoutMode.grid2 => BrowseLayoutMode.list2,
        _ => BrowseLayoutMode.list,
      };

  late BrowseLayoutMode mode = _supportedMode(
    BrowseLayoutMode.fromId(widget.library?.setting(widget.storageKey)),
  );
  bool selecting = false;
  bool busy = false;
  final selected = <String>{};
  Future<void> remove(Set<String> ids) async {
    if (ids.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${widget.title}'),
        content: Text(
          '将删除本板块的 ${ids.length} 条${widget.title}。${widget.title.contains('历史') ? '仅清除记录和进度，保留收藏。' : '仅移出收藏，保留历史和进度。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.onDelete(ids);
      if (mounted) {
        setState(() {
          selected.clear();
          selecting = false;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    selected.retainAll(widget.ids);
    Widget tile(int index) {
      final id = widget.ids[index];
      final child =
          (mode == BrowseLayoutMode.list || mode == BrowseLayoutMode.list2)
          ? widget.itemBuilder(index)
          : (widget.gridBuilder ?? widget.itemBuilder)(index);
      if (!selecting) return child;
      return Stack(
        children: [
          Positioned.fill(child: IgnorePointer(child: child)),
          Positioned.fill(
            child: InkWell(
              onTap: () => setState(() {
                selected.contains(id) ? selected.remove(id) : selected.add(id);
              }),
              child: Align(
                alignment: Alignment.topLeft,
                child: Checkbox(
                  value: selected.contains(id),
                  onChanged: (_) => setState(() {
                    selected.contains(id)
                        ? selected.remove(id)
                        : selected.add(id);
                  }),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return AbsorbPointer(
      absorbing: busy,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                PopupMenuButton<BrowseLayoutMode>(
                  tooltip: '显示模式',
                  initialValue: mode,
                  icon: const LumeIcon(
                    Icons.grid_view_outlined,
                    slot: 'collection_panel.1',
                  ),
                  onSelected: (value) {
                    widget.library?.setSetting(widget.storageKey, value.id);
                    setState(() => mode = value);
                  },
                  itemBuilder: (_) => [
                    for (final value in _supportedModes)
                      CheckedPopupMenuItem(
                        value: value,
                        checked: mode == value,
                        child: Text(value.label),
                      ),
                  ],
                ),
                Expanded(child: Text(mode.label)),
                TextButton(
                  onPressed: widget.ids.isEmpty
                      ? null
                      : () => setState(() {
                          selecting = !selecting;
                          selected.clear();
                        }),
                  child: Text(selecting ? '完成' : '多选'),
                ),
                TextButton(
                  onPressed: widget.ids.isEmpty
                      ? null
                      : () => remove(widget.ids.toSet()),
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          if (selecting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () =>
                        setState(() => selected.addAll(widget.ids)),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => selected.clear()),
                    child: const Text('取消全选'),
                  ),
                  Text('已选 ${selected.length}'),
                  TextButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => remove(Set.of(selected)),
                    child: const Text('删除所选'),
                  ),
                ],
              ),
            ),
          if (busy) const LinearProgressIndicator(),
          Flexible(
            child: widget.ids.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无内容'),
                  )
                : (mode == BrowseLayoutMode.list ||
                      mode == BrowseLayoutMode.list2)
                ? ColumnList(
                    columns: mode == BrowseLayoutMode.list ? 1 : 2,
                    // 双列列表：卡片内容 80 高 + 上下 8 内边距，别留 152 的空格。
                    mainAxisExtent: mode == BrowseLayoutMode.list2 ? 96 : null,
                    itemPadding: const EdgeInsets.symmetric(vertical: 8),
                    shrinkWrap: true,
                    itemCount: widget.ids.length,
                    itemBuilder: (_, index) => SizedBox(
                      height: selecting && mode == BrowseLayoutMode.list
                          ? 104
                          : null,
                      child: tile(index),
                    ),
                  )
                : GridView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: widget.ids.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: mode.columns,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      // 三列卡片：封面 + 两行标题 + 一行进度。按实测内容反推，
                      // 0.52 左右封面最大且文字不被挤掉（不是通用网格的 0.62）。
                      childAspectRatio: .52,
                    ),
                    itemBuilder: (_, index) => tile(index),
                  ),
          ),
        ],
      ),
    );
  }
}
