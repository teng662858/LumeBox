import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';

import 'js_sandbox/support/js_sandbox_support.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/features/settings/log_report.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

/// 设置页面的验证：缓存管理（分板块统计与清理，互不影响）、运行日志查看、
/// 错误报告导出与复制，以及非 iOS 的骨架占位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  void mockPathProvider(String? path) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? path : null,
    );
  }

  void writeFile(String relative, int bytes) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_settings');
    mockPathProvider(root.path);
    LumeLog.clear();
    // 板块作用域必须在真实时钟里先打开：testWidgets 的测试体跑在 fake-async
    // 时钟里，首次打开要创建目录（真实异步），在测试体里 await 会等不到。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    LumeLog.clear();
    // 缓存管理页会打开各板块的阅读库（策略按板块存）：必须一起释放，
    // 否则 Windows 上临时目录被库句柄占着删不掉。
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    mockPathProvider(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 滚到目标行再断言 / 点击。
  ///
  /// 设置页比一屏长（新增分组会把诊断区推到折叠线以下），ListView 是懒构建的，
  /// 不滚过去就「找不到」——这不是功能坏了，是测试没滚。
  Future<void> scrollTo(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      260,
      scrollable: find.byType(Scrollable).first,
    );
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool runtimeAvailable = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SettingsPage(
          runtimeAvailable: runtimeAvailable,
          exporter: const LogExporter(now: _fixedNow),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder clearButtonOf(String sectionLabel) => find.descendant(
        of: find.ancestor(
          of: find.text(sectionLabel),
          matching: find.byType(GlassCard),
        ),
        matching: find.widgetWithText(TextButton, '清理'),
      );

  testWidgets('切到深色：设置页整页换色（含「显示」「播放」两张分组卡）', (tester) async {
    // 走**真实壳层**：设置页挂在 AppShell 的页签里，主题接线与 app.dart 一致
    // （theme + darkTheme + builder 里回写静态色名）。这正是真机那条路径：
    // 只读静态色名的部件不会随 ThemeData 自动重建，靠壳层按主题身份重建当前页签。
    Widget app(ThemeMode mode) => MaterialApp(
          theme: LumeTheme.build(brightness: Brightness.light),
          darkTheme: LumeTheme.build(brightness: Brightness.dark),
          themeMode: mode,
          builder: (context, child) {
            final brightness = Theme.of(context).brightness;
            LumeTheme.applyBrightness(brightness);
            return KeyedSubtree(
              key: ValueKey<String>(LumeTheme.themeId),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: AppShell(controller: ShellDockController(), desktopRail: false),
        );

    /// 某段文字所在的（最近的）GlassCard 的实际底色。
    Color? cardColorOf(String text) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find
                  .ancestor(
                    of: find.text(text),
                    matching: find.byType(GlassCard),
                  )
                  .first,
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (box.decoration as BoxDecoration).color;
    }

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 非 iOS 平台默认只看骨架；装上原生桥 + 打开源运行时开关，
    // 让壳层渲染**真实页面**（这正是真机那条路径）。装不上就跳过用例
    //（本机没有原生库时跑不了这条）。
    if (!installBridge()) {
      markTestSkipped('本机没有 QuickJS 原生库，跳过（真机路径由设备验收覆盖）');
      return;
    }
    LumeJsEngine.debugSupportedOverride = true;
    addTearDown(() => LumeJsEngine.debugSupportedOverride = null);

    await tester.pumpWidget(app(ThemeMode.light));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text('设置'),
      ),
    );
    await tester.pumpAndSettle();

    final light = LumeTheme.paletteOf(Brightness.light).surface;
    final dark = LumeTheme.paletteOf(Brightness.dark).surface;
    expect(cardColorOf('外观'), light);
    expect(cardColorOf('横屏播放'), light);

    // 切深色：整页（含两张内容为 const 的分组卡）当场换成深色卡。
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(LumeTheme.surface, dark, reason: '静态色名的活动色板要跟着亮度走');
    expect(
      cardColorOf('外观'),
      dark,
      reason: '「显示」分组卡要跟着变深（真机上它曾留在白底）',
    );
    expect(
      cardColorOf('横屏播放'),
      dark,
      reason: '「播放」分组卡要跟着变深（真机同款白底）',
    );
    expect(cardColorOf('底部导航栏管理'), dark);
  });

  testWidgets('缓存管理：分板块统计，清理只动所选板块', (tester) async {
    writeFile('sections/comic/reading_cache/images/a.img', 100);
    writeFile('sections/comic/reading_cache/exports/saved.png', 50);
    writeFile('sections/novel/reading_cache/images/b.img', 200);

    await pumpSettings(tester);
    await scrollTo(tester, '缓存管理');
    expect(find.text('缓存管理'), findsOneWidget);
    await scrollTo(tester, '运行日志');
    expect(find.text('运行日志'), findsOneWidget);
    await scrollTo(tester, '错误报告');
    expect(find.text('错误报告'), findsOneWidget);

    await scrollTo(tester, '缓存管理');
    await tester.tap(find.text('缓存管理'));
    await tester.pumpAndSettle();

    // 四个板块各一行；漫画显示缓存与已保存图片。
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('猫源'), findsOneWidget);
    expect(find.textContaining('缓存 100 B'), findsOneWidget);
    expect(find.text('已保存图片 50 B（不参与清理）'), findsOneWidget);

    await tester.tap(clearButtonOf('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('清理漫画缓存'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('清理')),
    );
    await tester.pumpAndSettle();

    expect(find.text('已清理 漫画 100 B 缓存'), findsOneWidget);
    expect(
      File('${root.path}/sections/comic/reading_cache/images/a.img').existsSync(),
      isFalse,
    );
    expect(
      File('${root.path}/sections/comic/reading_cache/exports/saved.png')
          .existsSync(),
      isTrue,
      reason: '用户保存的图片不参与清理',
    );
    expect(
      File('${root.path}/sections/novel/reading_cache/images/b.img').existsSync(),
      isTrue,
      reason: '小说板块的缓存不受漫画清理影响',
    );
    expect(find.text('缓存 200 B（1 个文件）'), findsOneWidget);
  });

  testWidgets('图源总管理：设置页内的子页面入口仍在', (tester) async {
    await pumpSettings(tester);

    expect(find.text('源总管理'), findsOneWidget);

    await tester.tap(find.text('源总管理'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '源总管理'), findsOneWidget);
  });

  testWidgets('播放器内核：全局设置里保留逃生入口', (tester) async {
    await pumpSettings(tester);

    // 逃生入口是**内嵌**在设置页里的（点得最少）：同一份内核列表直接可见。
    expect(find.text('播放器内核 · 故障逃生入口'), findsOneWidget);
    expect(find.text('AVPlayer'), findsOneWidget);
    expect(find.text('MPV'), findsOneWidget);
    expect(find.text('MDK'), findsOneWidget);

    // 播放器设置（内核 / 倍速 / 字幕）也从板块页迁到了全局设置。
    expect(find.text('播放器设置'), findsOneWidget);
    await tester.tap(find.text('播放器设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '播放器设置'), findsOneWidget);
    expect(find.text('播放倍速'), findsOneWidget);
    expect(find.text('字幕'), findsOneWidget);
  });

  testWidgets('运行日志：查看、按级别筛选、清空', (tester) async {
    LumeLog.info('普通一条');
    LumeLog.warn('警告一条');
    LumeLog.error(StateError('错误一条'), StackTrace.current);

    await pumpSettings(tester);
    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();

    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('信息 1'), findsOneWidget);
    expect(find.text('警告 1'), findsOneWidget);
    expect(find.text('错误 1'), findsOneWidget);

    await tester.tap(find.text('错误 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('错误一条'), findsOneWidget);
    expect(find.text('警告一条'), findsNothing);

    await tester.tap(find.byTooltip('清空日志'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('错误报告：概览、导出文件、结果卡', (tester) async {
    LumeLog.error(StateError('报告错误'), StackTrace.current);
    LumeLog.warn('报告警告');

    await pumpSettings(tester);
    await scrollTo(tester, '错误报告');
    await tester.tap(find.text('错误报告'));
    await tester.pumpAndSettle();

    expect(find.text('发现 1 个错误、1 个警告'), findsOneWidget);

    await tester.tap(find.text('导出报告文件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已导出报告：2 条日志'), findsOneWidget);
    final path = '${root.path}${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}log_report_20261004_213310.txt';
    expect(find.text(path), findsOneWidget);
    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('报告错误'));
  });

  testWidgets('错误报告：复制全文到剪贴板', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    LumeLog.warn('要复制的警告');
    await pumpSettings(tester);
    await scrollTo(tester, '错误报告');
    await tester.tap(find.text('错误报告'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制报告全文'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('要复制的警告'));
    expect(find.textContaining('已复制报告全文'), findsOneWidget);
  });

  testWidgets('错误报告：导出失败给出可读提示', (tester) async {
    LumeLog.error(StateError('x'));

    await pumpSettings(tester);
    await scrollTo(tester, '错误报告');
    await tester.tap(find.text('错误报告'));
    await tester.pumpAndSettle();

    // 让应用目录拿不到：导出应失败并给出提示，而不是抛到界面外。
    mockPathProvider(null);
    await tester.tap(find.text('导出报告文件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出失败'), findsOneWidget);
  });

  testWidgets(
    '非 iOS：设置只保留骨架占位',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: LumeTheme.build(), home: const SettingsPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      expect(find.text('源总管理'), findsNothing);
      expect(find.text('缓存管理'), findsNothing);
      expect(find.text('运行日志'), findsNothing);
      expect(find.text('错误报告'), findsNothing);
    },
    skip: Platform.isIOS,
  );

  test('Section 顺序与设置页展示一致（防未来加板块时漏行）', () {
    // 展示文案（label）与内部标识（id）是两回事：视频板块显示「视频」，
    // 但库、缓存、图源归属仍走 id 'video'。
    expect(Section.values.map((section) => section.label).toList(), <String>[
      '小说',
      '漫画',
      '视频',
      '猫源',
    ]);
    expect(Section.values.map((section) => section.id).toList(), <String>[
      'novel',
      'comic',
      'video',
      'cat',
    ]);
  });
}

DateTime _fixedNow() => DateTime(2026, 10, 4, 21, 33, 10);
