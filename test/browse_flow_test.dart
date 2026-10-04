import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/browse_page.dart';

/// 用模拟实现驱动真实页面，走通「分类 → 列表 → 详情 → 章节 → 阅读器提示」。
///
/// 这是本轮在 Windows 上的功能验证：整条 UI 链路只经过数据源抽象接口，
/// 不需要图源运行时，也不改变非 iOS 平台的 Phase1 骨架行为。
void main() {
  Future<void> pumpBrowse(WidgetTester tester, DataSource source) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: BrowsePage(dataSource: source),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('模拟源驱动整条链路：分类 → 列表 → 详情 → 章节 → 阅读器提示', (tester) async {
    await pumpBrowse(tester, const MockDataSource(section: Section.novel));

    // 标题：板块 · 图源名；分类行：全部 + 图源提供的分类。
    expect(find.text('小说 · 小说模拟源'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('最新 · 模拟条目 1'), findsOneWidget);

    // 切分类后列表走同一个入口重新加载。
    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('玄幻 · 模拟条目 1'), findsOneWidget);

    // 进详情：图源名字与章节数来自接口。
    await tester.tap(find.text('玄幻 · 模拟条目 1'));
    await tester.pumpAndSettle();
    expect(find.text('章节（5）'), findsOneWidget);
    expect(find.text('第 1 章'), findsOneWidget);

    // Phase1 边界：章节点击只提示，不进入阅读器。
    await tester.tap(find.text('第 1 章'));
    await tester.pumpAndSettle();
    expect(find.text('阅读器尚未实现'), findsOneWidget);
  });

  testWidgets('搜索走统一列表入口', (tester) async {
    await pumpBrowse(tester, const MockDataSource(section: Section.comic));

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('搜索 测试 · 模拟条目 1'), findsOneWidget);
  });

  testWidgets('图源失败时页面展示可读错误', (tester) async {
    await pumpBrowse(tester, const MockDataSource(section: Section.cat, fail: true));
    expect(find.text('模拟源被配置为失败'), findsOneWidget);
  });

  testWidgets('不提供分类的图源隐藏分类行', (tester) async {
    await pumpBrowse(tester, const _NoCategorySource());
    expect(find.text('全部'), findsNothing);
    expect(find.text('条目'), findsOneWidget);
  });
}

/// 最小实现：没有分类、只有一条条目。
///
/// 它同时是「分类可缺省」这条契约的对照样例——实现 [DataSource] 不需要
/// 提供分类，页面会自动隐藏分类行。
class _NoCategorySource implements DataSource {
  const _NoCategorySource();

  @override
  String get id => 'lume.test.no-category';

  @override
  String get name => '无分类源';

  @override
  Section get section => Section.novel;

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async =>
      const SourceList(
        items: <SourceItem>[SourceItem(id: 'a', title: '条目')],
      );

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async =>
      null;
}
