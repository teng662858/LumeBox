import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_page.dart';

import 'support/fake_source_manager.dart';

/// 键盘弹起时，**顶部搜索框必须还在屏幕里**（真机反馈过两次）。
///
/// 这一份走**真实板块页结构**（GlassScaffold 顶栏 + 页签条 + ExploreView 的内容区），
/// 而不是单独挂 ExploreView——真机上出问题的正是「外层 Scaffold 收缩 + 内层固定
/// 头部」这套组合。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_board_kb');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    LumeJsEngine.debugSupportedOverride = true;
    await SectionScope.open(Section.video);
  });

  tearDown(() async {
    LumeJsEngine.debugSupportedOverride = null;
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('视频板块：点搜索框 → 键盘弹起后搜索框仍在屏幕内', (tester) async {
    // iPhone 14 几何：390×844pt，刘海 59，底部 34，键盘 320。
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPage(
          catalog: const _NoKernelCatalog(),
          sourceManager: FakeSourceManager(
            sources: const <SourceDescriptor>[
              SourceDescriptor(id: 'a', name: '示例源', version: '1.0', enabled: true),
            ],
            opened: <String, DataSource>{'a': MockDataSource(section: Section.video)},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点「搜索」→ 选范围（用户口径：先选模式再开输入框）。
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前源搜索'));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    expect(field, findsOneWidget, reason: '搜索框要出现');
    final before = tester.getRect(field);
    expect(before.top, greaterThanOrEqualTo(0), reason: '搜索框在屏幕内');

    // 弹键盘：搜索框不能被顶出屏幕、也不该被键盘盖住。
    const keyboard = 320.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * 3);
    await tester.pumpAndSettle();

    final keyboardTop = 844 - keyboard;
    final after = tester.getRect(find.byType(TextField));
    expect(
      after.top,
      greaterThanOrEqualTo(0),
      reason: '键盘弹起后搜索框仍在屏幕内（before=${before.top}, after=${after.top}）',
    );
    expect(
      after.bottom,
      lessThanOrEqualTo(keyboardTop),
      reason: '搜索框不被键盘盖住（bottom=${after.bottom}, 键盘顶沿=$keyboardTop）',
    );

    // 搜索范围要能切换（用户反馈切不了）：点输入框右侧的模式标签。
    await tester.tap(find.widgetWithText(TextButton, '当前源搜索'));
    await tester.pumpAndSettle();
    expect(find.text('聚合搜索'), findsOneWidget, reason: '切换菜单要出现');
    final option = tester.getRect(find.text('聚合搜索'));
    expect(
      option.bottom,
      lessThanOrEqualTo(keyboardTop),
      reason: '菜单浮在键盘之上（bottom=${option.bottom}, 键盘顶沿=$keyboardTop）',
    );
    await tester.tap(find.text('聚合搜索'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('搜索全部已启用源'),
      findsOneWidget,
      reason: '切换后输入框提示要跟着变（模式真的切了）',
    );
  });
}

/// 三套内核都不可用（本用例只看布局）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '${kernel.label} 未接入';
}
