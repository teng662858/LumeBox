import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';

void main() {
  testWidgets('横屏选集贴右侧占五分之二，安全区留在内容内部', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DanmakuPanelFrame(
            edgeDrawer: true,
            screenPadding: const EdgeInsets.only(right: 44, bottom: 24),
            child: Builder(builder: (_) => const Center(child: Text('内容'))),
          ),
        ),
      ),
    );
    final rect = tester.getRect(
      find.byKey(const ValueKey('danmaku-panel-frame')),
    );
    expect(rect.right, 932);
    expect(rect.width, closeTo(932 * .4, .01));
    expect(rect.height, 430);
    expect(tester.takeException(), isNull);
  });

  for (final mode in PlayerEpisodeView.values) {
    testWidgets('${mode.label}保留当前集定位、倒序和切集失败重试', (tester) async {
      tester.view.physicalSize = const Size(932, 430);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int? selected;
      PlayerEpisodeView? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 932 * .4,
                child: PlayerSourceSheet(
                  address: '',
                  initialView: mode,
                  currentChapterId: '120',
                  includeQualityTab: false,
                  loadEpisodes: () async => List.generate(
                    120,
                    (i) => SourceChapter(id: '${i + 1}', title: '第${i + 1}集'),
                  ),
                  onSelectEpisode: (i) async {
                    selected = i;
                    return false;
                  },
                  onViewChanged: (v) => changed = v,
                  artworkBuilder: (_, _, _) => const Icon(Icons.image),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第120集'), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('正序'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('第119集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第119集'));
      await tester.pumpAndSettle();
      expect(selected, 118);
      expect(find.text('切集失败，请重试'), findsOneWidget);
      final next = PlayerEpisodeView.values[(mode.index + 1) % 3];
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视图：${next.label}'));
      await tester.pumpAndSettle();
      expect(changed, next);
      expect(find.text('第120集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
