import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';

import 'support/fake_source_manager.dart';

/// 公共浏览页（小说 / 漫画 / 视频三块共用 ExploreView）的键盘布局回归。
///
/// 真机反馈：唤起软键盘后**顶部搜索框被顶出屏幕**，三块都复现。
/// 要求是「搜索栏锁死在导航栏下方，键盘只挤压下方列表」。
///
/// 这里对三个板块各跑一遍，守两条：
///   1. 键盘弹起前后，搜索框的矩形**不动**，且完整落在键盘顶沿之上；
///   2. 不产生布局溢出异常。
void main() {
  const sections = <Section>[Section.novel, Section.comic, Section.video];

  for (final section in sections) {
    testWidgets('${section.label}：唤起键盘后搜索框仍在屏幕内且不移位', (tester) async {
      // iPhone 14 几何：390×844pt，刘海 59，底部 34，键盘 320。
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
      tester.view.viewInsets = FakeViewPadding.zero;
      addTearDown(tester.view.reset);

      final cacheDir = Directory.systemTemp.createTempSync('lume_box_explore_kb');
      addTearDown(() {
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });
      final pipeline = SectionImagePipeline(cacheDir: cacheDir.path);
      addTearDown(pipeline.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            // 与正式壳层同构：底部有悬浮 Dock（extendBody + bottomNavigationBar）。
            extendBody: true,
            body: ExploreView(
              section: section,
              pipeline: pipeline,
              layout: section == Section.comic
                  ? ExploreLayout.grid
                  : ExploreLayout.list,
              manager: FakeSourceManager(
                sources: <SourceDescriptor>[
                  const SourceDescriptor(
                    id: 'a',
                    name: '示例源',
                    version: '1.0',
                    enabled: true,
                  ),
                ],
                opened: <String, DataSource>{
                  'a': MockDataSource(section: section),
                },
              ),
              onOpenItem: (_) {},
            ),
            bottomNavigationBar: const SizedBox(height: 100),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      expect(field, findsOneWidget, reason: '搜索行应当已经展开');
      final before = tester.getRect(field);

      // 弹键盘。
      const keyboard = 320.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * 3);
      await tester.pumpAndSettle();

      const screenHeight = 844.0;
      final keyboardTop = screenHeight - keyboard;

      expect(
        tester.takeException(),
        isNull,
        reason: '键盘弹起不该在浏览页产生布局溢出',
      );

      final after = tester.getRect(field);
      expect(
        after.top,
        greaterThanOrEqualTo(0),
        reason: '搜索框被顶到屏幕上方（top=${after.top}）',
      );
      expect(
        after.bottom,
        lessThanOrEqualTo(keyboardTop),
        reason: '搜索框被键盘盖住/顶下去了'
            '（bottom=${after.bottom}，键盘顶沿=$keyboardTop）',
      );
      expect(
        after,
        before,
        reason: '搜索栏是固定头部，键盘弹起前后位置不该变'
            '（前=$before，后=$after）',
      );
    });
  }
}
