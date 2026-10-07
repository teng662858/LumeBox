import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox_policy.dart';
import 'package:lume_box/core/js/sandbox_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/features/settings/settings_page.dart';


/// 全局沙箱超时（文档第 4 条点名的可配项）。
///
/// 交付的是「设置页能改超时、改了真的生效、且**只能**改超时」：
/// - 落盘往返与区间收敛；
/// - 图源引擎装配时取的就是这份设置（改完新建的引擎按新值运行）；
/// - 安全上限（内存 / 栈 / 指令计数 / 宿主调用数）**不随超时一起变**——
///   这是本设计最要紧的一条：可配项只影响它该影响的那一项。
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

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_sandbox_settings');
    mockPathProvider(root.path);
    SandboxSettingsStore.resetForTesting();
    LumeSandboxSettings.resetForTesting();
    LumeLog.clear();
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    SandboxSettingsStore.resetForTesting();
    LumeSandboxSettings.resetForTesting();
    await SectionScope.closeAll();
    mockPathProvider(null);
    LumeLog.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('设置模型：区间收敛与落盘', () {
    test('默认是 6 秒（区间 3–10，真机反馈后放宽）', () {
      expect(SandboxSettings.defaultTimeout, const Duration(seconds: 6));
      expect(const SandboxSettings().timeout, const Duration(seconds: 6));
      expect(SandboxSettings.minTimeout, const Duration(seconds: 3));
      expect(SandboxSettings.maxTimeout, const Duration(seconds: 10));
    });

    test('越界值被钳到区间内（不给用户关掉保护的口子）', () {
      expect(
        const SandboxSettings(timeout: Duration(seconds: 1)).clamped().timeout,
        const Duration(seconds: 3),
        reason: '低于下沿钳到 3 秒',
      );
      expect(
        const SandboxSettings(timeout: Duration(seconds: 60)).clamped().timeout,
        const Duration(seconds: 10),
        reason: '高于上沿钳到 10 秒——调大超时等于让卡住的脚本占更久',
      );
      expect(
        const SandboxSettings(timeout: Duration(seconds: 5)).clamped().timeout,
        const Duration(seconds: 5),
        reason: '区间内的值原样保留',
      );
    });

    test('落盘往返：保存后重新打开读到的是保存值', () async {
      final store = await SandboxSettingsStore.open();
      store.save(const SandboxSettings(timeout: Duration(seconds: 5)));

      SandboxSettingsStore.resetForTesting();
      final reopened = await SandboxSettingsStore.open();
      expect(reopened.load().timeout, const Duration(seconds: 5));
    });

    test('落盘时也收敛：写进去的越界值不会生效', () async {
      final store = await SandboxSettingsStore.open();
      store.save(const SandboxSettings(timeout: Duration(seconds: 30)));
      expect(store.load().timeout, const Duration(seconds: 10));
    });

    test('文件缺失 / 损坏时回退默认，不让沙箱起不来', () async {
      final store = await SandboxSettingsStore.open();
      File(store.path).writeAsStringSync('{ 这不是 JSON');
      expect(store.load().timeout, SandboxSettings.defaultTimeout);

      File(store.path).writeAsStringSync('{"timeoutMs": "abc"}');
      expect(store.load().timeout, SandboxSettings.defaultTimeout);
    });
  });

  group('可配项只影响超时：安全上限必须原样', () {
    test('策略只改超时，其余与标准预设逐项相同', () {
      const custom = SandboxSettings(timeout: Duration(seconds: 5));
      final policy = custom.policy();

      expect(policy.timeout, const Duration(seconds: 5));
      // 逐项核对：这些是防死循环 / 防内存失控的兜底，不许跟着超时一起变。
      expect(policy.memoryLimitBytes, SandboxPolicy.standard.memoryLimitBytes);
      expect(policy.stackLimitBytes, SandboxPolicy.standard.stackLimitBytes);
      expect(policy.maxInstructions, SandboxPolicy.standard.maxInstructions);
      expect(policy.maxHostCalls, SandboxPolicy.standard.maxHostCalls);
      expect(policy.maxSteps, SandboxPolicy.standard.maxSteps);
      expect(policy.maxJobRounds, SandboxPolicy.standard.maxJobRounds);
      expect(policy.maxTimers, SandboxPolicy.standard.maxTimers);
      expect(policy.maxResultChars, SandboxPolicy.standard.maxResultChars);
      expect(policy.allowHostAccess, SandboxPolicy.standard.allowHostAccess);
      expect(
        policy.poisonOnScriptError,
        SandboxPolicy.standard.poisonOnScriptError,
      );
    });

    test('栈上限没有被超时配置动过（这是已实测的崩溃开关）', () {
      // SandboxPolicy 的注释记着实测：栈上限调到 1MB 会让进程当场死亡。
      // 本用例钉住「改超时不会顺带改栈上限」这条不变式。
      const custom = SandboxSettings(timeout: Duration(seconds: 5));
      expect(
        custom.policy().stackLimitBytes,
        512 * 1024,
        reason: '栈上限必须保持 512KB（1MB 实测会让进程当场死亡）',
      );
    });
  });

  group('引擎真的用这份设置', () {
    test('引擎装配取的是全局设置（改完立即对新建引擎生效）', () async {
      // 默认 6 秒（真机反馈后从 4 秒放宽）。
      expect(LumeJsEngine.callTimeout, const Duration(seconds: 6));
      expect(LumeJsEngine.policy.timeout, const Duration(seconds: 6));

      // 改成 5 秒。
      LumeSandboxSettings.apply(const SandboxSettings(timeout: Duration(seconds: 5)));
      expect(LumeJsEngine.callTimeout, const Duration(seconds: 5));
      expect(LumeJsEngine.policy.timeout, const Duration(seconds: 5));
      expect(
        LumeJsEngine.policy.memoryLimitBytes,
        SandboxPolicy.standard.memoryLimitBytes,
        reason: '改超时不该动内存上限',
      );

      // 保存路径同样生效。
      await LumeSandboxSettings.save(
        const SandboxSettings(timeout: Duration(seconds: 3)),
      );
      expect(LumeJsEngine.callTimeout, const Duration(seconds: 3));
    });

    test('越界值经由 save 进来也会被收敛', () async {
      await LumeSandboxSettings.save(
        const SandboxSettings(timeout: Duration(seconds: 99)),
      );
      // 99 秒越界 → 收敛到新的上沿 10 秒（不再是不能改的保护口径，只是防呆上限）。
      expect(LumeJsEngine.callTimeout, const Duration(seconds: 10));
    });
  });

  group('设置页', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('设置页有「沙箱设置」入口，点进去能改超时', (tester) async {
      await pumpSettings(tester);

      expect(find.text('沙箱设置'), findsOneWidget);
      await tester.tap(find.text('沙箱设置'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '沙箱设置'), findsOneWidget);
      expect(find.text('JS 执行超时'), findsOneWidget);
      // 三档都在。
      expect(find.text('3 秒'), findsOneWidget);
      expect(find.text('4 秒'), findsOneWidget);
      expect(find.text('5 秒'), findsOneWidget);
    });

    testWidgets('选 5 秒并保存：真的写进设置', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('沙箱设置'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('5 秒'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      expect(LumeSandboxSettings.current.timeout, const Duration(seconds: 5));
      expect(
        find.textContaining('新建的源引擎按新超时运行'),
        findsOneWidget,
        reason: '要说清生效时机（改完不是立刻掐断在跑的脚本）',
      );
    });

    testWidgets('页面说明了「其余上限不可调」的理由', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.text('沙箱设置'));
      await tester.pumpAndSettle();

      expect(find.text('固定安全上限（不可调）'), findsOneWidget);
      expect(
        find.textContaining('防死循环与防内存失控'),
        findsOneWidget,
        reason: '要给出理由，免得用户以为是自己没找到入口',
      );
    });
  });
}
