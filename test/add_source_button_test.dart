import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/add_source_button.dart';

import 'support/fake_source_manager.dart';

/// 板块页「+」添加图源按钮的验证：本地文件导入、订阅链接导入（单脚本与
/// 「一行一个地址」的清单）、失败口径，以及脚本文本的 BOM 剥离。
void main() {
  late FakeSourceManager manager;
  late List<int> importedCount; // onImported 回调次数（用列表代替可变闭包变量）

  setUp(() {
    manager = FakeSourceManager();
    importedCount = <int>[];
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    Future<({String name, String text})?> Function()? readLocalScript,
    Future<String> Function(String url)? fetchSubscription,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          appBar: AppBar(
            actions: <Widget>[
              AddSourceButton(
                section: Section.novel,
                manager: manager,
                onImported: () => importedCount.add(1),
                readLocalScript: readLocalScript,
                fetchSubscription: fetchSubscription,
              ),
            ],
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('添加图源'));
    await tester.pumpAndSettle();
  }

  testWidgets('本地文件导入：读出的脚本剥掉 BOM 后写入本板块', (tester) async {
    await pumpButton(
      tester,
      readLocalScript: () async => (
        name: 'demo.js',
        text: '\uFEFF// LumeSource: {"id":"demo","name":"演示源","version":"1.0.0"}\n'
            'var LumeSource = {id: "demo"};',
      ),
    );

    await openDialog(tester);
    await tester.tap(find.text('选择本地 .js 文件'));
    await tester.pumpAndSettle();

    expect(find.text('已选择：demo.js'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    final imported = manager.imported.single;
    expect(imported.startsWith('\uFEFF'), isFalse, reason: 'BOM 必须在导入前剥掉');
    expect(imported, contains('LumeSource'));
    expect(find.text('已导入：新图源'), findsOneWidget);
    expect(importedCount, <int>[1]);
  });

  testWidgets('本地粘贴导入：内容为空时给出可读提示，不调用导入', (tester) async {
    await pumpButton(tester);

    await openDialog(tester);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('请粘贴脚本内容或选择本地文件'), findsOneWidget);
    expect(manager.imported, isEmpty);
  });

  testWidgets('订阅链接导入：拉取到的单个脚本直接导入', (tester) async {
    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        expect(url, 'https://example.com/sub.js');
        return '\uFEFFvar LumeSource = {id: "sub", name: "订阅源"};';
      },
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/sub.js');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(manager.imported.single.startsWith('\uFEFF'), isFalse);
    expect(manager.imported.single, contains('订阅源'));
    expect(find.text('已导入：新图源'), findsOneWidget);
  });

  testWidgets('订阅链接导入：清单里一行一个地址时逐个拉取', (tester) async {
    final fetched = <String>[];
    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        if (url == 'https://example.com/sub.txt') {
          return 'https://example.com/a.js\n# 注释行\nhttps://example.com/b.js\n';
        }
        return 'var LumeSource = {id: "s${fetched.length}", name: "源${fetched.length}"};';
      },
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/sub.txt');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(fetched, <String>[
      'https://example.com/sub.txt',
      'https://example.com/a.js',
      'https://example.com/b.js',
    ]);
    expect(manager.imported.length, 2);
    expect(find.text('已导入：新图源\n已导入：新图源'), findsOneWidget);
  });

  testWidgets('订阅链接导入：地址栏里直接粘多行地址也逐个拉取', (tester) async {
    final fetched = <String>[];
    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        return 'var LumeSource = {id: "s${fetched.length}", name: "源${fetched.length}"};';
      },
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/a.js\nhttps://example.com/b.js',
    );
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(fetched, <String>[
      'https://example.com/a.js',
      'https://example.com/b.js',
    ]);
    expect(manager.imported.length, 2);
  });

  testWidgets('订阅链接导入：拉取失败给出可读提示，不导入', (tester) async {
    await pumpButton(
      tester,
      fetchSubscription: (url) async => throw StateError('HTTP 404'),
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/x.js');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('订阅拉取失败'), findsOneWidget);
    expect(manager.imported, isEmpty);
  });

  testWidgets('订阅链接导入：地址非法时不发请求', (tester) async {
    await pumpButton(
      tester,
      fetchSubscription: (url) async => fail('不该发请求：$url'),
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(find.text('请填写 http / https 订阅地址'), findsOneWidget);
    expect(manager.imported, isEmpty);
  });

  testWidgets('导入失败：透出管理器的失败原因，不触发刷新回调', (tester) async {
    manager.importFailure = '脚本载入失败：语法错误或运行异常';
    await pumpButton(
      tester,
      readLocalScript: () async => (name: 'bad.js', text: 'var LumeSource = ('),
    );

    await openDialog(tester);
    await tester.tap(find.text('选择本地 .js 文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('导入失败：脚本载入失败：语法错误或运行异常'), findsOneWidget);
    expect(importedCount, isEmpty);
  });

  testWidgets('运行时不可用：不显示添加入口', (tester) async {
    manager = FakeSourceManager(runtimeAvailable: false);
    await pumpButton(tester);

    expect(find.byTooltip('添加图源'), findsNothing);
  });
}
