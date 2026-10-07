import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/source_generator_page.dart';
import 'package:lume_box/features/settings/tab_bar_settings_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_source_manager.dart';

/// 「玻璃顶栏高度被算两遍」的回归（真机实测：设置页首卡离顶栏 131pt，应 16pt）。
///
/// 机制：页面用 `GlassScaffold.barInset(context)` 给列表留出让位空间——那是给
/// **穿栏**（`behindBar: true`，内容从磨砂顶栏底下滚过去）用的。若某页漏了
/// `behindBar: true`，`SafeArea` 会先让一次栏高、`barInset` 再让一次，
/// 于是首屏上方出现一整条空白（真机上就是「上面空白太多、上下比例不对」）。
///
/// 这条用例不看具体像素值，只守一件事：**首块内容与顶栏之间的空隙应当在
/// 「一档常规间距」量级**（这里是 16pt），而不是一整个栏高。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_bar_inset');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    ShellSettingsController.instance.resetForTesting();
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    ShellSettingsController.instance.resetForTesting();
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

  /// 按 iPhone 14 的几何量：390×844pt，刘海 59pt，底部 34pt。
  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: page),
    );
    await tester.pumpAndSettle();
  }

  /// 顶栏下沿到首块内容之间的空隙。
  double topGap(WidgetTester tester) {
    final barBottom = tester.getRect(find.byType(AppBar)).bottom;
    final firstCard = tester.getRect(find.byType(GlassCard).first);
    return firstCard.top - barBottom;
  }

  /// 允许的区间：16pt 的常规间距，给排版的上下浮动留一点余量。
  /// 上界 32 远小于一个栏高（59+56=115），因此「被算两遍」必然被抓住。
  void expectNormalGap(WidgetTester tester, String label) {
    final gap = topGap(tester);
    expect(
      gap,
      inInclusiveRange(0, 32),
      reason: '$label 的顶部空隙应当是一档常规间距（约 16pt），'
          '实测 ${gap}pt——若接近一个栏高（约 115pt），'
          '说明 SafeArea 与 barInset 各让了一次（漏了 behindBar: true）',
    );
  }

  testWidgets('设置页：顶部不留整条空白', (tester) async {
    await pump(tester, const SettingsPage(runtimeAvailable: true));
    expectNormalGap(tester, '设置页');
  });

  testWidgets('图源生成器：顶部不留整条空白', (tester) async {
    await pump(tester, const SourceGeneratorPage());
    expectNormalGap(tester, '图源生成器');
  });

  testWidgets('板块源管理：顶部不留整条空白', (tester) async {
    // 必须塞一个源：空态卡是**垂直居中**的，量出来的不是顶栏空隙。
    await pump(
      tester,
      SourceSectionPage(
        section: Section.novel,
        manager: FakeSourceManager(
          sources: <SourceDescriptor>[
            const SourceDescriptor(
              id: 'a',
              name: '示例源',
              version: '1.0',
              enabled: true,
            ),
          ],
        ),
      ),
    );
    expectNormalGap(tester, '板块源管理');
  });

  testWidgets('底部导航栏管理（对照组，本来就传了 behindBar）', (tester) async {
    await pump(tester, const TabBarSettingsPage());
    expectNormalGap(tester, '底部导航栏管理');
  });
}
