import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/md5.dart';
import 'package:lume_box/features/source/add_source_button.dart';

import 'support/fake_source_manager.dart';

/// 板块页「+」添加源按钮的验证：本地文件（单个 / 多个 / 清单 / 裸校验值）、
/// 订阅链接（单脚本 / 地址清单 / `.js.md5` 校验清单）、剪贴板三条通道，
/// 以及覆盖确认、结果弹窗与失败口径。
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
    Future<List<({String name, String text})>> Function()? readLocalScripts,
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
                readLocalScripts: readLocalScripts,
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

  /// 模拟剪贴板里有 [text]，返回还原句柄（用完即撤）。
  void mockClipboard(String text) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': text};
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  group('本地文件', () {
    testWidgets('本地文件导入：读出的脚本剥掉 BOM 后写入本板块', (tester) async {
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (
            name: 'demo.js',
            text: '\uFEFF// LumeSource: {"id":"demo","name":"演示源","version":"1.0.0"}\n'
                'var LumeSource = {id: "demo"};',
          ),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 个文件'), findsOneWidget);
      expect(find.text('demo.js'), findsOneWidget);
      expect(find.text('脚本'), findsOneWidget, reason: '选中当场就标出识别结论');

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

    testWidgets('本地多文件：一次选多个文件逐个导入，结果弹窗逐条列', (tester) async {
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (name: 'a.js', text: 'var LumeSource = {id: "a", name: "甲源"};'),
          (name: 'b.js', text: 'var LumeSource = {id: "b", name: "乙源"};'),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(manager.imported.length, 2, reason: '两个文件各导入一条');
      expect(find.text('导入结果'), findsOneWidget);
      expect(find.text('共 2 条：新增 2 · 覆盖 0 · 失败 0'), findsOneWidget);
      expect(find.text('已导入：新图源'), findsNWidgets(2));

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(importedCount, <int>[1], reason: '全部结束后才回调一次');
    });

    testWidgets('本地清单文件：一行一个地址 → 走订阅解析并记下来源', (tester) async {
      final fetched = <String>[];
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (
            name: 'list.txt',
            text: 'https://example.com/a.js\nhttps://example.com/b.js\n',
          ),
        ],
        fetchSubscription: (url) async {
          fetched.add(url);
          return entity('var LumeSource = {id: "s${fetched.length}", name: "源${fetched.length}"};');
        },
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      expect(find.text('地址清单（2 个地址）'), findsOneWidget, reason: '选中就看出是清单');

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(fetched, <String>[
        'https://example.com/a.js',
        'https://example.com/b.js',
      ]);
      expect(manager.imported.length, 2);
      expect(
        manager.importedOrigins,
        <String>['https://example.com/a.js', 'https://example.com/b.js'],
        reason: '清单里每一份记**自己**的地址（不是清单地址）：'
            '「更新订阅源」各更各的，记清单地址只会拿到第一条',
      );
    });

    testWidgets('本地 .js.md5 文件：认得出、当场标红，且给下一步动作', (tester) async {
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (name: 'index.js.md5', text: '6c7379bc24a23ec5b923ecf6f9c9d331'),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();

      expect(find.text('校验值'), findsOneWidget, reason: '选择器允许 .md5，就要认得出它');

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.textContaining('本机导入拿不到脚本地址'), findsOneWidget);
      expect(
        find.textContaining('填入该 .md5 的网址'),
        findsOneWidget,
        reason: '点明换哪条路',
      );
      expect(manager.imported, isEmpty);
      expect(importedCount, isEmpty);
    });

    testWidgets('本地备份文本：直说去「恢复源」，不当作脚本导入', (tester) async {
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (
            name: 'lumesources.json',
            text: '{"format":"lume.sources","version":1,"createdAt":"2026-10-06T00:00:00.000",'
                '"sections":{"novel":[{"id":"a","name":"甲","version":"1.0.0",'
                '"script":"var LumeSource = {id: \\"a\\", name: \\"甲\\"};","enabled":true}]}}',
          ),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      expect(find.text('备份'), findsOneWidget);

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.textContaining('恢复源'), findsOneWidget);
      expect(manager.imported, isEmpty, reason: '备份里带着脚本原文，但绝不能当脚本导入');
    });

    testWidgets('本地粘贴导入：内容为空时给出可读提示，不调用导入', (tester) async {
      await pumpButton(tester);

      await openDialog(tester);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.text('请选择本地文件、粘贴脚本内容，或填写订阅地址'), findsOneWidget);
      expect(manager.imported, isEmpty);
    });
  });

  group('剪贴板', () {
    testWidgets('剪贴板是脚本：填进粘贴框，点导入即可', (tester) async {
      mockClipboard('var LumeSource = {id: "clip", name: "剪贴板源"};');
      await pumpButton(tester);

      await openDialog(tester);
      await tester.tap(find.text('从剪贴板'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已从剪贴板填入脚本'), findsOneWidget);

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(manager.imported.single, contains('剪贴板源'));
      expect(importedCount, <int>[1]);
    });

    testWidgets('剪贴板是地址：切到订阅页签并填入，拉取后导入', (tester) async {
      mockClipboard('https://example.com/sub.js');
      await pumpButton(
        tester,
        fetchSubscription: (url) async {
          expect(url, 'https://example.com/sub.js');
          return entity('var LumeSource = {id: "sub", name: "订阅源"};');
        },
      );

      await openDialog(tester);
      await tester.tap(find.text('从剪贴板'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已从剪贴板填入 1 个地址'), findsOneWidget);
      expect(find.text('拉取并导入'), findsOneWidget, reason: '自动切到订阅页签');

      await tester.tap(find.text('拉取并导入'));
      await tester.pumpAndSettle();

      expect(find.text('已导入：新图源（订阅）'), findsOneWidget);
      expect(manager.importedOrigins.single, 'https://example.com/sub.js');
    });

    testWidgets('剪贴板是备份：说清楚该去哪儿，不静默失败', (tester) async {
      mockClipboard(
        '{"format":"lume.sources","version":1,"createdAt":"2026-10-06T00:00:00.000","sections":{}}',
      );
      await pumpButton(tester);

      await openDialog(tester);
      await tester.tap(find.text('从剪贴板'));
      await tester.pumpAndSettle();

      expect(find.textContaining('恢复源'), findsOneWidget);
      expect(manager.imported, isEmpty);
    });

    testWidgets('剪贴板没有文本：给一句人话', (tester) async {
      mockClipboard('');
      await pumpButton(tester);

      await openDialog(tester);
      await tester.tap(find.text('从剪贴板'));
      await tester.pumpAndSettle();

      expect(find.text('剪贴板里没有文本'), findsOneWidget);
    });
  });

  group('订阅链接', () {
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
      expect(find.text('导入结果'), findsOneWidget, reason: '多条导入给逐条结果');
      expect(find.text('已导入：新图源（订阅）'), findsNWidgets(2));
      expect(
        manager.importedOrigins,
        <String>['https://example.com/a.js', 'https://example.com/b.js'],
        reason: '清单导入时每条记自己那一行地址：记用户填的清单地址会让'
            '「更新订阅源」只能更新到清单里的第一条（第二个源永远更新不了）',
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

      expect(find.textContaining('http:// 或 https://'), findsOneWidget);
      expect(manager.imported, isEmpty);
    });

    testWidgets('订阅链接导入：拉取过程中显示进度，而不是一个静态的「处理中」', (tester) async {
      final gate = Completer<void>();
      await pumpButton(
        tester,
        fetchSubscription: (url) async {
          await gate.future;
          return entity('var LumeSource = {id: "s", name: "源"};');
        },
      );

      await openDialog(tester);
      await tester.tap(find.text('订阅链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https://example.com/a.js');
      await tester.tap(find.text('拉取并导入'));
      await tester.pump();

      expect(find.text('正在拉取第 1 个地址…'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(manager.imported.single, contains('LumeSource'));
    });

    testWidgets('订阅链接导入：清单超过上限时说明只处理前 N 条', (tester) async {
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
        'https://example.com/sub.txt\n'
        '${List<String>.generate(25, (i) => 'https://example.com/$i.js').join('\n')}',
      );
      await tester.tap(find.text('拉取并导入'));
      await tester.pumpAndSettle();

      expect(
        fetched.length,
        20,
        reason: '一条订阅 + 19 个地址就到上限（防地址风暴）',
      );
      expect(find.textContaining('清单较长，本次只处理前 20 条地址'), findsOneWidget);
    });
  });

  group('覆盖确认与失败', () {
    testWidgets('同 id 已存在：先确认，取消则零写入', (tester) async {
      // id 用不含点的写法：真实解析器的 id 白名单只收字母数字与 - _，
      // 带点的 id 连头部元信息都读不出来，覆盖确认也就无从谈起。
      manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'lume-new', name: '新图源', version: '1.0.0', enabled: true),
        ],
      )..importDescriptor = const SourceDescriptor(
          id: 'lume-new',
          name: '新图源',
          version: '2.0.0',
          enabled: true,
        );
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (
            name: 'next.js',
            text: '// LumeSource: {"id":"lume-new","name":"新图源","version":"2.0.0"}\n'
                'var LumeSource = {id: "lume-new", name: "新图源"};',
          ),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.text('覆盖已有源？'), findsOneWidget);
      expect(find.textContaining('已存在源「新图源」（1.0.0 → 2.0.0）'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(manager.imported, isEmpty, reason: '取消即整批零写入');
      expect(find.text('已取消导入：没有写入任何源'), findsOneWidget);
      expect(importedCount, isEmpty);
    });

    testWidgets('同 id 已存在：确认后覆盖，结论写成「已覆盖」', (tester) async {
      manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'lume-new', name: '新图源', version: '1.0.0', enabled: true),
        ],
      )..importDescriptor = const SourceDescriptor(
          id: 'lume-new',
          name: '新图源',
          version: '2.0.0',
          enabled: true,
        );
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (
            name: 'next.js',
            text: '// LumeSource: {"id":"lume-new","name":"新图源","version":"2.0.0"}',
          ),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('覆盖'));
      await tester.pumpAndSettle();

      expect(manager.imported.single, contains('2.0.0'));
      expect(find.text('已覆盖：新图源'), findsOneWidget);
      expect(importedCount, <int>[1]);
    });

    testWidgets('新 id 不弹确认：直接导入', (tester) async {
      manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'other', name: '别的源', version: '1.0.0', enabled: true),
        ],
      )..importDescriptor = const SourceDescriptor(
          id: 'lume-new',
          name: '新图源',
          version: '1.0.0',
          enabled: true,
        );
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (name: 'a.js', text: '// LumeSource: {"id":"lume-new","name":"新图源"}'),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.text('覆盖已有源？'), findsNothing);
      expect(find.text('已导入：新图源'), findsOneWidget);
    });

    testWidgets('导入失败：透出管理器的失败原因，不触发刷新回调', (tester) async {
      manager.importFailure = '脚本载入失败：语法错误或运行异常';
      await pumpButton(
        tester,
        readLocalScripts: () async => <({String name, String text})>[
          (name: 'bad.js', text: 'var LumeSource = ('),
        ],
      );

      await openDialog(tester);
      await tester.tap(find.text('选择本地文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.text('导入结果'), findsOneWidget, reason: '有失败就给能看清的弹窗');
      expect(
        find.text('导入失败：bad.js — 脚本载入失败：语法错误或运行异常'),
        findsOneWidget,
      );
      expect(importedCount, isEmpty);
    });

    testWidgets('运行时不可用：不显示添加入口', (tester) async {
      manager = FakeSourceManager(runtimeAvailable: false);
      await pumpButton(tester);

      expect(find.byTooltip('添加源'), findsNothing);
    });
  });
}
