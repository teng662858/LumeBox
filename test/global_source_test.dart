import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/total_subscription.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/global_source_page.dart';

import 'support/fake_source_manager.dart';

/// 全局图源总管理页的功能验证：一页汇总四个板块、逐个板块执行管理操作。
///
/// 每个板块各用一个替身管理器驱动真实页面；断言不只看界面，还看「操作是否只
/// 落到目标板块的端口上」——板块隔离（宪法第 3 条）在这里有页面级证据。
void main() {
  const novel = Section.video;
  const comic = Section.comic;
  const cat = Section.cat;

  const novelA = SourceDescriptor(
    id: 'n1',
    name: '视频源A',
    version: '1.0.0',
    enabled: true,
  );
  const novelB = SourceDescriptor(
    id: 'n2',
    name: '视频源B',
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
  }) => <Section, FakeSourceManager>{
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
    Future<List<({String name, String text})>> Function()? readLocalScripts,
    Future<SourceFetchResult> Function(String url)? fetchSubscription,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: GlobalSourcePage(
          managerFactory: (section) => managers[section]!,
          readLocalScripts: readLocalScripts,
          fetchSubscription: fetchSubscription,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一键导入可选择三条线路，取消不会请求', (tester) async {
    final requests = <String>[];
    await pumpPage(
      tester,
      fakeManagers(),
      fetchSubscription: (url) async {
        requests.add(url);
        throw StateError('测试停止请求');
      },
    );
    Future<void> openPicker() async {
      await tester.tap(find.byTooltip('一键导入全部订阅源'));
      await tester.pumpAndSettle();
    }

    await openPicker();
    for (final route in SubscriptionRoute.values) {
      expect(find.text(route.label), findsOneWidget);
    }
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    for (final route in SubscriptionRoute.values) {
      await openPicker();
      await tester.tap(find.text(route.label));
      await tester.pumpAndSettle();
      expect(requests.last, SubscriptionCatalog.totalFor(route));
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
    }
    expect(requests, hasLength(3));
  });

  testWidgets('一键导入显示跳过项并可按选择恢复', (tester) async {
    final root = Directory.systemTemp.createTempSync('bulk-ui-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    final managers = fakeManagers();
    managers[Section.video]!.importDescriptor = const SourceDescriptor(
      id: 'recovered',
      name: '之前移除的源',
      version: '1',
      enabled: true,
    );
    const manifest = 'https://fixture.test/list.txt';
    const source = 'https://fixture.test/a.js';
    final total = TotalSubscription({
      Section.video: [(url: manifest, enabled: true)],
    });
    final stored = await tester.runAsync(
      () => SourceSubscriptionSync.open(
        Section.video,
        manager: managers[Section.video],
      ),
    );
    stored!.subscriptions.add(
      SavedSourceSubscription(
        manifest,
        excludedIds: {'recovered'},
        members: {'recovered': source},
      ),
    );
    await tester.runAsync(() => stored.save());
    final values = {
      SubscriptionCatalog.totalUrl: total.encode(),
      manifest: source,
      source: '// LumeSource: {"id":"recovered","name":"之前移除的源","version":"1","category":"video"}\nvar LumeSource = {};',
    };
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      await tester.pumpAndSettle();
    }

    try {
      await pumpPage(
        tester,
        managers,
        fetchSubscription: (url) async {
          final text = values[url]!;
          return SourceFetchResult(
            bytes: Uint8List.fromList(utf8.encode(text)),
            text: text,
          );
        },
      );
      await tester.tap(find.byTooltip('一键导入全部订阅源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GitHub 原站'));
      await settle();
      expect(find.text('订阅导入结果'), findsOneWidget);
      expect(find.text('之前移除的源'), findsOneWidget);
      expect(managers[Section.video]!.sources, isEmpty);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复选中源'));
      await settle();
      expect(managers[Section.video]!.sources.single.id, 'recovered');
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => SectionScope.closeAll());
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('全局管理运行类型筛选保留板块隔离', (tester) async {
    final managers = fakeManagers(
      sources: {
        Section.video: const [
          SourceDescriptor(
            id: 'py',
            name: '测试 Python',
            version: '1',
            enabled: true,
            runtimeKind: 'python',
          ),
          SourceDescriptor(
            id: 'mod',
            name: '测试模块',
            version: '1',
            enabled: true,
            runtimeKind: 'module',
          ),
        ],
        Section.comic: [comicA],
      },
    );
    await pumpPage(tester, managers);
    await tester.tap(find.widgetWithText(ChoiceChip, 'PY'));
    await tester.pumpAndSettle();
    expect(find.text('测试 Python'), findsOneWidget);
    expect(find.text('测试模块'), findsNothing);
    expect(find.text('漫画源'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '模块'));
    await tester.pumpAndSettle();
    expect(find.text('测试模块'), findsOneWidget);
    expect(find.text('测试 Python'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '网页'));
    await tester.pumpAndSettle();
    expect(find.text('测试模块'), findsNothing);
    expect(find.textContaining('暂无网页源'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '全部类型'));
    await tester.pumpAndSettle();
    expect(find.text('测试 Python'), findsOneWidget);
    expect(find.text('漫画源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全局多选按筛选范围操作，取消删除不改数据', (tester) async {
    final managers = fakeManagers(
      sources: {
        novel: [novelA, novelB],
        comic: [comicA],
      },
    );
    await pumpPage(tester, managers);
    await tester.tap(find.text('视频 1/2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('站点维护'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);
    await tester.tap(find.text('批量停用'));
    await tester.pumpAndSettle();
    expect((await managers[novel]!.list()).every((e) => !e.enabled), isTrue);
    expect((await managers[comic]!.list()).single.enabled, isTrue);
    await tester.tap(find.text('删除所选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('范围：视频'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await managers[novel]!.list()).length, 2);
    await tester.tap(find.text('删除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();
    expect(await managers[novel]!.list(), isEmpty);
    expect((await managers[comic]!.list()).length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('汇总：四板块分组展示，计数与状态标记正确', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA, novelB],
        comic: const <SourceDescriptor>[comicA],
      },
    );
    await pumpPage(tester, managers);

    // 筛选行：全部 + 每板块「启用 / 总数」。
    expect(find.text('全部 2/3'), findsOneWidget);
    expect(find.text('视频 1/2'), findsOneWidget);
    expect(find.text('漫画 1/1'), findsOneWidget);
    expect(find.text('猫源 0/0'), findsOneWidget);

    // 分组与条目：名称、版本、停用标记；版本为空时回退项目名。
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('视频源A'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('视频源B'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(find.text(LumeTheme.appName), findsWidgets);
    expect(find.text('漫画源'), findsOneWidget);

    // 没有图源的板块给出空提示。
    expect(find.text('暂无源'), findsNWidgets(1));
  });

  testWidgets('筛选：只显示所选板块的分组', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
        comic: const <SourceDescriptor>[comicA],
      },
    );
    await pumpPage(tester, managers);

    await tester.tap(find.text('漫画 1/1'));
    await tester.pumpAndSettle();

    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('视频源A'), findsNothing);
    expect(find.text('视频'), findsNothing);

    // 回到「全部」后视频分组回来。
    await tester.tap(find.text('全部 2/2'));
    await tester.pumpAndSettle();
    expect(find.text('视频源A'), findsOneWidget);
  });

  testWidgets('导入：只写入所选板块，列表随即刷新', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        comic: const <SourceDescriptor>[comicA],
      },
    );
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
    expect(find.text('漫画 · 已导入：新图源'), findsOneWidget);
    // 列表与计数一起刷新。
    expect(find.text('新图源'), findsOneWidget);
    expect(find.text('漫画 2/2'), findsOneWidget);
  });

  testWidgets('导入：对话框里可改目标板块', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
      },
    );
    await pumpPage(tester, managers);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('导入源'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('猫源')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'var LumeSource = {id:"c"};',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(managers[cat]!.imported.single, contains('LumeSource'));
    expect(managers[novel]!.imported, isEmpty);
    expect(find.text('猫源 · 已导入：新图源'), findsOneWidget);
  });

  testWidgets('导入：空脚本被拦下，不写任何板块', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
      },
    );
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入到视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 三条通道都没有内容：留在弹窗里说清楚，不落盘、不关窗。
    expect(find.text('请选择本地文件、粘贴脚本内容，或填写订阅地址'), findsOneWidget);
    for (final manager in managers.values) {
      expect(manager.imported, isEmpty);
    }
  });

  testWidgets('导入失败：提示原因，列表不变', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        comic: const <SourceDescriptor>[comicA],
      },
    );
    managers[comic]!.importFailure = '脚本载入失败：语法错误或运行异常';
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入到漫画'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'var LumeSource = (');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 结果弹窗带上板块名，失败行点明是哪一条、原因是什么。
    expect(find.text('导入结果 · 漫画'), findsOneWidget);
    expect(find.text('导入失败：粘贴 — 脚本载入失败：语法错误或运行异常'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('漫画 1/1'), findsOneWidget);
  });

  testWidgets('导入：本地文件通道可用，且只写所选板块', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
        comic: const <SourceDescriptor>[comicA],
      },
    );
    await pumpPage(
      tester,
      managers,
      readLocalScripts: () async => <({String name, String text})>[
        (name: 'a.js', text: 'var LumeSource = {id: "a", name: "文件源"};'),
      ],
    );

    await tester.tap(find.byTooltip('导入源'));
    await tester.pumpAndSettle();
    // 总管理页的导入弹窗也能挑文件（与本板块页同一个弹窗）。
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('漫画')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(managers[comic]!.imported.single, contains('文件源'));
    expect(managers[novel]!.imported, isEmpty, reason: '只写所选板块');
    expect(find.text('漫画 · 已导入：新图源'), findsOneWidget);
  });

  testWidgets('导入：订阅链接通道可用，来源地址落到所选板块', (tester) async {
    final managers = fakeManagers();
    await pumpPage(
      tester,
      managers,
      fetchSubscription: (url) async => SourceFetchResult(
        bytes: Uint8List.fromList(
          utf8.encode('var LumeSource = {id: "s", name: "订阅源"};'),
        ),
        text: 'var LumeSource = {id: "s", name: "订阅源"};',
      ),
    );

    await tester.tap(find.byTooltip('导入源'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('猫源')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('订阅链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/sub.js',
    );
    await tester.tap(find.text('拉取并导入'));
    await tester.pumpAndSettle();

    expect(managers[cat]!.importedOrigins.single, 'https://example.com/sub.js');
    expect(managers[novel]!.imported, isEmpty);
    expect(find.text('猫源 · 已导入：新图源（订阅）'), findsOneWidget);
  });

  testWidgets('导入：剪贴板里的脚本一键填入', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{
              'text': 'var LumeSource = {id: "clip", name: "剪贴板源"};',
            };
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final managers = fakeManagers();
    await pumpPage(tester, managers);

    await tester.tap(find.byTooltip('导入源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从剪贴板'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已从剪贴板填入脚本'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(managers[comic]!.imported.single, contains('剪贴板源'));
    expect(managers[novel]!.imported, isEmpty);
  });

  testWidgets('启停：只写入所属板块，停用后浏览入口禁用', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
        comic: const <SourceDescriptor>[comicA],
      },
    );
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
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('删除：二次确认后只移除所属板块的记录', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
        comic: const <SourceDescriptor>[comicA],
      },
    );
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
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
        comic: const <SourceDescriptor>[comicA],
      },
    );
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
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        comic: const <SourceDescriptor>[comicA],
      },
    );
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

    expect(find.text('暂无源'), findsOneWidget);
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
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'n1',
            name: '一个非常长的图源名称用于验证省略号是否生效',
            version: '1.0.0',
            enabled: true,
          ),
        ],
      },
    );
    await pumpPage(tester, managers, size: const Size(390, 844));

    expect(tester.takeException(), isNull);
    expect(find.text('视频 1/1'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('一个非常长的图源名称用于验证省略号是否生效')).overflow,
      TextOverflow.ellipsis,
    );
  });

  testWidgets('页面退出：四个板块的管理器一起释放', (tester) async {
    final managers = fakeManagers(
      sources: <Section, List<SourceDescriptor>>{
        novel: const <SourceDescriptor>[novelA],
      },
    );
    await pumpPage(tester, managers);
    for (final manager in managers.values) {
      expect(manager.closed, isFalse);
    }

    await tester.pumpWidget(const SizedBox());
    for (final manager in managers.values) {
      expect(manager.closed, isTrue);
    }
  });

  // ==========================================================================
  // 批量刷新全部订阅源（文档第 4 条点名项）
  // ==========================================================================

  group('批量刷新订阅源', () {
    /// 一条「有订阅地址」的源（可刷新）。
    const novelSubscribed = SourceDescriptor(
      id: 'n-sub',
      name: '订阅视频源',
      version: '1.0.0',
      enabled: true,
      originUrl: 'https://example.com/novel.js',
    );

    /// 一条本地导入的源（没有订阅地址，不该被刷新）。
    const novelLocal = SourceDescriptor(
      id: 'n-local',
      name: '本地视频源',
      version: '1.0.0',
      enabled: true,
    );

    const comicSubscribed = SourceDescriptor(
      id: 'c-sub',
      name: '订阅漫画源',
      version: '2.0.0',
      enabled: true,
      originUrl: 'https://example.com/comic.js',
    );

    testWidgets('只刷新有订阅地址的源，本地导入的源一个都不碰', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelSubscribed, novelLocal],
          comic: const <SourceDescriptor>[comicSubscribed],
        },
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();

      // 先确认（会改动多份源）。
      expect(find.textContaining('刷新 2 个订阅源？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '刷新'));
      await tester.pumpAndSettle();

      // 只有两条带订阅地址的被刷新，本地导入的那条没被碰。
      expect(managers[novel]!.updatedIds, <String>['n-sub']);
      expect(managers[comic]!.updatedIds, <String>['c-sub']);
      expect(
        managers[novel]!.updatedIds,
        isNot(contains('n-local')),
        reason: '本地导入的源没有订阅地址，不该出现在刷新范围里',
      );
      // 其他板块没被误伤。
      expect(managers[Section.cat]!.updatedIds, isEmpty);
    });

    testWidgets('刷新按板块隔离：视频源只经视频板块的端口', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelSubscribed],
        },
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '刷新'));
      await tester.pumpAndSettle();

      expect(managers[novel]!.updatedIds, <String>['n-sub']);
      for (final section in Section.values) {
        if (section == novel) continue;
        expect(
          managers[section]!.updatedIds,
          isEmpty,
          reason: '${section.label} 板块不该收到刷新调用',
        );
      }
    });

    testWidgets('结果汇总：更新 / 失败分别计数，失败原因逐条列出', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelSubscribed],
          comic: const <SourceDescriptor>[comicSubscribed],
        },
      );
      managers[novel]!.updateResults['n-sub'] =
          const SourceUpdateResult.updated(
            SourceDescriptor(
              id: 'n-sub',
              name: '订阅视频源',
              version: '2.0.0',
              enabled: true,
              originUrl: 'https://example.com/novel.js',
            ),
          );
      managers[comic]!.updateResults['c-sub'] = const SourceUpdateResult.failed(
        '订阅拉取失败：连接超时',
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '刷新'));
      await tester.pumpAndSettle();

      // 有失败 → 模态弹窗（失败原因是排障要看的信息）。
      expect(find.text('订阅刷新结果'), findsOneWidget);
      expect(find.textContaining('更新 1'), findsWidgets);
      expect(find.textContaining('失败 1'), findsWidgets);
      expect(
        find.textContaining('订阅拉取失败：连接超时'),
        findsOneWidget,
        reason: '失败原因要逐条列出，不能只给个数字',
      );
      await tester.tap(find.widgetWithText(FilledButton, '关闭'));
      await tester.pumpAndSettle();
    });

    testWidgets('取消确认：一个源都不刷新', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelSubscribed],
        },
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(managers[novel]!.updatedIds, isEmpty);
    });

    testWidgets('没有订阅源：直接说明，不弹确认框', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelLocal],
        },
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有订阅源可刷新'), findsOneWidget);
      expect(find.textContaining('刷新 1 个订阅源？'), findsNothing);
    });

    testWidgets('一条失败不中断整批：后面的源照常刷新', (tester) async {
      final managers = fakeManagers(
        sources: <Section, List<SourceDescriptor>>{
          novel: const <SourceDescriptor>[novelSubscribed],
          comic: const <SourceDescriptor>[comicSubscribed],
        },
      );
      managers[novel]!.updateResults['n-sub'] = const SourceUpdateResult.failed(
        '订阅拉取失败：连接超时',
      );
      await pumpPage(tester, managers);

      await tester.tap(find.byTooltip('批量刷新订阅源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '刷新'));
      await tester.pumpAndSettle();

      expect(managers[comic]!.updatedIds, <String>[
        'c-sub',
      ], reason: '一条失败不该让后面的源被跳过');
      await tester.tap(find.widgetWithText(FilledButton, '关闭'));
      await tester.pumpAndSettle();
    });
  });
}
