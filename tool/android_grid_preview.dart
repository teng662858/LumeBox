/// Android layout preview using the production homepage and cover widgets.
/// flutter run -d emulator-5580 -t tool/android_grid_preview.dart
library;

import 'package:flutter/material.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/session/module_ui_scale.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import '../test/support/fake_source_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPreferences.instance.boot();
  // Keep this preview's layout choices in memory; do not overwrite saved settings.
  final pages = <Widget>[];
  for (final section in Section.values) {
    final library = await ReadingLibrary.open(section);
    ModuleUiScale.instance.ensure(section);
    await BrowseLayoutSettings.instance.setMode(
      section,
      BrowseLayoutMode.grid3,
    );
    if (section == Section.cat) {
      pages.add(const CatPage());
      continue;
    }
    final source = _GridPreviewSource(section: section);
    final pipeline = SectionImagePipeline(cacheDir: library.imageCacheDir)
      ..bindSource(source);
    pages.add(
      GlassScaffold(
        title: section.label,
        behindBar: true,
        floatingBar: true,
        mergeHomeHeader: true,
        actions: [
          for (final icon in [
            Icons.history,
            Icons.bookmark_outline,
            Icons.dns_outlined,
            Icons.rss_feed,
          ])
            IconButton(onPressed: () {}, icon: Icon(icon)),
        ],
        child: ExploreView(
          section: section,
          pipeline: pipeline,
          manager: FakeSourceManager(
            sources: [
              SourceDescriptor(
                id: source.id,
                name: '布局演示源',
                version: '1',
                enabled: true,
                section: section,
              ),
            ],
            opened: {source.id: source},
          ),
          showSourceManage: false,
          onOpenItem: (_) {},
        ),
      ),
    );
  }
  await BrowseLayoutSettings.instance.setGridTitleStyle(GridTitleStyle.below);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(
        accent: ThemeAccent.ruby,
        customAccent: const Color(0xFFFF2D55),
      ),
      home: _PreviewTabs(pages: pages),
    ),
  );
}

class _PreviewTabs extends StatefulWidget {
  const _PreviewTabs({required this.pages});
  final List<Widget> pages;

  @override
  State<_PreviewTabs> createState() => _PreviewTabsState();
}

class _PreviewTabsState extends State<_PreviewTabs> {
  int selected = Section.values.indexOf(Section.video);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: selected, children: widget.pages),
    bottomNavigationBar: BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      currentIndex: selected,
      onTap: (value) => setState(() => selected = value),
      items: [
        for (final section in Section.values)
          BottomNavigationBarItem(
            icon: Icon(switch (section) {
              Section.novel => Icons.menu_book,
              Section.comic => Icons.auto_stories_outlined,
              Section.video => Icons.play_circle_outline,
              Section.cat => Icons.pets,
            }),
            label: section.label,
          ),
      ],
    ),
  );
}

class _GridPreviewSource extends MockDataSource
    implements HomeCapable, FilterCapable {
  const _GridPreviewSource({required super.section});

  static const titles = [
    '从金刚功开始肉身成圣',
    '假太监：我乃大明九千岁',
    '苟在武道世界成圣',
    '青山',
    '我在镇妖司里吃妖怪',
    '三界淘宝店',
    '人在美利坚：我的叔叔堂吉诃德',
    '九叔：从末法民国开始攀登仙路',
    '炼气期如履薄冰，元婴期重拳出击',
    '废体少主开局：吞噬万兽成大帝',
    '山海图腾',
    '九天斩神诀',
    '长书名演示：超过一行的文字自动显示省略号',
    '星海旅人',
    '风起时',
  ];

  @override
  Future<bool> supportsHome() async => true;

  @override
  Future<List<SourceCategory>> categories() async => [
    for (final title in ['热门', '动漫', '漫剧', '电影', '国产剧'])
      SourceCategory(id: title, title: title),
  ];

  @override
  Future<bool> supportsFilters() async => true;

  @override
  Future<List<SourceFilterGroup>> filters() async => [
    for (final (id, title, values) in [
      ('type', '类型', ['全部', '电影', 'AI漫剧', '连续剧', '综艺', '动漫']),
      ('area', '地区', ['全部', '大陆', '香港', '台湾', '欧美', '日本']),
      ('year', '年份', ['全部', '2026', '2025', '2024', '2023', '2022']),
      ('sort', '排序', ['全部', '综合', '最新', '高分']),
    ])
      SourceFilterGroup(
        id: id,
        title: title,
        options: [
          for (final value in values)
            SourceFilterOption(id: value, title: value),
        ],
      ),
  ];

  List<SourceItem> get previewItems => [
    for (final (index, title) in titles.indexed)
      SourceItem(id: 'preview-$index', title: title),
  ];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => SourceList(items: previewItems);

  @override
  Future<SourceHome> home() async => SourceHome.parse([
    for (final (index, title) in titles.indexed)
      {'id': 'preview-$index', 'title': title},
  ]);
}
