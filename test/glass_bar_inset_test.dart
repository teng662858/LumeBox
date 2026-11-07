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
import 'package:lume_box/features/settings/settings_ui.dart';
import 'package:lume_box/features/settings/liquid_glass_settings_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/core/source/source.dart';

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

    await tester.pumpWidget(MaterialApp(theme: LumeTheme.build(), home: page));
    await tester.pumpAndSettle();
  }

  testWidgets('设置页：顶部不留整条空白', (tester) async {
    await pump(tester, const SettingsPage(runtimeAvailable: true));
    // 设置页第一个元素是「显示」分组的小标题（卡片在它下面），因此这里量的是
    // 标题到顶栏的距离：判据仍然是「16pt 一档，远小于一个栏高」。
    final barBottom = tester.getRect(find.byType(AppBar)).bottom;
    final firstTitle = tester.getRect(find.text('常用')).top;
    expect(
      firstTitle - barBottom,
      inInclusiveRange(0, 32),
      reason: '设置页顶部空隙应是一档常规间距；接近栏高说明顶栏高度被算了两遍',
    );
  });

  testWidgets('板块源管理：顶部不留整条空白', (tester) async {
    // 必须塞一个源：空态卡是**垂直居中**的，量出来的不是顶栏空隙。
    await pump(
      tester,
      SourceSectionPage(
        section: Section.video,
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
    final gap =
        tester.getRect(find.byType(TextField).first).top -
        tester.getRect(find.byType(AppBar)).bottom;
    expect(gap, inInclusiveRange(0, 32), reason: '搜索源入口应紧接顶栏');
  });

  testWidgets('底部导航栏管理（对照组，本来就传了 behindBar）', (tester) async {
    await pump(tester, const LiquidGlassSettingsPage());
    final gap =
        tester.getRect(find.byType(SettingsPageIntro).first).top -
        tester.getRect(find.byType(AppBar)).bottom;
    expect(gap, inInclusiveRange(0, 32));
  });
}
