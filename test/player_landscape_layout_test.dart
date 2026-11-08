import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/player_settings_panel.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings_sheet.dart';
import 'package:lume_box/core/source/source.dart';

void main() {
  for (final view in PlayerEpisodeView.values) {
    testWidgets('选集抽屉左右各留14点，视图 $view', (tester) async {
      tester.view.physicalSize = const Size(380, 430);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerSourceSheet(
              address: 'https://fixture.invalid/video.m3u8',
              fullBleed: true,
              initialView: view,
              loadEpisodes: () async => List.generate(
                8,
                (i) => SourceChapter(id: '$i', title: '第${i + 1}集'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final content = view == PlayerEpisodeView.grid
          ? find.byType(GridView)
          : find.byType(ListView);
      final bounds = tester.getRect(content);
      expect(bounds.left, closeTo(14, .01));
      expect(380 - bounds.right, closeTo(14, .01));
      expect(tester.takeException(), isNull);
    });
  }
  for (final scale in [1.0, 1.6]) {
    testWidgets('横屏弹幕设置保留右侧抽屉并可使用较大字体，字号 $scale', (tester) async {
      tester.view.physicalSize = const Size(932, 430);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var matched = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开'),
                onPressed: () => showPlayerSettingsPanel<void>(
                  context: context,
                  builder: (_) => DanmakuSettingsSheet(
                    settings: const DanmakuSettings(),
                    onChanged: (_) {},
                    videoTitle: '横屏检查',
                    episodeTitle: '第一集',
                    danmakuCount: 18268,
                    publicCount: 18268,
                    onMatch: () => matched++,
                    onReload: () {},
                    onConfigureService: () {},
                    onClearMatch: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final rect = tester.getRect(
        find.byKey(const ValueKey('danmaku-panel-frame')),
      );
      expect(rect.left, closeTo(932 * .6, .01));
      expect(rect.width, closeTo(932 * .4, .01));
      expect(rect.height, 430);
      await tester.tap(find.text('匹配公共弹幕'));
      await tester.pumpAndSettle();
      expect(matched, 1);
      await tester.tap(find.text('显示样式'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回播放'));
      await tester.pumpAndSettle();
      expect(find.text('打开'), findsOneWidget);
    });
  }
  testWidgets('剧集线路的标题与选项对齐且离两侧有留白', (tester) async {
    tester.view.physicalSize = const Size(380, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerSourceSheet(
            address: 'https://fixture.invalid/video.m3u8',
            fullBleed: true,
            initialTab: PlayerSourceTab.lines,
            loadLines: () async => const [
              PlayerSourceLine('默认线路', current: true),
              PlayerSourceLine('备用线路'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('剧集线路'));
    final current = tester.getRect(find.text('默认线路'));
    expect(title.left, greaterThanOrEqualTo(18));
    expect(current.left, title.left);
    expect(
      tester.getRect(find.byIcon(Icons.check)).right,
      lessThanOrEqualTo(362),
    );
    expect(tester.takeException(), isNull);
  });
}
