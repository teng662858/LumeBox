import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/shared/widgets/state_view.dart';

/// 统一状态视图的形态验证：五状态各自的标题、说明与动作。
void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    required SourceStateKind state,
    String? title,
    String? detail,
    VoidCallback? onRetry,
    Widget? action,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: SourceStateView(
            state: state,
            title: title,
            detail: detail,
            onRetry: onRetry,
            action: action,
          ),
        ),
      ),
    );
    // 加载态的转圈是常驻动画，pumpAndSettle 永远不收敛，因此只泵固定帧数。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('加载中：转圈 + 文案', (tester) async {
    await pumpView(tester, state: SourceStateKind.loading);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载…'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('空数据：标题 + 默认说明 + 重试', (tester) async {
    var retried = 0;
    await pumpView(
      tester,
      state: SourceStateKind.empty,
      onRetry: () => retried++,
    );

    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('换个条件试试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('图源禁用：默认引导去图源管理启用', (tester) async {
    await pumpView(tester, state: SourceStateKind.disabled);

    expect(find.text('源已停用'), findsOneWidget);
    expect(find.text('去源管理里启用它'), findsOneWidget);
  });

  testWidgets('脚本报错：标题 + 数据层原始原因原样可见', (tester) async {
    await pumpView(
      tester,
      state: SourceStateKind.scriptError,
      detail: 'TypeError: x is not a function',
    );

    expect(find.text('源脚本报错'), findsOneWidget);
    expect(find.text('TypeError: x is not a function'), findsOneWidget);
  });

  testWidgets('网络异常：标题 + 原始原因 + 重试', (tester) async {
    var retried = 0;
    await pumpView(
      tester,
      state: SourceStateKind.networkError,
      detail: '网络请求失败：ClientException: 连接被拒绝',
      onRetry: () => retried++,
    );

    expect(find.text('网络异常'), findsOneWidget);
    expect(find.text('网络请求失败：ClientException: 连接被拒绝'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('标题可覆盖，且能与额外动作共存', (tester) async {
    await pumpView(
      tester,
      state: SourceStateKind.empty,
      title: '暂无源',
      detail: '进入源管理导入并启用源',
      action: FilledButton(onPressed: () {}, child: const Text('源管理')),
    );

    expect(find.text('暂无源'), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);
    expect(find.text('源管理'), findsOneWidget);
  });

  testWidgets('就绪态不渲染任何提示', (tester) async {
    await pumpView(tester, state: SourceStateKind.ready);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('暂无内容'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });
}
