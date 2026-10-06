import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/sandbox/sandbox_result.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_engine_settings_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_source_manager.dart';

/// 猫源引擎的门控、选择与持久化验证：
/// 平台矩阵（Android 二选一 / iOS 仅 QuickJS / 其余骨架）、切换项只在 Android
/// 的猫源板块显示、选择落在猫源自己的库里（板块隔离）、扩展点按引擎分流。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_cat_engine');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 板块作用域在真实时钟里先打开（fake-async 里等不到真实异步）。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    CatEngines.debugPlatformOverride = null;
    SourceEngineRegistry.reset();
    SectionDatabase.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('平台矩阵与切换项可见性', () {
    test('Android：二选一可选，切换项只对猫源显示', () {
      CatEngines.debugPlatformOverride = 'android';

      expect(CatEngines.choices, <CatEngineKind>[
        CatEngineKind.quickjs,
        CatEngineKind.nodeMobile,
      ]);
      expect(CatEngines.available, isTrue);
      expect(CatEngines.showsEngineSwitch(Section.cat), isTrue);
      for (final section in <Section>[
        Section.novel,
        Section.comic,
        Section.video,
      ]) {
        expect(
          CatEngines.showsEngineSwitch(section),
          isFalse,
          reason: '${section.label} 不是猫源，没有引擎切换项',
        );
      }
    });

    test('iOS：仅 QuickJS，切换项隐藏（任务书第 4 条）', () {
      CatEngines.debugPlatformOverride = 'ios';

      expect(CatEngines.choices, <CatEngineKind>[CatEngineKind.quickjs]);
      expect(CatEngines.showsEngineSwitch(Section.cat), isFalse);
      // 覆盖平台上 QuickJS 原生库并不存在（本机是 Windows），
      // 因此 available 走既有骨架口径 —— 与真实 iOS 行为一致。
      expect(CatEngines.available, isFalse);
    });

    test('无引擎平台：choices 为空，板块维持骨架', () {
      CatEngines.debugPlatformOverride = 'windows';

      expect(CatEngines.choices, isEmpty);
      expect(CatEngines.available, isFalse);
      expect(CatEngines.showsEngineSwitch(Section.cat), isFalse);
    });
  });

  group('引擎选择持久化（猫源板块自己的库）', () {
    test('保存 / 读回；非法值回退 QuickJS', () async {
      CatEngines.debugPlatformOverride = 'android';
      final settings = await CatEngineSettings.open();

      expect(settings.load(), CatEngineKind.quickjs, reason: '默认 QuickJS');

      settings.save(CatEngineKind.nodeMobile);
      expect(settings.load(), CatEngineKind.nodeMobile);

      // 脏值回退。
      final database = await SectionDatabase.open(await SectionScope.open(Section.cat));
      database.setSetting(CatEngineSettings.key, 'vlc');
      expect(settings.load(), CatEngineKind.quickjs);
    });

    test('隔离：选择落在猫源库，其他板块读不到', () async {
      CatEngines.debugPlatformOverride = 'android';
      final settings = await CatEngineSettings.open();
      settings.save(CatEngineKind.nodeMobile);

      expect(
        File('${root.path}/sections/cat/cat.db').existsSync(),
        isTrue,
        reason: '选择落在猫源自己的源库里',
      );

      final novel = await SectionDatabase.open(await SectionScope.open(Section.novel));
      expect(novel.setting(CatEngineSettings.key), isNull);
    });

    test('engineKindFor：只有猫源读自己的选择，其余板块恒为 QuickJS', () async {
      CatEngines.debugPlatformOverride = 'android';
      final cat = await SectionDatabase.open(await SectionScope.open(Section.cat));
      cat.setSetting(CatEngineSettings.key, CatEngineKind.nodeMobile.id);

      expect(
        CatEngineSettings.engineKindFor(Section.cat, cat),
        CatEngineKind.nodeMobile,
      );

      final comic = await SectionDatabase.open(await SectionScope.open(Section.comic));
      for (final section in <Section>[
        Section.novel,
        Section.comic,
        Section.video,
      ]) {
        expect(
          CatEngineSettings.engineKindFor(section, comic),
          CatEngineKind.quickjs,
        );
      }
    });
  });

  group('引擎提供方登记表（扩展点）', () {
    test('默认登记：本机（非 Android）只有 QuickJS 一项，且原生不可用时不可用', () {
      expect(SourceEngineRegistry.isRegistered(CatEngineKind.quickjs), isTrue);
      expect(
        SourceEngineRegistry.isRegistered(CatEngineKind.nodeMobile),
        isFalse,
        reason: 'Node-Mobile 只在 Android 构建登记',
      );
      // Windows 上没有 QuickJS 原生库（Phase1 口径：仅 iOS）。
      expect(SourceEngineRegistry.isAvailable(CatEngineKind.quickjs), isFalse);
    });

    test('可覆盖登记项：造引擎走端口，不改注册表调用方', () async {
      final created = <String>[];
      SourceEngineRegistry.register(CatEngineKind.nodeMobile, ({
        required String sourceId,
        required LumeHttp http,
        required Section section,
      }) async {
        created.add('$sourceId@${section.id}');
        return _FakeEngine(CatEngineKind.nodeMobile.id);
      });

      final engine = await SourceEngineRegistry.create(
        kind: CatEngineKind.nodeMobile,
        sourceId: 'cat-1',
        http: LumeHttp(),
        section: Section.cat,
      );

      expect(engine, isNotNull);
      expect(engine!.id, CatEngineKind.nodeMobile.id);
      expect(created, <String>['cat-1@cat']);
    });
  });

  group('引擎设置页', () {
    Future<void> pumpPage(
      WidgetTester tester, {
      required CatEngineSettings settings,
      required Map<CatEngineKind, bool> ready,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: CatEngineSettingsPage(
            settings: settings,
            probe: () async => ready,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出两套引擎；不可用项置灰且点击无效', (tester) async {
      CatEngines.debugPlatformOverride = 'android';
      final settings = await CatEngineSettings.open();

      await pumpPage(
        tester,
        settings: settings,
        ready: const <CatEngineKind, bool>{
          CatEngineKind.quickjs: true,
          CatEngineKind.nodeMobile: false,
        },
      );

      expect(find.text('QuickJS-NG'), findsOneWidget);
      expect(find.text('Node-Mobile'), findsOneWidget);
      expect(find.text('本机不可用'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // 置灰项不可点：点击不产生任何变化（设计行为，而不是静默失败）。
      await tester.tap(find.text('Node-Mobile'));
      await tester.pumpAndSettle();
      expect(settings.load(), CatEngineKind.quickjs, reason: '不可用项不会被选中');
      expect(find.textContaining('已切换为'), findsNothing);
    });

    testWidgets('切换引擎：落库并提示下次生效', (tester) async {
      CatEngines.debugPlatformOverride = 'android';
      final settings = await CatEngineSettings.open();

      await pumpPage(
        tester,
        settings: settings,
        ready: const <CatEngineKind, bool>{
          CatEngineKind.quickjs: true,
          CatEngineKind.nodeMobile: true,
        },
      );

      await tester.tap(find.text('Node-Mobile'));
      await tester.pumpAndSettle();

      expect(find.text('已切换为 Node-Mobile，下次打开源时生效'), findsOneWidget);
      expect(settings.load(), CatEngineKind.nodeMobile);

      final checkOn = find.descendant(
        of: find.ancestor(
          of: find.text('Node-Mobile'),
          matching: find.byType(GlassCard),
        ),
        matching: find.byIcon(Icons.check_circle),
      );
      expect(checkOn, findsOneWidget);
    });
  });

  group('板块页入口（只属于 Android 的猫源）', () {
    Future<void> pumpSection(
      WidgetTester tester,
      Section section,
      FakeSourceManager manager,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: SourceSectionPage(section: section, manager: manager),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Android 猫源：显示引擎入口并进入设置页', (tester) async {
      CatEngines.debugPlatformOverride = 'android';
      await pumpSection(tester, Section.cat, FakeSourceManager());

      expect(find.byTooltip('猫源引擎'), findsOneWidget);
      await tester.tap(find.byTooltip('猫源引擎'));
      // 目标页会先渲染加载态（无限动画），因此按步长推帧而不是 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.widgetWithText(AppBar, '猫源引擎'), findsOneWidget);
    });

    testWidgets('Android 非猫源板块：没有引擎入口', (tester) async {
      CatEngines.debugPlatformOverride = 'android';
      await pumpSection(tester, Section.novel, FakeSourceManager());

      expect(find.byTooltip('猫源引擎'), findsNothing);
    });

    testWidgets('iOS 猫源：入口隐藏（任务书第 4 条）', (tester) async {
      CatEngines.debugPlatformOverride = 'ios';
      await pumpSection(tester, Section.cat, FakeSourceManager());

      expect(find.byTooltip('猫源引擎'), findsNothing);
    });
  });
}

/// 最小引擎替身：只用于验证「造引擎经端口」这一条。
class _FakeEngine implements SourceEngine {
  _FakeEngine(this.id);

  @override
  final String id;

  @override
  Future<bool> loadScript(String script) async => true;

  @override
  String? get loadFailure => null;

  @override
  Future<Map<String, Object?>?> metadata() async => null;

  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) async =>
      const SandboxSuccess(null);

  @override
  void dispose() {}
}
