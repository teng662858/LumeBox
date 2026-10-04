import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/app.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/theme/lume_theme.dart';

void main() {
  testWidgets('首页展示项目名称与四个板块入口', (tester) async {
    await tester.pumpWidget(const LumeBoxApp());

    expect(find.text(LumeTheme.appName), findsWidgets);
    for (final section in Section.values) {
      expect(find.text(section.label), findsOneWidget);
    }
  });

  testWidgets(
    '非 iOS 平台进入板块只显示空页面骨架',
    (tester) async {
      await tester.pumpWidget(const LumeBoxApp());

      await tester.tap(find.text(Section.novel.label));
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
    skip: Platform.isIOS,
  );

  testWidgets(
    '首页可进入全局图源总管理页',
    (tester) async {
      await tester.pumpWidget(const LumeBoxApp());

      await tester.tap(find.byTooltip('图源总管理'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '图源总管理'), findsOneWidget);
      // 没有图源运行时的平台：总管理页同样是骨架，不提供导入入口。
      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
    },
    skip: Platform.isIOS,
  );

  testWidgets('板块页标题显示对应板块名称', (tester) async {
    // 默认测试视口放不下四个板块卡片，放大后再逐个进入。
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const LumeBoxApp());

    for (final section in Section.values) {
      await tester.tap(find.text(section.label));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppBar, section.label),
        findsOneWidget,
        reason: '${section.label} 页面标题应为板块名称',
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
