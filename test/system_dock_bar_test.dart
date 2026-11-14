import 'package:lume_box/features/shell/system_search_button.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';
import 'package:lume_box/shared/widgets/native_glass_controls.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/features/reading/compact_browse_header.dart';
import 'package:lume_box/features/settings/native_navigation_settings_card.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';
import 'package:lume_box/features/shell/system_dock_bar.dart';
import 'package:lume_box/shared/widgets/dock_handle_button.dart';
import 'package:lume_box/shared/widgets/lume_icon.dart';

const entries = [
  ShellDockEntry(
    id: 'comic',
    label: '漫画',
    icon: Icons.book,
    selectedIcon: Icons.book,
  ),
  ShellDockEntry(
    id: 'video',
    label: '视频',
    icon: Icons.play_circle,
    selectedIcon: Icons.play_circle,
  ),
  ShellDockEntry(
    id: 'settings',
    label: '设置',
    icon: Icons.settings,
    selectedIcon: Icons.settings,
  ),
];

class NativeHarness {
  NativeHarness(this.tester);
  final WidgetTester tester;
  final updates = <Map<Object?, Object?>>[];
  final created = <Map<Object?, Object?>>[];
  final channels = <MethodChannel>[];
  final searchChannels = <MethodChannel>[];
  final searchCreated = <Map<Object?, Object?>>[];
  final searchUpdates = <Map<Object?, Object?>>[];
  final disposed = <int>[];
  Completer<void>? creationGate;
  bool failUpdates = false;

  void install({bool supported = true}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemTabBarCapabilities.channel,
      (_) async => {'supported': supported, 'height': 64.0},
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        if (args['viewType'] == SystemSearchButton.viewType) {
          searchCreated.add(
            const StandardMessageCodec().decodeMessage(
              ByteData.sublistView(args['params'] as Uint8List),
            ) as Map<Object?, Object?>,
          );
          final searchChannel = MethodChannel(
            '${SystemSearchButton.viewType}_${args['id']}',
          );
          searchChannels.add(searchChannel);
          messenger.setMockMethodCallHandler(searchChannel, (call) async {
            searchUpdates.add(
              Map<Object?, Object?>.from(call.arguments as Map),
            );
            return null;
          });
          return null;
        }
        created.add(
          const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(args['params'] as Uint8List),
          ) as Map<Object?, Object?>,
        );
        final channel = MethodChannel(
          '${SystemDockBar.viewType}_${args['id']}',
        );
        channels.add(channel);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (failUpdates) throw PlatformException(code: 'unavailable');
          updates.add(Map<Object?, Object?>.from(call.arguments as Map));
          return {'height': 64.0};
        });
        await creationGate?.future;
      } else if (call.method == 'dispose') {
        disposed.add(call.arguments as int);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      messenger.setMockMethodCallHandler(
        SystemTabBarCapabilities.channel,
        null,
      );
      for (final channel in [...channels, ...searchChannels]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  Future<void> event(String method, Object? args, {bool search = false}) async {
    final done = Completer<void>();
    tester.binding.channelBuffers.push(
      search ? searchChannels.last.name : channels.last.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    await done.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() {
    ShellSettingsController.instance.resetForTesting();
    directory = Directory.systemTemp.createTempSync('system-navigation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });
  tearDown(() {
    ShellSettingsController.instance.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    directory.deleteSync(recursive: true);
  });

  testWidgets('圆形搜索使用独立 UIKit 视图并保留系统交互和主题更新', (tester) async {
    final harness = NativeHarness(tester)..install();
    var presses = 0;
    Widget scene(Brightness brightness) => MaterialApp(
      theme: LumeTheme.build(brightness: brightness),
      themeAnimationDuration: Duration.zero,
      home: Center(
        child: SystemSearchButton(
          size: 60,
          useNative: true,
          onPressed: () => presses++,
        ),
      ),
    );
    await tester.pumpWidget(scene(Brightness.light));
    await tester.pumpAndSettle();
    expect(harness.searchCreated, hasLength(1));
    expect(harness.created, isEmpty);
    expect(tester.getSize(find.byType(SystemSearchButton)), const Size(60, 60));
    await harness.event('pressed', null, search: true);
    expect(presses, 1);
    await tester.pumpWidget(scene(Brightness.dark));
    await tester.pumpAndSettle();
    expect(harness.searchCreated, hasLength(1));
    expect(harness.searchUpdates.last['brightness'], 'dark');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  testWidgets('原生实心图标选中时跟随主题色', (tester) async {
    final harness = NativeHarness(tester)..install();
    var badge = 7;
    Widget scene(Brightness brightness) => MaterialApp(
      theme: LumeTheme.build(
        brightness: brightness,
        customAccent: const Color(0xFFFF2D55),
      ),
      themeAnimationDuration: Duration.zero,
      home: Align(
        alignment: Alignment.bottomCenter,
        child: SystemDockBar(
          entries: [
            ...entries.take(2),
            ShellDockEntry(
              id: 'settings',
              label: '设置',
              icon: Icons.settings,
              selectedIcon: Icons.settings,
              badgeCount: badge,
            ),
          ],
          activeId: 'comic',
          onSelect: (_) {},
          settings: const NativeNavigationSettings(solidIcons: true),
          height: 64,
          bottomMargin: 0,
          onHeightChanged: (_) {},
          onUnavailable: () {},
        ),
      ),
    );
    await tester.pumpWidget(scene(Brightness.light));
    await tester.pumpAndSettle();
    expect(harness.updates.last['tintColor'], LumeTheme.accent.toARGB32());
    expect(((harness.updates.last['entries'] as List).last as Map)['badge'], 7);
    badge = 0;
    await tester.pumpWidget(scene(Brightness.dark));
    await tester.pumpAndSettle();
    expect(harness.updates.last['tintColor'], LumeTheme.accent.toARGB32());
    expect(
      ((harness.updates.last['entries'] as List).last as Map).containsKey(
        'badge',
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('兼容导航可切换原图标和黑色实心图标', (tester) async {
    const items = [
      ShellDockEntry(
        id: 'comic',
        label: '漫画',
        icon: Icons.book_outlined,
        selectedIcon: Icons.book,
      ),
      ShellDockEntry(
        id: 'video',
        label: '视频',
        icon: Icons.play_circle_outline,
        selectedIcon: Icons.play_circle_fill,
      ),
    ];
    Widget scene(bool solid, Brightness brightness) => MaterialApp(
      theme: LumeTheme.build(brightness: brightness),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ShellDockBar(
            entries: items,
            activeId: 'video',
            onSelect: (_) {},
            appearance: DockAppearance.defaults,
            solidIcons: solid,
          ),
        ),
      ),
    );
    Finder comic() => find.byWidgetPredicate(
      (w) => w is LumeIcon && w.slot == 'dock.comic.normal',
    );
    Finder video() => find.byWidgetPredicate(
      (w) => w is LumeIcon && w.slot == 'dock.video.selected',
    );
    await tester.pumpWidget(scene(false, Brightness.light));
    await tester.pumpAndSettle();
    expect(tester.widget<LumeIcon>(comic()).icon, Icons.book_outlined);
    await tester.pumpWidget(scene(true, Brightness.light));
    await tester.pumpAndSettle();
    expect(tester.widget<LumeIcon>(comic()).icon, Icons.book);
    expect(tester.widget<LumeIcon>(comic()).color, const Color(0xFF161616));
    expect(tester.widget<LumeIcon>(video()).color, LumeTheme.accent);
    await tester.pumpWidget(scene(true, Brightness.dark));
    await tester.pumpAndSettle();
    expect(tester.widget<LumeIcon>(comic()).color, Colors.white);
    expect(tester.widget<LumeIcon>(video()).color, LumeTheme.accent);
  });

  test('导航默认值采用用户截图参数，明确保存的系统高度和零留白仍保留', () {
    const defaults = NativeNavigationSettings();
    expect(defaults.barHeight, 85);
    expect(defaults.iconSize, 22);
    expect(defaults.horizontalMargin, 3);
    expect(defaults.safeGap, -36);
    expect(defaults.materialOpacity, .62);
    expect(defaults.opaqueBackground, isFalse);
    expect(defaults.showLabels && defaults.followThemeColor, isTrue);
    expect(defaults.solidIcons, isFalse);
    final solid = defaults.copyWith(solidIcons: true);
    expect(
      NativeNavigationSettings.fromJson(solid.toJson()).solidIcons,
      isTrue,
    );
    expect(NativeNavigationSettings.fromJson({}), defaults);
    final saved = NativeNavigationSettings.fromJson({
      'barHeight': 0,
      'safeGap': 0,
      'horizontalMargin': 0,
    });
    expect(saved.heightFor(64), 64);
    expect(saved.safeGap, 0);
    expect(saved.horizontalMargin, 0);
  });

  test('原生参数单独保存，隐藏排序及修改自定义外观不会覆盖它', () {
    const native = NativeNavigationSettings(
      enabled: false,
      showLabels: false,
      followThemeColor: false,
      tintColor: 0xFF008A6A,
      iconSize: 28,
      horizontalMargin: 12,
      safeGap: 8,
    );
    var settings = const ShellSettings(nativeNavigation: native);
    settings = settings
        .withMove(0, 2)
        .withVisible('video', false)!
        .withHandleStyle(DockHandleStyle.arrow)
        .withAppearance(const DockAppearance(height: 70));
    final restored = ShellSettings.fromJson(settings.toJson());
    expect(restored, settings);
    expect(restored.nativeNavigation, native);
    expect(restored.withDefaultTabs().nativeNavigation, native);
    final old = Map<String, Object?>.of(settings.toJson())
      ..remove('nativeNavigation');
    final migrated = ShellSettings.fromJson(old);
    expect(migrated.tabs.map((t) => t.id), settings.tabs.map((t) => t.id));
    expect(migrated.appearance, settings.appearance);
    expect(migrated.nativeNavigation, const NativeNavigationSettings());
  });

  test('明确开启系统栏后，旧胶囊尺寸不能在重载时关闭它', () async {
    final controller = ShellSettingsController.instance;
    await controller.setAppearance(const DockAppearance(height: 70));
    expect(controller.settings.nativeNavigation.enabled, false);
    controller.updateNativeNavigation(
      const NativeNavigationSettings(enabled: true),
    );
    await controller.saveNativeNavigation();
    final restored = (await ShellSettingsStore.open()).load();
    expect(restored.appearance.height, 70);
    expect(restored.nativeNavigation.enabled, true);
  });

  test('损坏数值回退或收敛，窄屏边距不能挤掉导航项', () {
    final parsed = NativeNavigationSettings.fromJson({
      'iconSize': double.nan,
      'safeGap': double.infinity,
      'horizontalMargin': 999,
      'tintColor': -1,
      'showLabels': 'bad',
    });
    expect(parsed.iconSize, 22);
    expect(parsed.safeGap, -36);
    expect(parsed.horizontalMargin, 40);
    expect(parsed.tintColor, 0xFF7C5CFF);
    expect(parsed.showLabels, isTrue);
    expect(
      SystemDockBar.marginFor(
        width: 280,
        entryCount: 3,
        requested: 40,
        trailingWidth: 74,
      ),
      25,
    );
  });

  test('原生高度和负安全区距离可持久化，旧配置跟随系统', () {
    const value = NativeNavigationSettings(
      barHeight: 88,
      safeGap: -50,
      materialOpacity: .25,
      opaqueBackground: true,
    );
    expect(NativeNavigationSettings.fromJson(value.toJson()), value);
    expect(value.heightFor(64), 88);
    expect(value.bottomFor(34), 0);
    expect(value.copyWith(safeGap: -12).bottomFor(34), 22);
    expect(NativeNavigationSettings.fromJson({}).heightFor(64), 85);
    final bounded = NativeNavigationSettings.fromJson({
      'barHeight': 999,
      'safeGap': -999,
    });
    expect(bounded.barHeight, 120);
    expect(bounded.safeGap, -100);
    expect(
      NativeNavigationSettings.fromJson({'materialOpacity': -1})
          .materialOpacity,
      0,
    );
    expect(
      NativeNavigationSettings.fromJson({'materialOpacity': 2}).materialOpacity,
      1,
    );
    expect(
      NativeNavigationSettings.fromJson({'barHeight': double.nan}).barHeight,
      85,
    );
  });

  testWidgets('原生栏高度和向下位移同步实际视图及内容避让，系统回报不覆盖自定义高度', (tester) async {
    final harness = NativeHarness(tester)..install();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = ShellSettingsController.instance;
    settings.updateNativeNavigation(
      const NativeNavigationSettings(barHeight: 88, safeGap: -50),
    );
    ShellDockScope? scope;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewPadding: EdgeInsets.only(bottom: 34),
          ),
          child: AppShell(
            desktopRail: false,
            pageBuilder: (_) => Builder(
              builder: (context) {
                scope = ShellDockScope.maybeScopeOf(context);
                return const Text('native-geometry');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final view = find.byWidgetPredicate(
      (widget) =>
          widget is UiKitView && widget.viewType == SystemDockBar.viewType,
    );
    expect(tester.getSize(view).height, 88);
    expect(tester.getRect(view).bottom, 844);
    expect(scope!.navigationHeight, 88);
    expect(scope!.dockBottom, 0);
    expect(harness.updates.last['barHeight'], 88);
    await harness.event('metrics', {'height': 80.0});
    await tester.pumpAndSettle();
    expect(tester.getSize(view).height, 88);
    settings.updateNativeNavigation(
      const NativeNavigationSettings(barHeight: 44, safeGap: -12),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(view).height, 44);
    expect(tester.getRect(view).bottom, 822);
    expect(scope!.dockBottom, 22);
    expect(harness.updates.last['barHeight'], 44);
    expect(settings.settings.nativeNavigation.enabled, isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('平台视图创建期间修改配置，创建后只应用最新配置与主题', (tester) async {
    final harness = NativeHarness(tester)..creationGate = Completer<void>();
    harness.install();
    final selected = <String>[];
    var unavailable = 0;
    Widget scene(String id, Brightness brightness, bool labels, bool visible) =>
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          home: Align(
            alignment: Alignment.bottomCenter,
            child: SystemDockBar(
              entries: entries,
              activeId: id,
              onSelect: selected.add,
              settings: NativeNavigationSettings(
                showLabels: labels,
                followThemeColor: false,
                tintColor: 0xFF008A6A,
                iconSize: 28,
              ),
              height: 64,
              bottomMargin: 34,
              visible: visible,
              onHeightChanged: (_) {},
              onUnavailable: () => unavailable++,
            ),
          ),
        );
    await tester.pumpWidget(scene('comic', Brightness.light, true, true));
    await tester.pumpWidget(scene('settings', Brightness.dark, false, true));
    harness.creationGate!.complete();
    await tester.pumpAndSettle();
    expect(harness.updates.last['activeId'], 'settings');
    expect(harness.updates.last['brightness'], 'dark');
    expect(harness.updates.last['showLabels'], false);
    expect(harness.updates.last['iconSize'], 28);
    expect(harness.updates.last['tintColor'], 0xFF008A6A);
    final count = harness.updates.length;
    await tester.pumpWidget(scene('settings', Brightness.dark, false, true));
    await tester.pumpAndSettle();
    expect(harness.updates.length, count);
    await harness.event('selected', 'video');
    await harness.event('selected', 'retired-tab');
    expect(selected, ['video']);
    await tester.pumpWidget(scene('settings', Brightness.dark, false, false));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsNothing,
    );
    expect(harness.disposed, hasLength(1));
    expect(unavailable, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('原生切页、布局更新、排序、全屏和键盘显隐共用原有页面状态', (tester) async {
    final harness = NativeHarness(tester)..install();
    final controller = ShellDockController();
    addTearDown(controller.dispose);
    var keyBottom = 0.0;
    var searches = 0;
    Widget scene() => MaterialApp(
      theme: LumeTheme.build(),
      navigatorObservers: [ShellDockObserver(controller)],
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          viewPadding: const EdgeInsets.only(bottom: 34),
          viewInsets: EdgeInsets.only(bottom: keyBottom),
        ),
        child: AppShell(
          controller: controller,
          desktopRail: false,
          pageBuilder: (id) => Stack(
            fit: StackFit.expand,
            children: [
              Text('page-$id'),
              TextButton(
                onPressed: () =>
                    Navigator.of(tester.element(find.text('page-$id'))).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(body: Text('detail')),
                      ),
                    ),
                child: const Text('detail-open'),
              ),
              if (id == 'comic' || id == 'video')
                BrowseSearchButton(onPressed: () => searches++),
            ],
          ),
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    expect(find.byType(SystemDockBar), findsOneWidget);
    final page = tester.element(find.text('page-comic'));
    final scope = ShellDockScope.maybeScopeOf(page)!;
    expect(scope.navigationHeight, 85);
    expect(scope.dockBottom, 0);
    expect(scope.dockInset, 93);
    final creations = harness.created.length;
    ShellSettingsController.instance.updateNativeNavigation(
      const NativeNavigationSettings(safeGap: 12, horizontalMargin: 16),
    );
    await tester.pumpAndSettle();
    expect(tester.element(find.text('page-comic')), same(page));
    expect(harness.created.length, creations);
    expect(ShellDockScope.maybeScopeOf(page)!.dockBottom, 46);
    final barRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
    );
    expect(barRect.width, closeTo(288, .1));
    expect(
      (harness.updates.last['entries'] as List).map((e) => (e as Map)['id']),
      ['comic', 'video', 'music', 'settings'],
    );
    expect(find.byKey(const ValueKey('browse-search-surface')), findsNothing);
    // Search is no longer a native tab item.
    await tester.pumpAndSettle();
    expect(searches, 0);
    UserScrollNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 200,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: page,
      direction: ScrollDirection.reverse,
    ).dispatch(page);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final handleDuring = tester.getRect(find.byType(DockHandleButton));
    await tester.pumpAndSettle();
    expect(find.byType(DockHandleButton), findsOneWidget);
    final handleRect = tester.getRect(find.byType(DockHandleButton));
    expect(handleRect.height, closeTo(barRect.height, .1));
    expect(handleRect.width, closeTo(barRect.height, .1));
    expect(handleRect.bottom, closeTo(barRect.bottom, .1));
    expect(handleDuring.bottom, closeTo(handleRect.bottom, .1));
    expect(find.byTooltip('搜索'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsNothing,
    );
    await tester.tap(find.byTooltip('展开导航'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsOneWidget,
    );
    // Search is no longer a native tab item.
    await tester.pumpAndSettle();
    expect(searches, 0);
    final hideToken = Object();
    controller.hide(hideToken);
    await tester.pumpAndSettle();
    expect(find.byTooltip('搜索'), findsNothing);
    expect(find.byType(DockHandleButton), findsNothing);
    controller.show(hideToken);
    await tester.pumpAndSettle();
    expect((harness.updates.last['entries'] as List).last, {
      'id': 'settings',
      'label': '设置',
    });
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('detail-open'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsNothing,
    );
    expect(find.byTooltip('搜索'), findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsOneWidget,
    );
    expect((harness.updates.last['entries'] as List).last, {
      'id': 'settings',
      'label': '设置',
    });
    keyBottom = 320;
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UiKitView && widget.viewType == SystemDockBar.viewType,
      ),
      findsNothing,
    );
    expect(find.byTooltip('搜索'), findsNothing);
    keyBottom = 0;
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    await harness.event('selected', 'settings');
    await tester.pumpAndSettle();
    ShellSettingsController.instance.apply(
      ShellSettingsController.instance.settings.withMove(0, 2),
    );
    await tester.pumpAndSettle();
    expect(
      (harness.updates.last['entries'] as List).map((e) => (e as Map)['id']),
      ['video', 'music', 'comic', 'settings'],
    );
    expect(find.text('page-settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('旧系统回退 Dock 仍保留音乐，全局搜索位于底部右侧', (tester) async {
    final harness = NativeHarness(tester);
    harness.install(supported: false);
    final controller = ShellDockController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: AppShell(
          controller: controller,
          desktopRail: false,
          pageBuilder: (id) =>
              GlassScaffold(title: id, child: Text('page-$id')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShellDockBar), findsOneWidget);
    final capsule = tester.getRect(find.byKey(ShellDockBar.capsuleSurfaceKey));
    final search = find.byKey(const ValueKey('global-search-button'));
    expect(capsule.contains(tester.getCenter(search)), false);
    expect(
      find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text('音乐'),
      ),
      findsOneWidget,
    );
    final page = tester.element(find.text('page-comic'));
    UserScrollNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 100,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: page,
      direction: ScrollDirection.reverse,
    ).dispatch(page);
    await tester.pumpAndSettle();
    expect(find.byType(DockHandleButton), findsOneWidget);
    expect(search, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('原生通道失败自动恢复自定义 Dock，不切换当前页面', (tester) async {
    final harness = NativeHarness(tester)..failUpdates = true;
    harness.install();
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          desktopRail: false,
          pageBuilder: (id) => Text('page-$id'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShellDockBar), findsOneWidget);
    expect(find.byType(SystemDockBar), findsNothing);
    expect(find.text('page-comic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('设置参数可实时修改、保存、重读，关闭原生后恢复旧 Dock 偏好', (tester) async {
    final controller = ShellSettingsController.instance;
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNavigationSettingsPage(
          controller: controller,
          entries: entries,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final solidToggle = find.byKey(const ValueKey('navigation-solid-icons'));
    await tester.tap(solidToggle);
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.solidIcons, isTrue);
    expect(
      (await ShellSettingsStore.open()).load().nativeNavigation.solidIcons,
      isTrue,
    );
    await tester.tap(solidToggle);
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.solidIcons, isFalse);
    expect(
      find.byKey(const ValueKey('top-navigation-transparency')),
      findsNothing,
    );
    await tester.tap(find.text('紧凑玻璃'));
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.barHeight, 64);
    await tester.tap(find.text('清晰实色'));
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.opaqueBackground, isTrue);
    await tester.tap(find.text('标准玻璃'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级外观'));
    await tester.pumpAndSettle();
    final top = tester.widget<NativeGlassSlider>(
      find.byKey(const ValueKey('top-navigation-transparency')),
    );
    final bottom = tester.widget<NativeGlassSlider>(
      find.byKey(const ValueKey('bottom-navigation-transparency')),
    );
    final oldBottom = controller.settings.nativeNavigation.materialOpacity;
    top.onChanged!(.25);
    await tester.pump();
    expect(FloatingModules.instance.style(FloatingModule.home).opacity, .75);
    expect(
      FloatingModules.instance.style(FloatingModule.navigation).opacity,
      .75,
    );
    expect(controller.settings.nativeNavigation.materialOpacity, oldBottom);
    bottom.onChanged!(.6);
    bottom.onChangeEnd!(.6);
    await tester.pumpAndSettle();
    expect(
      controller.settings.nativeNavigation.materialOpacity,
      closeTo(.4, .001),
    );
    expect(FloatingModules.instance.style(FloatingModule.home).opacity, .75);
    await tester.tap(find.byKey(const ValueKey('native-navigation-labels')));
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.showLabels, false);
    final slider = tester.widget<NativeGlassSlider>(
      find.byKey(const ValueKey('native-navigation-icon-size')),
    );
    slider.onChanged!(29);
    slider.onChangeEnd!(29);
    await tester.pumpAndSettle();
    await controller.saveNativeNavigation();
    expect(
      (await ShellSettingsStore.open()).load().nativeNavigation.iconSize,
      29,
    );
    final height = tester.widget<NativeGlassSlider>(
      find.byKey(const ValueKey('native-navigation-height')),
    );
    height.onChanged!(88);
    height.onChangeEnd!(88);
    await tester.pumpAndSettle();
    final gapFinder = find.byKey(const ValueKey('native-navigation-safe-gap'));
    await tester.scrollUntilVisible(gapFinder, 200);
    final gap = tester.widget<NativeGlassSlider>(gapFinder);
    expect(gap.min, -100);
    expect(gap.max, 100);
    gap.onChanged!(-50);
    gap.onChangeEnd!(-50);
    await tester.pumpAndSettle();
    await controller.saveNativeNavigation();
    final saved = (await ShellSettingsStore.open()).load().nativeNavigation;
    expect(saved.barHeight, 88);
    expect(saved.safeGap, -50);
    expect(saved.enabled, isTrue);
    final reset = find.byKey(const ValueKey('native-navigation-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(
      controller.settings.nativeNavigation,
      const NativeNavigationSettings(),
    );
    expect(FloatingModules.instance.style(FloatingModule.home).opacity, .95);
    expect(
      FloatingModules.instance.style(FloatingModule.navigation).opacity,
      .95,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('native-navigation-enabled')),
      -300,
    );
    final oldAppearance = controller.appearance;
    await tester.tap(find.byKey(const ValueKey('native-navigation-enabled')));
    await tester.pumpAndSettle();
    expect(controller.settings.nativeNavigation.enabled, false);
    expect(controller.appearance, oldAppearance);
    expect(
      (await ShellSettingsStore.open()).load().nativeNavigation.enabled,
      false,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
