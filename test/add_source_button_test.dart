import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/md5.dart';
import 'package:lume_box/features/source/add_source_button.dart';

import 'support/fake_source_manager.dart';

/// 板块页「+」添加图源按钮的验证：本地文件导入、订阅链接导入（单脚本 /
/// 「一行一个地址」的清单 / `.js.md5` 校验清单）、失败口径，以及脚本文本的
/// BOM 剥离与 MD5 校验。
///
/// 测试用：文本 → 订阅拉取结果（字节按 UTF-8 编码，供 `.md5` 校验）。
SourceFetchResult entity(String text) => SourceFetchResult(
      bytes: Uint8List.fromList(utf8.encode(text)),
      text: text,
    );

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
    Future<SourceFetchResult> Function(String url)? fetchSubscription,
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
    await tester.tap(find.byTooltip('添加源'));
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
    expect(find.text('已导入：新图源'), findsOneWidget, reason: '本地导入不带订阅标记');
    expect(
      manager.importedOrigins.single,
      isEmpty,
      reason: '本地导入没有订阅来源地址',
    );
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
        return entity('\uFEFFvar LumeSource = {id: "sub", name: "订阅源"};');
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
    expect(find.text('已导入：新图源（订阅）'), findsOneWidget);
    expect(
      manager.importedOrigins.single,
      isNotEmpty,
      reason: '订阅来源要记下来，供「更新订阅源」重新拉取',
    );
  });

  testWidgets('订阅链接导入：清单里一行一个地址时逐个拉取', (tester) async {
    final fetched = <String>[];
    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        if (url == 'https://example.com/sub.txt') {
          return entity('https://example.com/a.js\n# 注释行\nhttps://example.com/b.js\n');
        }
        return entity('var LumeSource = {id: "s${fetched.length}", name: "源${fetched.length}"};');
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
    expect(find.text('已导入：新图源（订阅）\n已导入：新图源（订阅）'), findsOneWidget);
    expect(
      manager.importedOrigins,
      everyElement('https://example.com/sub.txt'),
      reason: '清单导入时来源记的是用户填的那个地址',
    );
  });

  testWidgets('订阅链接导入：地址栏里直接粘多行地址也逐个拉取', (tester) async {
    final fetched = <String>[];
    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        return entity('var LumeSource = {id: "s${fetched.length}", name: "源${fetched.length}"};');
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

  testWidgets('订阅链接导入：.js.md5 校验清单 → 去掉 .md5 取脚本并核对 MD5', (tester) async {
    // 真实约定：清单里是 MD5 校验值，脚本实体在同名去掉 `.md5` 的地址上。
    const script = 'var LumeSource = {id: "md5src", name: "校验清单源"};';
    final expected = Md5.hex(utf8.encode(script));
    final fetched = <String>[];

    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        if (url.endsWith('.md5')) return entity('$expected\n');
        return entity(script);
      },
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://9280.kstore.vip/cat/index.js.md5',
    );
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(fetched, <String>[
      'https://9280.kstore.vip/cat/index.js.md5',
      'https://9280.kstore.vip/cat/index.js',
    ]);
    expect(manager.imported.single, script);
    expect(find.text('已导入：新图源（订阅）'), findsOneWidget);
    expect(
      manager.importedOrigins.single,
      'https://9280.kstore.vip/cat/index.js.md5',
      reason: '来源记用户填的 .md5 清单地址（下次更新仍走同一套校验）',
    );
  });

  testWidgets('订阅链接导入：MD5 对不上时拒绝导入并说明差异', (tester) async {
    await pumpButton(
      tester,
      fetchSubscription: (url) async => url.endsWith('.md5')
          ? entity('6c7379bc24a23ec5b923ecf6f9c9d331')
          : entity('var LumeSource = {id: "tampered"};'),
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://9280.kstore.vip/cat/index.js.md5',
    );
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('MD5 校验不一致'), findsOneWidget);
    expect(manager.imported, isEmpty);
  });

  testWidgets('订阅链接导入：清单里嵌 .js.md5 也逐个按约定解析', (tester) async {
    const script = 'var LumeSource = {id: "nested", name: "嵌套校验源"};';
    final expected = Md5.hex(utf8.encode(script));
    final fetched = <String>[];

    await pumpButton(
      tester,
      fetchSubscription: (url) async {
        fetched.add(url);
        if (url == 'https://example.com/list.txt') {
          return entity('https://example.com/a.js.md5\n');
        }
        if (url.endsWith('.md5')) return entity(expected);
        return entity(script);
      },
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/list.txt');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(fetched, <String>[
      'https://example.com/list.txt',
      'https://example.com/a.js.md5',
      'https://example.com/a.js',
    ]);
    expect(manager.imported.single, script);
  });

  testWidgets('订阅链接导入：清单里互相引用不会死循环', (tester) async {
    await pumpButton(
      tester,
      fetchSubscription: (url) async => entity('https://example.com/loop.txt\n'),
    );

    await openDialog(tester);
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/loop.txt');
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(find.text('订阅里没有可导入的源脚本'), findsOneWidget);
    expect(manager.imported, isEmpty);
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

    expect(find.byTooltip('添加源'), findsNothing);
  });
}
