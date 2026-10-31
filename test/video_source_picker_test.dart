import 'package:lume_box/shared/widgets/source_icon.dart';
import 'package:lume_box/shared/widgets/source_rating_badge.dart';
import 'package:lume_box/core/session/privacy_settings.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/kazumi_rule.dart';
import 'package:lume_box/core/source/source_subscription_catalog.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_bar.dart';
import 'package:lume_box/features/source/video_source_picker.dart';
import 'package:lume_box/features/source/video_source_scope.dart';
import 'package:lume_box/core/web/web_home_sources.dart';
import 'package:lume_box/shared/widgets/source_picker_scroll_list.dart';
import 'package:lume_box/shared/widgets/source_picker_card.dart';

import 'support/fake_source_manager.dart';

class _PickerCatService extends CatService {
  _PickerCatService() : super.testing();
  @override
  Future<void> boot() async {}
}

void main() {
  late Directory root;
  late _PickerCatService service;
  late FakeSourceManager manager;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-type-picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ReadingLibrary.open(Section.video);
    await ReadingLibrary.open(Section.cat);
    service = _PickerCatService();
    service.subscriptions.add(
      CatSubscription(
        id: 'pack',
        name: '牛二',
        url: 'https://example.test/index.js.md5',
        sites: const [
          CatSite(
            subscriptionId: 'pack',
            key: 'a',
            name: '猫源测试长名称站点',
            api: '/a',
          ),
          CatSite(subscriptionId: 'pack', key: 'b', name: '另一个站点', api: '/b'),
        ],
      ),
    );
    manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'ordinary',
          name: '普通视频长名称测试',
          version: '1.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'disabled',
          name: '停用源',
          version: '1',
          enabled: false,
        ),
      ],
    );
  });
  tearDown(() async {
    service.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    Brightness brightness = Brightness.light,
    bool keepInitialType = false,
    bool showingCat = false,
    String? currentCatId,
    String? currentWebId,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: VideoSourcePicker(
                manager: manager,
                service: service,
                showingCat: showingCat,
                currentCatId: currentCatId,
                currentWebId: currentWebId,
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    if (!keepInitialType) {
      await tester.ensureVisible(
        find.byKey(const ValueKey('video-source-type-all')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('video-source-type-all')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-source-type-all')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('视频源选择器给已分级的源显示 18+ 徽章，普通源不误标', (tester) async {
    final privacy = PrivacySettings.instance;
    final previous = privacy.showAdult;
    await tester.runAsync(() async {
      await privacy.boot(directory: root);
      await privacy.setShowAdult(true);
    });
    addTearDown(() => tester.runAsync(() => privacy.setShowAdult(previous)));
    manager.sources.insert(
      0,
      const SourceDescriptor(
        id: 'p5mh_comic',
        name: '分级测试源',
        version: '1.0',
        enabled: true,
      ),
    );
    await pump(tester);
    final adult = find.ancestor(
      of: find.text('分级测试源'),
      matching: find.byType(SourcePickerCard),
    );
    expect(
      find.descendant(of: adult, matching: find.byType(SourceRatingBadge)),
      findsOneWidget,
    );
    final ordinary = find.ancestor(
      of: find.text('普通视频长名称测试'),
      matching: find.byType(SourcePickerCard),
    );
    expect(
      find.descendant(of: ordinary, matching: find.byType(SourceRatingBadge)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Kazumi与有声小说独立分类，旧源无需重新导入且普通页不混入', (tester) async {
    manager.sources.addAll(const [
      SourceDescriptor(
        id: 'kazumi_fixture',
        name: '动漫测试',
        version: '8',
        enabled: true,
      ),
      SourceDescriptor(
        id: 'book',
        name: '听书测试',
        version: '1',
        enabled: true,
        group: '听书',
      ),
      SourceDescriptor(
        id: 'podcast',
        name: '明确音频',
        version: '1',
        enabled: true,
        mediaKind: 'audio',
        runtimeKind: 'python',
      ),
    ]);
    manager.selected = 'book';
    await pump(tester, keepInitialType: true);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('video-source-type-audio')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('听书测试'), findsOneWidget);
    expect(find.text('明确音频'), findsOneWidget);
    expect(find.text('动漫测试'), findsNothing);
    final tab = find.byKey(const ValueKey('video-source-type-kazumi'));
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(find.text('动漫测试'), findsOneWidget);
    expect(find.text('听书测试'), findsNothing);
    final ordinary = find.byKey(const ValueKey('video-source-type-ordinary'));
    await tester.ensureVisible(ordinary);
    await tester.tap(ordinary);
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('动漫测试'), findsNothing);
    expect(find.text('听书测试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有声小说汇集猫源和网页音频，保留选中状态且不混入普通影视', (tester) async {
    service.subscriptions.add(
      CatSubscription(
        id: 'books',
        name: '书库订阅',
        url: 'https://fixture.test/books',
        sites: const [
          CatSite(
            subscriptionId: 'books',
            key: 'audio',
            name: '猫源听书',
            api: '/audio',
          ),
        ],
      ),
    );
    final store = await WebHomeStore.open();
    store.upsert(
      WebHomeSource(
        id: 'audio-home',
        name: '网页听书',
        url: 'https://fixture.test/audio',
      ),
    );
    await pump(
      tester,
      keepInitialType: true,
      showingCat: true,
      currentCatId: 'books|video|audio',
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('video-source-type-audio')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('猫源听书'), findsOneWidget);
    expect(find.text('网页听书'), findsOneWidget);
    expect(find.text('猫源测试长名称站点'), findsNothing);
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(VideoSourceType.values.map((s) => s.label).toList(), [
      '全部',
      'JS 源',
      '猫源',
      'PY',
      '有声小说',
      'Kazumi',
      '模块',
      '网页',
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final runtime in ['javascript', 'python', 'module']) {
    testWidgets(
      'reopen locates the last $runtime source without changing source order',
      (tester) async {
        manager.sources.addAll([
          for (var i = 0; i < 100; i++)
            SourceDescriptor(
              id: '$runtime-$i',
              name: '源$i',
              version: '1',
              enabled: true,
              runtimeKind: runtime,
            ),
        ]);
        manager.selected = '$runtime-99';
        final order = manager.sources.map((source) => source.id).toList();
        await pump(tester, keepInitialType: true);
        final kind = runtime == 'javascript' ? 'ordinary' : runtime;
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(ValueKey('video-source-type-$kind')),
              )
              .selected,
          true,
        );
        final card = find.byKey(ValueKey('video-picker-source-$runtime-99'));
        expect(card, findsOneWidget);
        expect(
          tester.getTopLeft(card).dy,
          closeTo(tester.getTopLeft(find.byType(SourcePickerScrollList)).dy, 1),
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SourcePickerCard && widget.selected,
          ),
          findsOneWidget,
        );
        expect(manager.sources.map((source) => source.id).toList(), order);
        expect(manager.selectedIds, isEmpty);
        await tester.ensureVisible(
          find.byKey(const ValueKey('video-source-type-all')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('video-source-type-all')));
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(SourcePickerScrollList),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scrollable.position.pixels, 0);
        await tester.enterText(find.byType(TextField), '普通视频长名称测试');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('video-picker-source-ordinary')),
          findsOneWidget,
        );
        expect(manager.selected, '$runtime-99');
      },
    );
  }

  testWidgets('cat drawer locates the active site in a later subscription', (
    tester,
  ) async {
    for (var group = 0; group < 8; group++) {
      service.subscriptions.add(
        CatSubscription(
          id: 'pack-$group',
          name: '订阅$group',
          url: 'https://example.test/$group',
          sites: [
            for (var i = 0; i < 14; i++)
              CatSite(
                subscriptionId: 'pack-$group',
                key: '$i',
                name: '站点$group-$i',
                api: '/$i',
              ),
          ],
        ),
      );
    }
    final selected = service.subscriptions.last.sites.last;
    await pump(
      tester,
      keepInitialType: true,
      showingCat: true,
      currentCatId: selected.id,
      scale: 2,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('video-source-type-cat')),
          )
          .selected,
      true,
    );
    final card = find.byKey(ValueKey('video-picker-source-${selected.id}'));
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      closeTo(tester.getTopLeft(find.byType(SourcePickerScrollList)).dy, 1),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourcePickerCard && widget.selected,
      ),
      findsOneWidget,
    );
    expect(manager.selectedIds, isEmpty);
  });

  testWidgets(
    'web drawer restores the last home and does not also select the ordinary source',
    (tester) async {
      final store = await WebHomeStore.open();
      for (var i = 0; i < 60; i++) {
        store.upsert(
          WebHomeSource(
            id: 'home-$i',
            name: '网页$i',
            url: 'https://example.test/$i',
          ),
        );
      }
      await pump(tester, keepInitialType: true, currentWebId: 'home-59');
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('video-source-type-web')),
            )
            .selected,
        true,
      );
      final card = find.byKey(const ValueKey('video-picker-source-home-59'));
      expect(
        tester.getTopLeft(card).dy,
        closeTo(tester.getTopLeft(find.byType(SourcePickerScrollList)).dy, 1),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('video-source-type-all')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-source-type-all')));
      await tester.pumpAndSettle();
      final ordinary = tester.widget<SourcePickerCard>(
        find.ancestor(
          of: find.byKey(const ValueKey('video-picker-source-ordinary')),
          matching: find.byType(SourcePickerCard),
        ),
      );
      expect(ordinary.selected, false);
    },
  );

  testWidgets(
    'a removed active site leaves the drawer at the top with all source types available',
    (tester) async {
      await pump(
        tester,
        keepInitialType: true,
        showingCat: true,
        currentCatId: 'removed',
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('video-source-type-all')),
            )
            .selected,
        true,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SourcePickerCard && widget.selected,
        ),
        findsNothing,
      );
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(SourcePickerScrollList),
                matching: find.byType(Scrollable),
              ),
            )
            .position
            .pixels,
        0,
      );
    },
  );

  testWidgets('本地 HTML 可批量导入、跳过重复、改名及删除，不改变普通源', (tester) async {
    final valid = File('${root.path}/fixture.html')
      ..writeAsStringSync(
        '<!doctype html><html><head><title>本地直播</title></head><body>fixture</body></html>',
      );
    final bad = File('${root.path}/broken.html')..writeAsStringSync('not html');
    var selected = [valid.path, bad.path];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      (call) async {
        expect(call.method, 'openFile');
        expect((call.arguments as Map)['multiple'], true);
        final groups = (call.arguments as Map)['acceptedTypeGroups'] as List;
        final htmlGroup = groups.single as Map;
        expect(htmlGroup['extensions'], containsAll(['html', 'htm']));
        expect(
          htmlGroup['uniformTypeIdentifiers'],
          containsAll(['public.html', 'public.plain-text', 'public.data']),
        );
        return selected;
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        null,
      ),
    );
    Future<void> flush() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-web')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-web')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-import-html')));
    await flush();
    final store = await WebHomeStore.open();
    expect(store.items, hasLength(1));
    expect(store.items.single.isLocal, true);
    expect(find.text('部分文件未导入'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    selected = [valid.path];
    await tester.tap(find.byKey(const ValueKey('video-import-html')));
    await flush();
    expect(store.items, hasLength(1));
    expect(manager.imported, isEmpty);
    await tester.tap(find.byTooltip('本地直播的设置'));
    await tester.pumpAndSettle();
    expect(find.text('本地 HTML 已保存在 App 内，可以修改名称或删除。'), findsOneWidget);
    final html = store.items.single.html;
    await tester.enterText(find.byType(TextField).last, '我的直播');
    await tester.tap(find.text('保存'));
    await flush();
    expect(store.items.single.name, '我的直播');
    expect(store.items.single.html, html);
    await tester.tap(find.byTooltip('我的直播的设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await flush();
    expect(store.items, isEmpty);
  });

  testWidgets('网页添加菜单仍能保存普通地址，取消编辑保留原值', (tester) async {
    await pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-web')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-web')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加网页主页'));
    await tester.pumpAndSettle();
    expect(find.text('导入 HTML 文件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('web-home-add-url')));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '网页首页');
    await tester.enterText(fields.at(1), 'example.com/home');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final store = await WebHomeStore.open();
    expect(store.items.single.url, 'https://example.com/home');
    expect(store.items.single.isLocal, false);
    await tester.tap(find.byTooltip('网页首页的设置'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(0), '取消改名');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.items.single.name, '网页首页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部按运行类型分组，不混排 JS、PY 与模块', (tester) async {
    manager.sources.addAll(const [
      SourceDescriptor(
        id: 'py',
        name: 'Python源',
        version: '1',
        enabled: true,
        runtimeKind: 'python',
      ),
      SourceDescriptor(
        id: 'esm',
        name: '模块源',
        version: '1',
        enabled: true,
        runtimeKind: 'module',
      ),
    ]);
    await pump(tester);
    for (final pair in [
      ('ordinary', '普通视频长名称测试'),
      ('python', 'Python源'),
      ('module', '模块源'),
    ]) {
      final group = find.byKey(ValueKey('video-source-group-${pair.$1}'));
      await tester.ensureVisible(group);
      expect(
        find.descendant(of: group, matching: find.text(pair.$2)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: group, matching: find.text('猫源测试长名称站点')),
        findsNothing,
      );
    }
  });

  testWidgets('有声小说独立导入入口预填听书订阅，取消不写入源', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('添加视频源'));
    await tester.pumpAndSettle();
    final entry = find.text('有声小说源');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('导入有声小说源'), findsOneWidget);
    expect(find.text(SubscriptionCatalog.audiobooksUrl), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.sources.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有声小说筛选下仍可找到 HTML 导入入口', (tester) async {
    await pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-audio')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-audio')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-import-html')), findsOneWidget);
  });

  testWidgets('Kazumi 独立入口预填官方订阅，取消不写入任何源', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('添加视频源'));
    await tester.pumpAndSettle();
    expect(find.text('Kazumi 源'), findsOneWidget);
    await tester.tap(find.text('Kazumi 源'));
    await tester.pumpAndSettle();
    expect(find.text('导入 Kazumi 源'), findsOneWidget);
    expect(find.text(KazumiRule.officialIndex), findsOneWidget);
    expect(find.textContaining('部分规则没有首页推荐'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.sources.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑先露出删除，取消保留，确认才删除且相邻卡片保留', (tester) async {
    manager.sources.add(
      const SourceDescriptor(
        id: 'neighbor',
        name: '相邻源',
        version: '1',
        enabled: true,
      ),
    );
    await pump(tester);
    final tile = find.byKey(const ValueKey('video-picker-swipe-ordinary'));
    Future<void> reveal() async {
      await tester.drag(tile, const Offset(-110, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: tile, matching: find.text('删除')));
      await tester.pumpAndSettle();
    }

    await reveal();
    expect(manager.removed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    await reveal();
    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(manager.removed, ['ordinary']);
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(find.text('相邻源'), findsOneWidget);
  });

  testWidgets('猫源删除只移除该站点并记住排除记录', (tester) async {
    await pump(tester);
    final record = service.subscriptions.single;
    final site = record.sites.first;
    service.selectedSiteId = site.id;
    final tile = find.byKey(ValueKey('video-picker-swipe-${site.id}'));
    await tester.ensureVisible(tile);
    await tester.drag(tile, const Offset(-110, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: tile, matching: find.text('删除')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(record.sites.single.key, 'b');
    expect(service.selectedSiteId, isNull);
    expect(service.needsSiteSelection, isTrue);
    final restored = CatSubscription.fromJson(record.toJson());
    restored.replaceSites([site, ...restored.sites]);
    expect(restored.sites.single.key, 'b');
    expect(service.subscriptions, hasLength(1));
  });

  testWidgets('顶部分类筛选和搜索包名，不改变已有源选择', (tester) async {
    await pump(tester);
    expect(find.byTooltip('源管理'), findsOneWidget);
    expect(find.text('源订阅'), findsNothing);
    expect(
      tester.getCenter(find.byTooltip('源管理')).dy,
      tester.getCenter(find.byTooltip('添加视频源')).dy,
    );
    expect(
      tester.getCenter(find.byTooltip('源管理')).dx,
      lessThan(tester.getCenter(find.byTooltip('添加视频源')).dx),
    );
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('牛二'), findsOneWidget);
    expect(find.text('停用源'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-cat')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-cat')));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(find.text('猫源测试长名称站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '牛二');
    await tester.pumpAndSettle();
    expect(find.text('另一个站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的源'), findsOneWidget);
    expect(manager.selectedIds, isEmpty);
  });

  testWidgets('网页源长按排序，搜索过滤后仍保留未显示项位置', (tester) async {
    final store = await WebHomeStore.open();
    for (final id in ['first', 'hidden', 'last']) {
      store.upsert(
        WebHomeSource(
          id: id,
          name: id == 'hidden' ? '别的网页' : '排序$id',
          url: 'https://$id.test',
        ),
      );
    }
    await pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-web')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-web')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '排序');
    await tester.pumpAndSettle();
    final from = find.byKey(const ValueKey('web-picker-drag-last'));
    final to = find.byKey(const ValueKey('web-picker-drag-first'));
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.items.map((row) => row.id), ['last', 'hidden', 'first']);
    expect(find.text('排序last'), findsOneWidget);
  });

  testWidgets('Python 和模块分类显示真实源，普通分类不混入', (tester) async {
    manager.sources.addAll(const [
      SourceDescriptor(
        id: 'py-one',
        name: 'Python 测试源',
        version: '1',
        enabled: true,
        runtimeKind: 'python',
      ),
      SourceDescriptor(
        id: 'module-one',
        name: '模块测试源',
        version: '1',
        enabled: true,
        runtimeKind: 'module',
      ),
    ]);
    await pump(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-python')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-python')));
    await tester.pumpAndSettle();
    expect(find.text('Python 测试源'), findsOneWidget);
    expect(find.text('模块测试源'), findsNothing);
    expect(find.text('普通视频长名称测试'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-module')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-module')));
    await tester.pumpAndSettle();
    expect(find.text('模块测试源'), findsOneWidget);
    expect(find.text('Python 测试源'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-ordinary')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-ordinary')));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('Python 测试源'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets('选中猫源返回原站点，调用方继续使用原存储', (tester) async {
    VideoSourceChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<VideoSourceChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      VideoSourcePicker(manager: manager, service: service),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-source-type-cat')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-source-type-cat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('猫源测试长名称站点'));
    await tester.pumpAndSettle();
    expect(result?.site?.id, service.subscriptions.single.sites.first.id);
    expect(result?.sourceId, isNull);
  });

  testWidgets('视频的单个切源按钮使用统一抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoSourceScope(
          openPicker: (_) async {
            opened++;
          },
          child: Scaffold(
            body: ReadingSourceBar(
              section: Section.video,
              manager: manager,
              sources: manager.sources,
              currentId: 'ordinary',
              onSelect: (_) {},
              onManage: () {},
              showManage: false,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('选择视频源'), findsNothing);
  });

  testWidgets('JS源卡片支持双行名称，保留33图标、14留白、8列距和5行距', (tester) async {
    manager.sources.addAll([
      for (final id in ['b', 'c', 'd'])
        SourceDescriptor(id: id, name: '视频源$id', version: '1.0', enabled: true),
    ]);
    await pump(tester, width: 390);
    final a = find.byKey(const ValueKey('video-picker-source-ordinary'));
    final b = find.byKey(const ValueKey('video-picker-source-b'));
    final c = find.byKey(const ValueKey('video-picker-source-c'));
    final first = tester.getRect(a),
        second = tester.getRect(b),
        third = tester.getRect(c);
    expect(first.height, 55);
    expect(first.width, 177);
    expect(first.left, 14);
    expect(second.right, 376);
    expect(second.left - first.right, 8);
    expect(third.top - first.bottom, 5);
    expect(
      tester.getSize(find.descendant(of: a, matching: find.byType(SourceIcon))),
      const Size(33, 33),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('长名称适配宽度 $width 字号 $scale', (tester) async {
        await pump(tester, width: width, scale: scale);
        expect(tester.takeException(), isNull);
        if (width == 390 && scale == 1) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('build/video-source-layout-light.png');
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
