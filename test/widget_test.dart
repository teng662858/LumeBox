import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/app.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/shell/app_shell.dart';

/// 应用入口的验证：启动直接进入五页签导航壳（不再有卡片仪表盘首页）、
/// 页签文案与顺序、板块页平台边界，以及设置里的图源总管理入口。
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const LumeBoxApp());
    await tester.pumpAndSettle();
  }

  /// 当前平台的排布：桌面端是左侧栏，移动端是底部 Dock。
  Finder navItemFinder() =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux
          ? find.byKey(AppShell.railKey)
          : find.byKey(AppShell.dockKey);

  Finder navItem(String label) => find.descendant(
        of: navItemFinder(),
        matching: find.text(label),
      );

  testWidgets('启动即导航壳：五个页签，文案为 小说 / 漫画 / 视频 / 猫源 / 设置', (tester) async {
    await pumpApp(tester);

    for (final label in <String>[
      Section.novel.label,
      Section.comic.label,
      Section.video.label,
      Section.cat.label,
      '设置',
    ]) {
      expect(navItem(label), findsOneWidget, reason: '导航缺少页签：$label');
    }

    // 旧的卡片仪表盘首页已移除：它当时把项目名放在每个卡片里。
    expect(find.text('自定义视频'), findsNothing);
    expect(find.widgetWithText(AppBar, '设置'), findsNothing);
  });

  testWidgets('板块页标题显示对应板块名称', (tester) async {
    await pumpApp(tester);

    for (final section in Section.values) {
      await tester.tap(navItem(section.label));
      await tester.pumpAndSettle();

      // 猫源板块页本身就是该板块的源管理页（标题用「· 源管理」口径），
      // 其余板块是内容页，标题就是板块名。
      final expectedTitle =
          section == Section.cat ? '${section.label} · 源管理' : section.label;
      expect(
        find.widgetWithText(AppBar, expectedTitle),
        findsOneWidget,
        reason: '${section.label} 页面标题应为 $expectedTitle',
      );
    }
  });

  testWidgets(
    '非 iOS 平台进入板块只显示空页面骨架，没有添加图源入口',
    (tester) async {
      await pumpApp(tester);

      await tester.tap(navItem(Section.novel.label));
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      expect(find.byTooltip('添加源'), findsNothing);
    },
    skip: Platform.isIOS,
  );
}
