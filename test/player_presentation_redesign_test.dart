import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';
import 'package:lume_box/features/video/player_waiting_overlay.dart';

void main() {
  testWidgets('紧凑横屏选集仍完整显示三位数集名', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => PlayerSourceSheet(
                  address: '',
                  currentChapterId: '120',
                  loadEpisodes: () async => List.generate(
                    120,
                    (i) => SourceChapter(id: '${i + 1}', title: '第${i + 1}集'),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final label = find.text('第120集');
    expect(label, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('短暂缓冲无闪烁，持续缓冲提供出口，锁定禁止操作且计时可重新开始', (tester) async {
    var buffering = true, locked = false, retries = 0, lines = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: PlayerWaitingOverlay(
                snapshot: PlayerSnapshot(
                  buffering: buffering,
                  position: const Duration(seconds: 20),
                ),
                locked: locked,
                onRetry: () => retries++,
                onSwitchLine: () => lines++,
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('缓冲中'), findsNothing);
    update(() => buffering = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('缓冲中'), findsNothing);
    update(() => buffering = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('缓冲中'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.pump(const Duration(seconds: 8));
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('换线路'));
    expect((retries, lines), (1, 1));
    update(() => locked = true);
    await tester.pump();
    expect(find.text('重试'), findsNothing);
    update(() => buffering = false);
    await tester.pump();
    expect(find.text('缓冲中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('画质切换等待完成才关闭，失败保留面板允许再次尝试', (tester) async {
    Completer<void>? pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => PlayerSourceSheet(
                  address: 'https://example.test/video',
                  initialTab: PlayerSourceTab.quality,
                  qualities: [
                    VideoQuality(
                      label: '备用',
                      url: Uri.parse('https://example.test/backup'),
                    ),
                  ],
                  onSelectQuality: (_) => (pending = Completer<void>()).future,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备用'));
    await tester.pump();
    expect(find.byType(PlayerSourceSheet), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending!.completeError(StateError('unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('切换失败，请重试'), findsOneWidget);
    await tester.tap(find.text('备用'));
    await tester.pump();
    pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSourceSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('紧凑面板在小屏与大字下可展开，线路缺集不可误切', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => PlayerSourceSheet(
                  address: '',
                  initialTab: PlayerSourceTab.lines,
                  loadLines: () async => const [
                    PlayerSourceLine('当前', current: true),
                    PlayerSourceLine('缺集', available: false),
                    PlayerSourceLine('备用'),
                  ],
                  onSelectLine: (line) async {
                    selected.add(line);
                    return false;
                  },
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final frame = find.byKey(const ValueKey('danmaku-panel-frame'));
    final height = tester.getSize(frame).height;
    // 竖屏抽屉已取消展开抓手：高度固定，不再有「展开/收起」入口。
    expect(find.byTooltip('展开面板'), findsNothing);
    expect(find.byTooltip('收起面板'), findsNothing);
    expect(height, greaterThan(0));
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '缺集')).enabled,
      isFalse,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备用'));
    await tester.pumpAndSettle();
    expect(selected, ['备用']);
    expect(find.text('切换失败，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
