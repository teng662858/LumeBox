import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    await tester.tap(find.byTooltip('添加源'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), script);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
  }

  /// 打开某行的「更多」菜单。
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
  }


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

  testWidgets('空板块：显示空态与导入入口（含空态里的导入按钮）', (tester) async {
    final manager = FakeSourceManager();
    await pumpPage(tester, manager);

    expect(find.text('暂无源'), findsOneWidget);
    expect(find.text('导入后即可在本板块浏览内容'), findsOneWidget);
    expect(find.byTooltip('添加源'), findsOneWidget);

    // 空态直接给「导入源」按钮：新用户第一步的动作应该能点。
    await tester.tap(find.widgetWithText(FilledButton, '导入源'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '打开的是同一个导入弹窗');

    await tester.enterText(find.byType(TextField), 'var LumeSource = {id: "lume.new"};');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(manager.imported.single, contains('LumeSource'));
  });

  testWidgets('导入：成功后刷新列表并提示已导入', (tester) async {
    final manager = FakeSourceManager();
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = {id: "lume.new"};');

    expect(manager.imported.single, contains('LumeSource'));
    expect(find.text('已导入：新图源'), findsOneWidget);
    expect(find.text('新图源'), findsOneWidget);
  });

  testWidgets('导入：同 id 覆盖时提示已覆盖', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'lume.new', name: '旧名字', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = {id: "lume.new"};');

    expect(find.text('已覆盖：新图源'), findsOneWidget);
  });

  testWidgets('导入失败：提示具体原因，列表不变', (tester) async {
    final manager = FakeSourceManager()
      ..importFailure = '脚本载入失败：语法错误或运行异常';
    await pumpPage(tester, manager);

    await importScript(tester, 'var LumeSource = (');

    // 失败走结果弹窗：逐条列出、可复制，比一闪而过的 Toast 好读。
    expect(
      find.text('导入失败：粘贴 — 脚本载入失败：语法错误或运行异常'),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('暂无源'), findsOneWidget);
  });

  testWidgets('导入对话框：可载入内置示例脚本', (tester) async {
    await pumpPage(tester, FakeSourceManager());

    await tester.tap(find.byTooltip('添加源'));
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

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(manager.toggled.single, ('a', false));
    // 停用后「浏览」不可点：点了也不会打开数据源。
    manager.openedIds.clear();
    await openMenu(tester);
    await tester.tap(find.text('浏览'));
    await tester.pumpAndSettle();
    expect(manager.openedIds, isEmpty, reason: '停用后浏览不可点');
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('删除：取消不删除，确认后连同运行时的记录一起移除', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await openMenu(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.removed, isEmpty);
    expect(find.text('示例源'), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(manager.removed.single, 'a');
    expect(find.text('暂无源'), findsOneWidget);
  });

  testWidgets('浏览：经管理器打开数据源并进入浏览页', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    )..opened['a'] = const MockDataSource(section: Section.novel);
    await pumpPage(tester, manager);

    await openMenu(tester);
    await tester.tap(find.text('浏览'));
    await tester.pumpAndSettle();

    expect(manager.openedIds.single, 'a');
    expect(find.text('小说 · 小说模拟源'), findsOneWidget);
  });

  testWidgets('重命名：弹窗改名并写回管理器，列表随即刷新', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '旧名字', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名源'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(manager.renamed.single, ('a', '新名字'));
    expect(find.text('新名字'), findsOneWidget);
    expect(find.text('旧名字'), findsNothing);
    expect(find.textContaining('已重命名为'), findsOneWidget);
  });

  testWidgets('重命名：空名字不提交，保持原样', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    );
    await pumpPage(tester, manager);

    await openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(manager.renamed, isEmpty);
    expect(find.text('示例源'), findsOneWidget);
  });

  testWidgets('导出：弹窗展示脚本全文，可一键复制', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
      ],
    )..scripts['a'] = "var LumeSource = {id: 'a', name: '示例源'};";
    await pumpPage(tester, manager);

    await openMenu(tester);
    await tester.tap(find.text('导出脚本'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出脚本'), findsWidgets);
    expect(find.textContaining('var LumeSource'), findsOneWidget);
    expect(manager.exportedIds.single, 'a');

    await tester.tap(find.text('复制全文'));
    await tester.pumpAndSettle();
    expect(copied, contains('LumeSource'));
    expect(find.textContaining('已复制'), findsOneWidget);
  });

  testWidgets('运行时不可用：只显示骨架，无导入入口', (tester) async {
    final manager = FakeSourceManager(runtimeAvailable: false);
    await pumpPage(tester, manager);

    expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
    expect(find.byTooltip('添加源'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets('页面退出：释放板块资源', (tester) async {
    final manager = FakeSourceManager();
    await pumpPage(tester, manager);
    expect(manager.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(manager.closed, isTrue);
  });

  // ==========================================================================
  // 图源分组与失效标记（文档「图源导入/导出模块规范」）
  // ==========================================================================

  group('图源分组', () {
    testWidgets('设置分组：写回管理器，列表上显示分组名', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'a', name: '示例源', version: '1.0.0', enabled: true),
        ],
      );
      await pumpPage(tester, manager);

      await openMenu(tester);
      await tester.tap(find.text('设置分组'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '主力');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(manager.groups.single, ('a', '主力'));
      expect(find.text('主力'), findsOneWidget, reason: '列表上要能看出分组');
      expect(find.textContaining('已归入分组'), findsOneWidget);
    });

    testWidgets('取消分组：留空保存即取消', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '示例源',
            version: '1.0.0',
            enabled: true,
            group: '主力',
          ),
        ],
      );
      await pumpPage(tester, manager);
      expect(find.text('主力'), findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text('设置分组'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(manager.groups.single, ('a', ''));
      expect(find.textContaining('已取消'), findsOneWidget);
    });

    testWidgets('已有分组作为快捷选项出现', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '甲源',
            version: '1.0.0',
            enabled: true,
            group: '主力',
          ),
          SourceDescriptor(
            id: 'b',
            name: '乙源',
            version: '1.0.0',
            enabled: true,
            group: '备用',
          ),
          SourceDescriptor(id: 'c', name: '丙源', version: '1.0.0', enabled: true),
        ],
      );
      await pumpPage(tester, manager);

      // 打开丙源（未分组）的菜单：第三行的「更多」。
      await tester.tap(find.byTooltip('更多操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置分组'));
      await tester.pumpAndSettle();

      expect(find.text('已有分组'), findsOneWidget);
      // 两个已有分组都在（快捷 chip）。
      expect(find.widgetWithText(ActionChip, '主力'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '备用'), findsOneWidget);
    });
  });

  group('失效标记', () {
    testWidgets('失效的源在列表上标出「已失效」并给出失败次数', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '坏源',
            version: '1.0.0',
            enabled: true,
            failureCount: 3,
            broken: true,
          ),
        ],
      );
      await pumpPage(tester, manager);

      expect(find.textContaining('已失效'), findsOneWidget);
      expect(find.textContaining('连错 3 次'), findsOneWidget);
    });

    testWidgets('失效的源才有「恢复」菜单项', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '坏源',
            version: '1.0.0',
            enabled: true,
            failureCount: 3,
            broken: true,
          ),
        ],
      );
      await pumpPage(tester, manager);
      await openMenu(tester);
      expect(find.text('恢复（解除失效标记）'), findsOneWidget);
    });

    testWidgets('正常的源没有「恢复」菜单项', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'a', name: '好源', version: '1.0.0', enabled: true),
        ],
      );
      await pumpPage(tester, manager);
      await openMenu(tester);
      expect(find.text('恢复（解除失效标记）'), findsNothing);
    });

    testWidgets('恢复：二次确认后写回管理器，标记消失', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '坏源',
            version: '1.0.0',
            enabled: true,
            failureCount: 3,
            broken: true,
          ),
        ],
      );
      await pumpPage(tester, manager);

      await openMenu(tester);
      await tester.tap(find.text('恢复（解除失效标记）'));
      await tester.pumpAndSettle();

      expect(find.text('恢复源'), findsOneWidget);
      expect(find.textContaining('连续失败 3 次'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '恢复'));
      await tester.pumpAndSettle();

      expect(manager.recoveredIds, <String>['a']);
      expect(find.textContaining('已失效'), findsNothing);
      expect(find.textContaining('已恢复'), findsOneWidget);
    });

    testWidgets('恢复：取消则不写回', (tester) async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '坏源',
            version: '1.0.0',
            enabled: true,
            failureCount: 3,
            broken: true,
          ),
        ],
      );
      await pumpPage(tester, manager);

      await openMenu(tester);
      await tester.tap(find.text('恢复（解除失效标记）'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(manager.recoveredIds, isEmpty);
      expect(find.textContaining('已失效'), findsOneWidget);
    });
  });
}
