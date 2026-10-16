import 'package:flutter/material.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/reading/collection_panel.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/shared/widgets/drawer_geometry.dart';
import 'package:lume_box/shared/widgets/column_list.dart';
import 'package:lume_box/features/reading/poster_card.dart';

import '../test/support/fake_source_manager.dart';

// Sample entries rendered by production list widgets. Collection samples are not saved.
void main() => runApp(const ListsPreview());

class ListsPreview extends StatefulWidget {
  const ListsPreview({super.key});
  @override
  State<ListsPreview> createState() => _ListsPreviewState();
}

class _ListsPreviewState extends State<ListsPreview> {
  bool dark = false;
  final sources = [
    for (var i = 0; i < 11; i++)
      SourceDescriptor(
        id: 'preview-$i',
        name: '示例源 $i · 长标题显示检查',
        version: '1.0',
        enabled: true,
      ),
  ];

  Future<void> open(BuildContext context, String title) async {
    var columns = 2;
    await showLumeBottomSheet<void>(
      context: context,
      builder: (context) {
        if (title == '源选择') {
          return SourcePickerSheet(
            section: Section.comic,
            sources: sources,
            currentId: sources.first.id,
            manager: FakeSourceManager(sources: sources),
          );
        }
        return StatefulBuilder(
          builder: (context, setState) => SafeArea(
            top: false,
            child: Column(
              children: [
                ListTile(
                  title: Text(title),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                if (title == '猫源' || title == '猫源内容') ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('单列列表')),
                      ButtonSegment(value: 2, label: Text('双列列表')),
                    ],
                    selected: {columns},
                    onSelectionChanged: (value) =>
                        setState(() => columns = value.first),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: title == '猫源内容'
                        ? ColumnList(
                            columns: columns,
                            itemCount: 11,
                            decorateItems: false,
                            itemPadding: EdgeInsets.zero,
                            itemBuilder: (_, i) => CompactSourceItemTile(
                              uniformList: true,
                              columns: columns,
                              item: SourceItem(
                                id: '$i',
                                title: '猫源内容 $i · 长标题检查',
                              ),
                              onTap: () {},
                            ),
                          )
                        : CatSourceList(
                            columns: columns,
                            shrinkWrap: false,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: [
                              for (var i = 0; i < 11; i++)
                                ListTile(
                                  leading: CircleAvatar(
                                    radius: 14,
                                    child: Text('$i'),
                                  ),
                                  title: Text(
                                    '猫源站点 $i · 长名称',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.more_vert),
                                    constraints: const BoxConstraints.tightFor(
                                      width: 24,
                                      height: 40,
                                    ),
                                    padding: EdgeInsets.zero,
                                    onPressed: () {},
                                  ),
                                ),
                            ],
                          ),
                  ),
                ] else
                  Expanded(
                    child: CollectionPanel(
                      title: title,
                      ids: [for (var i = 0; i < 11; i++) '$i'],
                      storageKey: 'preview.$title',
                      onDelete: (_) async {},
                      itemBuilder: (index) => HistoryEntryTile(
                        item: LibraryItem(
                          section: Section.comic,
                          itemId: '$index',
                          sourceId: 'preview',
                          title: '$title示例 $index · 长标题测试',
                          chapterCount: 10,
                          readChapterIndex: 2,
                          addedAt: DateTime(2026, 10, 17),
                          updatedAt: DateTime(2026, 10, 17),
                        ),
                        progress: null,
                        now: DateTime(2026, 10, 17, 12),
                        onResume: () {},
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: LumeTheme.build(
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: const EdgeInsets.only(bottom: 34),
        viewPadding: const EdgeInsets.only(bottom: 34),
      ),
      child: child ?? const SizedBox.shrink(),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('列表统一预览 · 34px 安全区'),
          actions: [
            IconButton(
              tooltip: '切换亮暗模式',
              icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
              onPressed: () => setState(() => dark = !dark),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final title in ['源选择', '猫源', '猫源内容', '历史', '收藏'])
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilledButton(
                    onPressed: () => open(context, title),
                    child: Text(title),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('历史/收藏：点击“显示模式”切换单列与双列列表。'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
