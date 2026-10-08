import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_module_settings.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/module_settings_pages.dart';

/// 「各模块独立设置」（用户口径）：
/// - 四个模块各一个入口，页内按五个**可折叠分组**组织；
/// - 参数**按板块分开存**：改小说的不动漫画的（各存各的库）；
/// - 与阅读 / 播放页的就地设置读写同一份数据（双向同步）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_module_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpHub(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: const ModuleSettingsHubPage()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpSection(WidgetTester tester, Section section) async {
    await tester.binding.setSurfaceSize(const Size(440, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SectionModuleSettingsPage(section: section),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('四个模块入口都在', (tester) async {
    await pumpHub(tester);
    expect(find.text('小说设置'), findsOneWidget);
    expect(find.text('漫画设置'), findsOneWidget);
    expect(find.text('视频设置'), findsOneWidget);
    expect(find.text('猫源设置'), findsOneWidget);
  });

  testWidgets('五个分组都在，且默认**收起**（不把设置堆一页）', (tester) async {
    await pumpSection(tester, Section.comic);
    for (final title in <String>['UI 与控件', '手势 & 触发灵敏度', '内容排版', '阅读 / 播放行为', '高级']) {
      expect(find.text(title), findsOneWidget, reason: '缺分组：$title');
    }
    // 收起态：组内的滑杆还没出现（展开了才建）。
    expect(find.byType(Slider), findsNothing);

    await tester.tap(find.text('手势 & 触发灵敏度'));
    await tester.pumpAndSettle();
    expect(find.text('呼出工具栏延时'), findsOneWidget);
  });

  testWidgets('参数按板块隔离：改漫画的不动小说（各存各的库）', (tester) async {
    final comicLibrary = await ReadingLibrary.open(Section.comic);
    final novelLibrary = await ReadingLibrary.open(Section.novel);

    // 漫画这边改呼出延时。
    SectionModuleSettings()
        .copyWith(toolbarToggleDelayMs: 520)
        .save(comicLibrary);

    expect(
      SectionModuleSettings.load(comicLibrary).toolbarToggleDelayMs,
      520,
    );
    expect(
      SectionModuleSettings.load(novelLibrary).toolbarToggleDelayMs,
      SectionModuleSettings.defaultToolbarToggleDelayMs,
      reason: '小说板块必须还是默认值——两边是两套库',
    );
  });

  test('落盘往返：越界值钳到区间，旧配置缺项回退默认', () {
    final parsed = SectionModuleSettings.fromJson(<String, Object?>{
      'toggleDelayMs': 99999,
      'doubleTapMs': 10,
      'swipeThresholdPx': -4,
      'controlScale': 9.9,
      'preset': 'roomy',
    });
    expect(parsed.toolbarToggleDelayMs, SectionModuleSettings.maxToolbarToggleDelayMs);
    expect(parsed.doubleTapWindowMs, SectionModuleSettings.minDoubleTapWindowMs);
    expect(parsed.swipeTurnThresholdPx, SectionModuleSettings.minSwipeTurnThresholdPx);
    expect(parsed.controlScale, SectionModuleSettings.maxControlScale);
    expect(parsed.layoutPreset, ModuleLayoutPreset.roomy);
    expect(parsed.animationEnabled, isTrue, reason: '缺项回退默认');
  });

  test('预制方案：选一套就带上尺寸与间距（不开放自定义坐标）', () {
    final compact = const SectionModuleSettings().withPreset(ModuleLayoutPreset.compact);
    expect(compact.controlScale, ModuleLayoutPreset.compact.controlScale);
    expect(compact.spacingScale, ModuleLayoutPreset.compact.spacingScale);
    expect(compact.layoutPreset, ModuleLayoutPreset.compact);
  });
}
