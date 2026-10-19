import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/poster_card.dart';

void main() {
  const item = SourceItem(
    id: 'a',
    title: '仙逆剧场版 弑仙之战',
    subtitle: '评分 8.4 · 蓝光',
    duration: Duration(hours: 2, minutes: 25),
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('首页单列：80×100 封面、简介/时长、三点菜单', (tester) async {
    await pump(
      tester,
      CompactSourceItemTile(
        item: item,
        onTap: () {},
        columns: 1,
        coverWidth: 80,
        coverHeight: 100,
        flat: true,
        showMenu: true,
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('source-tile-cover'))),
      const Size(80, 100),
    );
    final coverClip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byKey(const ValueKey('source-tile-cover')),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(coverClip.borderRadius, kPosterCoverRadius, reason: '单列缩略图四角圆角');
    expect(find.byKey(const ValueKey('source-tile-menu')), findsOneWidget);
    expect(find.text('评分 8.4 · 蓝光'), findsOneWidget);
    expect(find.text('2:25:00'), findsOneWidget);
  });

  testWidgets('首页双列：60×80 封面、紧凑且不塞三点菜单', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 174,
        child: CompactSourceItemTile(
          item: item,
          onTap: () {},
          columns: 2,
          coverWidth: 60,
          coverHeight: 80,
          showMenu: false,
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('source-tile-cover'))),
      const Size(60, 80),
    );
    final coverClip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byKey(const ValueKey('source-tile-cover')),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(coverClip.borderRadius, kPosterCoverRadius, reason: '双列缩略图四角圆角');
    expect(find.byKey(const ValueKey('source-tile-menu')), findsNothing);
    expect(find.text('评分 8.4 · 蓝光'), findsOneWidget);
  });

  for (final width in [320.0, 390.0, 430.0, 768.0, 1024.0]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('双列列表适配 $width 宽、$textScale 字号，保持两列和封面比例', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TwoColumnSourceLayout.sidePadding,
                  ),
                  itemCount: 6,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: TwoColumnSourceLayout.spacing,
                    mainAxisSpacing: TwoColumnSourceLayout.rowSpacing,
                    mainAxisExtent: TwoColumnSourceLayout.itemExtent(
                      context,
                      TwoColumnSourceLayout.cellWidth(constraints.maxWidth),
                    ),
                  ),
                  itemBuilder: (_, _) =>
                      TwoColumnSourceItemTile(item: item, onTap: () => taps++),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cells = find.byType(TwoColumnSourceItemTile);
        final first = tester.getRect(cells.at(0)),
            second = tester.getRect(cells.at(1));
        expect(first.left, TwoColumnSourceLayout.sidePadding);
        expect(second.top, first.top);
        expect(second.left - first.right, TwoColumnSourceLayout.spacing);
        final cover = tester.getSize(
          find.byKey(const ValueKey('source-tile-cover')).first,
        );
        expect(cover.width / cover.height, closeTo(.75, .001));
        expect(cover.width, inInclusiveRange(44, 80));
        expect(tester.takeException(), isNull);
        await tester.tap(cells.first);
        expect(taps, 1);
      });
    }
  }

  testWidgets('首页三列：标题外置卡片不再铺白色底板', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 112,
        height: 182,
        child: PosterTile(item: item, onTap: () {}),
      ),
    );
    expect(find.byType(PosterTile), findsOneWidget);
    expect(find.byType(CoverThumb), findsOneWidget);
    final card = tester.widget<PosterCard>(find.byType(PosterCard));
    expect(card.footnoteBelow, isTrue, reason: '文字外置且不再铺白色底板');
    expect(find.text('仙逆剧场版 弑仙之战'), findsOneWidget);

    // 去掉文字白底后，封面自己必须裁四角；卡片与封面的半径要一致。
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(PosterCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.borderRadius, kPosterCoverRadius);
    final clips = tester.widgetList<ClipRRect>(
      find.descendant(
        of: find.byType(PosterCard),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clips, isNotEmpty, reason: '外置标题卡片必须自己裁封面');
    for (final clip in clips) {
      expect(clip.borderRadius, kPosterCoverRadius);
    }
  });

  testWidgets('外置标题卡片：非封面子组件也按同一半径裁切', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 112,
        height: 182,
        child: PosterCard(
          footnoteBelow: true,
          onTap: () {},
          footnote: const Text('示例标题'),
          child: const ColoredBox(color: Colors.orange),
        ),
      ),
    );
    final clips = tester.widgetList<ClipRRect>(
      find.descendant(
        of: find.byType(PosterCard),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clips, isNotEmpty);
    for (final clip in clips) {
      expect(clip.borderRadius, kPosterCoverRadius);
    }
  });
}
