import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import 'support/fake_source_manager.dart';

/// 管理界面的功能验证：用替身管理器驱动**真实页面**，走通
/// 列表 → 导入 → 启停 → 删除（含二次确认）→ 浏览 全流程。
///
/// 替身只存在于测试里，生产代码不带任何 Mock 或 Debug 入口；正式实现由
/// `LumeSources.manager(section)` 提供，两者共用同一套页面与同一套端口语义。
/// 因此没有图源运行时的 Windows 上，这套管理流程依然可以被完整验证。
void main() {
  Future<void> pumpPage(WidgetTester tester, SourceManager manager) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceSectionPage(section: Section.novel, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> importScript(WidgetTester tester, String script) async {
    await tester.tap(find.byTooltip('添加图源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), script);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
  }

  bool browseEnabled(WidgetTester tester) =>
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed !=
      null;

  testWidgets('列表：展示图源名称与版本', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '2.0.0', enabled: true),
        SourceDescriptor(id: 'b', name: '停用源', version: '', enabled: false),
      ],
    );
    await pumpPage(tester, manager);

    expect(find.text('示例源'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);
    expect(find.text('停用源'), findsOneWidget);
    // 停用的图源在管理页有明显标记，不只是开关状态。
    expect(find.text('已停用'), findsOneWidget);
    // 版本为空时回退到项目名。
    expect(find.text(LumeTheme.appName), findsWidgets);
  });

  testWidgets('空板块：显示空态与导入入口', (tester) async {
    await pumpPage(tester, FakeSourceManager());

    expect(find.text('暂无图源'), findsOneWidget);
    expect(find.text('点击右上角「+」导入图源脚本'), findsOneWidget);
    expect(find.byTooltip('添加图源'), findsOneWidget);
  });

  testWidgets('导入：成功后刷新列表并提示已导入', (tester) async {
    final manager = FakeSourceManager();
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = {id: "lume.new"};');

    expect(manager.imported.single, contains('LumeSource'));
    expect(find.text('已导入：新图源'), findsOneWidget);
    expect(find.text('新图源'), findsOneWidget);
  });

  testWidgets('导入：同 id 覆盖时提示已更新', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'lume.new', name: '旧名字', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = {id: "lume.new"};');

    expect(find.text('已更新：新图源'), findsOneWidget);
  });

  testWidgets('导入失败：提示具体原因，列表不变', (tester) async {
    final manager = FakeSourceManager()
      ..importFailure = '脚本载入失败：语法错误或运行异常';
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = (');

    expect(find.text('导入失败：脚本载入失败：语法错误或运行异常'), findsOneWidget);
    expect(find.text('暂无图源'), findsOneWidget);
  });

  testWidgets('导入对话框：可载入内置示例脚本', (tester) async {
    await pumpPage(tester, FakeSourceManager());

    await tester.tap(find.byTooltip('添加图源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('载入内置示例'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, contains('LumeSource'));
  });

  testWidgets('启停：写入管理器，停用后浏览入口禁用', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);
    expect(browseEnabled(tester), isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(manager.toggled.single, ('a', false));
    expect(browseEnabled(tester), isFalse);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('删除：取消不删除，确认后连同运行时的记录一起移除', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除图源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.removed, isEmpty);
    expect(find.text('示例源'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(manager.removed.single, 'a');
    expect(find.text('暂无图源'), findsOneWidget);
  });

  testWidgets('浏览：经管理器打开数据源并进入浏览页', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    )..opened['a'] = const MockDataSource(section: Section.novel);
    await pumpPage(tester, manager);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(manager.openedIds.single, 'a');
    expect(find.text('小说 · 小说模拟源'), findsOneWidget);
  });

  testWidgets('运行时不可用：只显示骨架，无导入入口', (tester) async {
    final manager = FakeSourceManager(runtimeAvailable: false);
    await pumpPage(tester, manager);

    expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
    expect(find.byTooltip('添加图源'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets('页面退出：释放板块资源', (tester) async {
    final manager = FakeSourceManager();
    await pumpPage(tester, manager);
    expect(manager.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(manager.closed, isTrue);
  });
}
