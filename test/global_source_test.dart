import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/global_source_page.dart';

import 'support/fake_source_manager.dart';

/// 全局图源总管理页的功能验证：一页汇总四个板块、逐个板块执行管理操作。
///
/// 每个板块各用一个替身管理器驱动真实页面；断言不只看界面，还看「操作是否只
/// 落到目标板块的端口上」——板块隔离（宪法第 3 条）在这里有页面级证据。
void main() {
  const novel = Section.novel;
  const comic = Section.comic;
  const cat = Section.cat;

  const novelA = SourceDescriptor(
    id: 'n1',
    name: '小说源A',
    version: '1.0.0',
    enabled: true,
  );
  const novelB = SourceDescriptor(
    id: 'n2',
    name: '小说源B',
    version: '',
    enabled: false,
  );
  const comicA = SourceDescriptor(
    id: 'c1',
    name: '漫画源',
    version: '2.0.0',
    enabled: true,
  );

  Map<Section, FakeSourceManager> fakeManagers({
    Map<Section, List<SourceDescriptor>> sources =
        const <Section, List<SourceDescriptor>>{},
    bool runtimeAvailable = true,
  }) =>
      <Section, FakeSourceManager>{
        for (final section in Section.values)
          section: FakeSourceManager(
            runtimeAvailable: runtimeAvailable,
            sources: sources[section] ?? const <SourceDescriptor>[],
          ),
      };

  Future<void> pumpPage(
    WidgetTester tester,
    Map<Section, FakeSourceManager> managers, {
    Size size = const Size(900, 1400),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: GlobalSourcePage(
          managerFactory: (section) => managers[section]!,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('汇总：四板块分组展示，计数与状态标记正确', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA, novelB],
      comic: const <SourceDescriptor>[comicA],
    });
    await pumpPage(tester, managers);

    // 筛选行：全部 + 每板块「启用 / 总数」。
    expect(find.text('全部 2/3'), findsOneWidget);
    expect(find.text('小说 1/2'), findsOneWidget);
    expect(find.text('漫画 1/1'), findsOneWidget);
    expect(find.text('视频 0/0'), findsOneWidget);
    expect(find.text('猫源 0/0'), findsOneWidget);

    // 分组与条目：名称、版本、停用标记；版本为空时回退项目名。
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('小说源A'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('小说源B'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(find.text(LumeTheme.appName), findsWidgets);
    expect(find.text('漫画源'), findsOneWidget);

    // 没有图源的板块给出空提示。
    expect(find.text('暂无源'), findsNWidgets(2));
  });

  testWidgets('筛选：只显示所选板块的分组', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
      comic: const <SourceDescriptor>[comicA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.text('漫画 1/1'));
    await tester.pumpAndSettle();

    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('小说源A'), findsNothing);
    expect(find.text('小说'), findsNothing);

    // 回到「全部」后小说分组回来。
    await tester.tap(find.text('全部 2/2'));
    await tester.pumpAndSettle();
    expect(find.text('小说源A'), findsOneWidget);
  });

  testWidgets('导入：只写入所选板块，列表随即刷新', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      comic: const <SourceDescriptor>[comicA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入到漫画'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'var LumeSource = {id: "lume.new"};',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(managers[comic]!.imported.single, contains('LumeSource'));
    expect(managers[novel]!.imported, isEmpty);
    expect(managers[cat]!.imported, isEmpty);
    expect(find.text('已导入：新图源（漫画）'), findsOneWidget);
    // 列表与计数一起刷新。
    expect(find.text('新图源'), findsOneWidget);
    expect(find.text('漫画 2/2'), findsOneWidget);
  });

  testWidgets('导入：对话框里可改目标板块', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('导入源'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('猫源')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'var LumeSource = {id:"c"};');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(managers[cat]!.imported.single, contains('LumeSource'));
    expect(managers[novel]!.imported, isEmpty);
    expect(find.text('已导入：新图源（猫源）'), findsOneWidget);
  });

  testWidgets('导入：空脚本被拦下，不写任何板块', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入到小说'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('脚本内容为空'), findsOneWidget);
    for (final manager in managers.values) {
      expect(manager.imported, isEmpty);
    }
  });

  testWidgets('导入失败：提示原因，列表不变', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      comic: const <SourceDescriptor>[comicA],
    });
    managers[comic]!.importFailure = '脚本载入失败：语法错误或运行异常';
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入到漫画'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'var LumeSource = (');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('导入失败：脚本载入失败：语法错误或运行异常'), findsOneWidget);
    expect(find.text('漫画 1/1'), findsOneWidget);
  });

  testWidgets('启停：只写入所属板块，停用后浏览入口禁用', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
      comic: const <SourceDescriptor>[comicA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.text('漫画 1/1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(managers[comic]!.toggled.single, ('c1', false));
    expect(managers[novel]!.toggled, isEmpty);
    expect(find.text('漫画 0/1'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right))
          .onPressed,
      isNull,
    );
  });

  testWidgets('删除：二次确认后只移除所属板块的记录', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
      comic: const <SourceDescriptor>[comicA],
    });
    await pumpPage(tester, managers);

    await tester.tap(find.text('漫画 1/1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(managers[comic]!.removed, isEmpty);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(managers[comic]!.removed.single, 'c1');
    expect(managers[novel]!.removed, isEmpty);
    expect(find.text('暂无源'), findsOneWidget);
  });

  testWidgets('浏览：经所属板块端口打开数据源', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
      comic: const <SourceDescriptor>[comicA],
    });
    managers[comic]!.opened['c1'] = const MockDataSource(section: comic);
    await pumpPage(tester, managers);

    await tester.tap(find.text('漫画 1/1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('浏览'));
    await tester.pumpAndSettle();

    expect(managers[comic]!.openedIds.single, 'c1');
    expect(managers[novel]!.openedIds, isEmpty);
    expect(find.text('漫画 · 漫画模拟源'), findsOneWidget);
  });

  testWidgets('单板块存储故障：只影响该板块，其他板块照常', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      comic: const <SourceDescriptor>[comicA],
    });
    managers[novel]!.listFailure = const SourceException(
      SourceErrorKind.callFailed,
      '板块库打不开',
    );
    await pumpPage(tester, managers);

    expect(find.text('该板块源存储不可用'), findsOneWidget);
    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('漫画 1/1'), findsOneWidget);
  });

  testWidgets('四板块皆空：提示导入并给出入口', (tester) async {
    final managers = fakeManagers();
    await pumpPage(tester, managers);

    expect(find.text('四板块均无源'), findsOneWidget);
    expect(find.text('导入源'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('运行时不可用：只显示骨架，无导入入口', (tester) async {
    final managers = fakeManagers(runtimeAvailable: false);
    await pumpPage(tester, managers);

    expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    for (final manager in managers.values) {
      expect(manager.imported, isEmpty);
    }
  });

  testWidgets('窄屏：条目控件不溢出，超长名称省略', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'n1',
          name: '一个非常长的图源名称用于验证省略号是否生效',
          version: '1.0.0',
          enabled: true,
        ),
      ],
    });
    await pumpPage(tester, managers, size: const Size(390, 844));

    expect(tester.takeException(), isNull);
    expect(find.text('小说 1/1'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.text('一个非常长的图源名称用于验证省略号是否生效'))
          .overflow,
      TextOverflow.ellipsis,
    );
  });

  testWidgets('页面退出：四个板块的管理器一起释放', (tester) async {
    final managers = fakeManagers(sources: <Section, List<SourceDescriptor>>{
      novel: const <SourceDescriptor>[novelA],
    });
    await pumpPage(tester, managers);
    for (final manager in managers.values) {
      expect(manager.closed, isFalse);
    }

    await tester.pumpWidget(const SizedBox());
    for (final manager in managers.values) {
      expect(manager.closed, isTrue);
    }
  });
}
