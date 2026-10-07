import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/cache_settings_page.dart';
import 'package:lume_box/features/settings/debug_panel_page.dart';
import 'package:lume_box/features/settings/log_report.dart';
import 'package:lume_box/features/settings/log_report_page.dart';
import 'package:lume_box/features/settings/log_viewer_page.dart';
import 'package:lume_box/features/settings/network_settings_page.dart';
import 'package:lume_box/features/settings/sandbox_settings_page.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/source_generator_page.dart';
import 'package:lume_box/features/source/global_source_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/features/video/player_settings_page.dart';

import 'support/fake_source_manager.dart';

/// **窄屏 × 双主题**的布局体检：真机验收的「无 UI 错乱」。
///
/// ## 为什么必须有这一组
///
/// 本轮真机验收准备阶段实测发现：**四个页面在 iPhone SE（320pt）宽度下横向溢出**
/// （生成器 17px / 板块源管理 121px / 错误报告 13px / 源总管理 6px），
/// 而此前所有页面用例都跑在 900×1400 这种比手机宽得多的画布上，**一个都没测出来**。
/// 溢出在真机上表现为黄黑条纹（Release 下是内容被裁掉），正是验收单要查的
/// 「UI 错乱」。因此这组用例的价值不在「再测一遍」，而在**把画布换成真机尺寸**。
///
/// ## 两个关键口径（踩过的坑）
///
/// 1. **必须设 `tester.view.physicalSize`，不能只用 `setSurfaceSize`**：
///    `setSurfaceSize` 只改渲染面，**不改 MediaQuery**（实测仍报 800×600）。
///    而窄屏适配代码读的正是 MediaQuery（`_FieldRow` 的 `stackBelow`），
///    用 `setSurfaceSize` 测等于没测——第一次扫描就是这么漏掉生成的溢出的。
/// 2. **每个页面必须单独 pump、单独收集错误**：`FlutterError.onError` 收集器
///    在同一个测试体内连续扫描多个页面时会串味（前一页的错误被算到后一页），
///    实测导致「同一页面 dark 溢出、light 正常」这种假象。
///
/// ## 覆盖
///
/// 宽 320（iPhone SE / 老机型）与 390（主流机型）× 亮/暗两套主题，
/// 覆盖本轮新增页面与全部设置类页面。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_narrow');
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

  /// 一组带满标记的图源：名称很长 + 已停用 + 已失效 + 分组 + 订阅。
  ///
  /// 刻意把「所有标记同时出现」造出来——单看每个标记都不宽，六个叠在一起才是
  /// 320pt 下溢出的真实成因（实测板块源管理溢出 121px）。
  List<SourceDescriptor> crowdedSources() => <SourceDescriptor>[
        for (var i = 0; i < 6; i++)
          SourceDescriptor(
            id: 's$i',
            name: '一个相当长的图源名称用于验证窄屏省略号 $i',
            version: '1.0.$i',
            enabled: i.isEven,
            originUrl: i.isEven ? 'https://example.com/$i.js' : '',
            group: i.isEven ? '主力' : '',
            failureCount: i == 0 ? 3 : 0,
            broken: i == 0,
          ),
      ];

  /// 扫描一个页面在指定宽度 / 亮度下是否有布局错误。
  ///
  /// 返回错误列表（空 = 干净）。**用 `tester.view` 设真实屏幕尺寸**，
  /// 让 MediaQuery 与真机一致（见文件头说明）。
  Future<List<String>> scan(
    WidgetTester tester,
    Widget page, {
    required double width,
    required Brightness brightness,
  }) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString().split('\n').first);
    };
    try {
      tester.view.physicalSize = Size(width * 3, 3000 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      LumeTheme.applyBrightness(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(brightness: brightness),
          home: page,
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  /// 对一组页面做全宽度 × 全亮度扫描，逐个页面单独 pump。
  void sweep(String group, Map<String, Widget Function()> pages) {
    for (final entry in pages.entries) {
      for (final width in <double>[320, 390]) {
        for (final brightness in Brightness.values) {
          testWidgets(
            '$group · ${entry.key} · ${width.toInt()}pt · ${brightness.name}',
            (tester) async {
              final errors = await scan(
                tester,
                entry.value(),
                width: width,
                brightness: brightness,
              );
              expect(
                errors,
                isEmpty,
                reason: '${entry.key} 在 ${width.toInt()}pt / ${brightness.name} 下'
                    '出现布局错误（真机表现为黄黑条纹或内容被裁）：\n'
                    '${errors.join('\n')}',
              );
            },
          );
        }
      }
    }
  }

  // 本轮新增页面。
  sweep('新增页面', <String, Widget Function()>{
    '沙箱设置': () => const SandboxSettingsPage(),
    '调试面板': () => const DebugPanelPage(),
    '图源生成器': () => const SourceGeneratorPage(),
    '设置页': () => const SettingsPage(runtimeAvailable: true),
    '播放器设置': () => PlayerSettingsPage(
          settings: const PlayerSettings(),
          catalog: const PlatformPlayerKernelCatalog(),
          onChanged: (_) {},
        ),
  });

  // 设置类与图源管理页（含带满标记的图源列表）。
  sweep('设置与图源管理', <String, Widget Function()>{
    '网络设置': () => const NetworkSettingsPage(),
    '缓存管理': () => const CacheSettingsPage(),
    '运行日志': () => LogViewerPage(exporter: const LogExporter()),
    '错误报告': () => LogReportPage(exporter: const LogExporter()),
    '源总管理': () => GlobalSourcePage(
          managerFactory: (_) => FakeSourceManager(sources: crowdedSources()),
        ),
    '板块源管理': () => SourceSectionPage(
          section: Section.novel,
          manager: FakeSourceManager(sources: crowdedSources()),
        ),
  });
}
