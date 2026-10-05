import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/global_source_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import 'support/fake_source_manager.dart';

/// 图源「测试连通性」与「更新订阅源」（文档 Phase1 图源管理 UI 要求：测试图源、
/// 更新订阅源；第 4 条要求图源总管理支持批量操作）。
///
/// 连通性：单源三态（可用 / 无内容 / 不可用）、结论落在列表行上、批量测试只测
/// 已启用的源并给出汇总、测试不改变图源状态（只读）。
/// 订阅更新：只有订阅导入的图源可更新、四种结论各自的提示、批量刷新、失败不吞。
void main() {
  const video = Section.video;

  FakeSourceManager managerWith({
    List<SourceDescriptor> extra = const <SourceDescriptor>[],
    Map<String, SourceTestResult>? results,
  }) {
    final manager = FakeSourceManager(
      sources: <SourceDescriptor>[
        const SourceDescriptor(
          id: 'demo-1',
          name: '示例源',
          version: '1.0.0',
          enabled: true,
        ),
        ...extra,
      ],
      opened: <String, DataSource>{'demo-1': const MockDataSource(section: video)},
    );
    if (results != null) manager.testResults.addAll(results);
    return manager;
  }

  Future<void> pumpManager(WidgetTester tester, FakeSourceManager manager) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceSectionPage(section: video, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMoreMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
  }

  testWidgets('单源测试：可用时给条目数与耗时', (tester) async {
    final manager = managerWith(
      results: <String, SourceTestResult>{
        'demo-1': const SourceTestResult.ok(
          itemCount: 12,
          categoryCount: 3,
          elapsed: Duration(milliseconds: 850),
        ),
      },
    );
    await pumpManager(tester, manager);

    await openMoreMenu(tester);
    await tester.tap(find.text('测试连通性'));
    await tester.pumpAndSettle();

    expect(manager.testedIds, <String>['demo-1']);
    expect(find.textContaining('可用 · 12 条 · 3 个分类'), findsOneWidget);
    // 结论也落在列表行上（不只弹 Toast）。
    expect(find.text('可用'), findsOneWidget);
  });

  testWidgets('单源测试：脚本能跑但没内容时区分「无内容」', (tester) async {
    final manager = managerWith(
      results: <String, SourceTestResult>{
        'demo-1': const SourceTestResult.empty(
          elapsed: Duration(milliseconds: 400),
          message: '脚本能运行，但首屏没有返回任何条目（图源可能已改版）',
        ),
      },
    );
    await pumpManager(tester, manager);

    await openMoreMenu(tester);
    await tester.tap(find.text('测试连通性'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无内容'), findsWidgets);
    expect(find.textContaining('图源可能已改版'), findsOneWidget);
    expect(find.text('无内容'), findsOneWidget, reason: '行内标记');
  });

  testWidgets('单源测试：打不开时给可读原因', (tester) async {
    final manager = managerWith(
      results: <String, SourceTestResult>{
        'demo-1': const SourceTestResult.failed('网络异常：连接超时'),
      },
    );
    await pumpManager(tester, manager);

    await openMoreMenu(tester);
    await tester.tap(find.text('测试连通性'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不可用 · 网络异常：连接超时'), findsOneWidget);
    expect(find.text('不可用'), findsOneWidget, reason: '行内标记');
  });

  testWidgets('批量测试：只测已启用的源，给出汇总', (tester) async {
    final manager = managerWith(
      extra: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'demo-2',
          name: '停用源',
          version: '1.0.0',
          enabled: false,
        ),
      ],
      results: <String, SourceTestResult>{
        'demo-1': const SourceTestResult.ok(
          itemCount: 5,
          categoryCount: 1,
          elapsed: Duration(milliseconds: 300),
        ),
      },
    );
    await pumpManager(tester, manager);

    await tester.tap(find.byTooltip('批量测试连通性'));
    await tester.pumpAndSettle();

    expect(
      manager.testedIds,
      <String>['demo-1'],
      reason: '停用的图源跳过（测试会如实报「已停用」，没意义）',
    );
    expect(find.textContaining('测试完成：可用 1'), findsOneWidget);
  });

  testWidgets('批量测试：混合结论的汇总把三类分开', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'a', name: '好源', version: '1', enabled: true),
        SourceDescriptor(id: 'b', name: '空源', version: '1', enabled: true),
        SourceDescriptor(id: 'c', name: '坏源', version: '1', enabled: true),
      ],
    );
    manager.testResults.addAll(<String, SourceTestResult>{
      'a': const SourceTestResult.ok(
        itemCount: 3,
        categoryCount: 0,
        elapsed: Duration(milliseconds: 100),
      ),
      'b': const SourceTestResult.empty(
        elapsed: Duration(milliseconds: 100),
        message: '首屏为空',
      ),
      'c': const SourceTestResult.failed('脚本载入失败'),
    });
    await pumpManager(tester, manager);

    await tester.tap(find.byTooltip('批量测试连通性'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('可用 1 · 无内容 1 · 不可用 1'),
      findsOneWidget,
    );
  });

  testWidgets('测试是只读的：不改图源状态与当前选择', (tester) async {
    final manager = managerWith();
    await pumpManager(tester, manager);

    await openMoreMenu(tester);
    await tester.tap(find.text('测试连通性'));
    await tester.pumpAndSettle();

    expect(manager.toggled, isEmpty, reason: '测试不得改启停');
    expect(manager.removed, isEmpty);
    expect(manager.renamed, isEmpty);
    expect(manager.selectedIds, isEmpty, reason: '测试不得改当前图源');
    expect(manager.sources.single.enabled, isTrue);
  });

  testWidgets('图源总管理：批量测试跨四个板块', (tester) async {
    // 总管理页每个板块各造一个管理器，验证它按板块逐个测。
    final managers = <Section, FakeSourceManager>{
      for (final section in Section.values)
        section: FakeSourceManager(
          sources: <SourceDescriptor>[
            SourceDescriptor(
              id: 'src-${section.id}',
              name: '${section.label}源',
              version: '1.0.0',
              enabled: true,
            ),
          ],
        ),
    };

    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: GlobalSourcePage(managerFactory: (section) => managers[section]!),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('批量测试连通性'));
    await tester.pumpAndSettle();

    for (final section in Section.values) {
      expect(
        managers[section]!.testedIds,
        <String>['src-${section.id}'],
        reason: '${section.label} 板块的图源应当被测到',
      );
    }
    expect(find.textContaining('测试完成（4 个）'), findsOneWidget);
  });

  group('更新订阅源', () {
    FakeSourceManager subscribedManager({
      Map<String, SourceUpdateResult>? results,
    }) {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'sub-1',
            name: '订阅源',
            version: '1.0.0',
            enabled: true,
            originUrl: 'https://example.com/sub.js',
          ),
          SourceDescriptor(
            id: 'local-1',
            name: '本地源',
            version: '1.0.0',
            enabled: true,
          ),
        ],
      );
      if (results != null) manager.updateResults.addAll(results);
      return manager;
    }

    testWidgets('订阅源：行内标「订阅」，「更新订阅源」可用', (tester) async {
      final manager = subscribedManager(
        results: <String, SourceUpdateResult>{
          'sub-1': const SourceUpdateResult.updated(
            SourceDescriptor(
              id: 'sub-1',
              name: '订阅源',
              version: '2.0.0',
              enabled: true,
            ),
          ),
        },
      );
      await pumpManager(tester, manager);

      expect(find.text('订阅'), findsOneWidget, reason: '只有订阅导入的源带这个标记');

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新订阅源'));
      await tester.pumpAndSettle();

      expect(manager.updatedIds, <String>['sub-1']);
      expect(find.textContaining('已更新到最新脚本'), findsOneWidget);
    });

    testWidgets('本地导入的源：菜单项置灰，点了不会去更新', (tester) async {
      final manager = subscribedManager();
      await pumpManager(tester, manager);

      // 第二条是本地源，打开它的菜单。
      await tester.tap(find.byTooltip('更多操作').last);
      await tester.pumpAndSettle();

      // 置灰的菜单项在 Flutter 里渲染为禁用色；点它不会触发回调。
      await tester.tap(find.text('更新订阅源'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        manager.updatedIds,
        isEmpty,
        reason: '本地源没有订阅地址，点了也不该去更新',
      );
      // 菜单仍然开着（禁用项不关闭菜单）。
      expect(find.text('更新订阅源'), findsOneWidget);
    });

    testWidgets('已是最新：如实说「已是最新」，不谎报更新', (tester) async {
      final manager = subscribedManager(
        results: <String, SourceUpdateResult>{
          'sub-1': const SourceUpdateResult.unchanged(
            SourceDescriptor(
              id: 'sub-1',
              name: '订阅源',
              version: '1.0.0',
              enabled: true,
            ),
          ),
        },
      );
      await pumpManager(tester, manager);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新订阅源'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已是最新'), findsOneWidget);
    });

    testWidgets('更新失败：透出原因（MD5 不符 / 网络异常）', (tester) async {
      final manager = subscribedManager(
        results: <String, SourceUpdateResult>{
          'sub-1': const SourceUpdateResult.failed(
            '订阅拉取失败：MD5 校验不一致（清单 abc，实际 def）',
          ),
        },
      );
      await pumpManager(tester, manager);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新订阅源'));
      await tester.pumpAndSettle();

      expect(find.textContaining('更新失败'), findsOneWidget);
      expect(find.textContaining('MD5 校验不一致'), findsOneWidget);
    });

    testWidgets('批量刷新：只刷订阅源，给出汇总', (tester) async {
      final manager = subscribedManager(
        results: <String, SourceUpdateResult>{
          'sub-1': const SourceUpdateResult.updated(
            SourceDescriptor(
              id: 'sub-1',
              name: '订阅源',
              version: '2.0.0',
              enabled: true,
            ),
          ),
        },
      );
      await pumpManager(tester, manager);

      await tester.tap(find.byTooltip('刷新全部订阅源'));
      await tester.pumpAndSettle();

      expect(
        manager.updatedIds,
        <String>['sub-1'],
        reason: '本地导入的源没有来源地址，不该被刷新',
      );
      expect(find.textContaining('更新 1'), findsOneWidget);
    });

    testWidgets('没有订阅源时：不显示批量刷新入口', (tester) async {
      final manager = managerWith();
      await pumpManager(tester, manager);
      expect(find.byTooltip('刷新全部订阅源'), findsNothing);
    });
  });
}
