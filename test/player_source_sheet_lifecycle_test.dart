import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';

void main() {
  testWidgets('关闭选集抽屉的动画中取址完成，不会再次返回并关闭播放页', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selection = Completer<bool>();
    late ModalRoute<dynamic> playerRoute;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) {
                    playerRoute = ModalRoute.of(context)!;
                    return Scaffold(
                      body: TextButton(
                        onPressed: () => showDanmakuPanel<void>(
                          context: context,
                          builder: (_) => PlayerSourceSheet(
                            address: '',
                            currentChapterId: 'one',
                            loadEpisodes: () async => const [
                              SourceChapter(id: 'one', title: '第1集'),
                              SourceChapter(id: 'two', title: '第2集'),
                            ],
                            onSelectEpisode: (_) => selection.future,
                          ),
                        ),
                        child: const Text('选集入口'),
                      ),
                    );
                  },
                ),
              ),
              child: const Text('进入播放页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入播放页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选集入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第2集'));
    await tester.pump();
    await tester.tapAt(const Offset(40, 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(playerRoute.isCurrent, isTrue);
    expect(find.byType(PlayerSourceSheet), findsOneWidget);
    selection.complete(true);
    await tester.pump();
    expect(playerRoute.isCurrent, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('选集入口'), findsOneWidget);
    expect(find.byType(PlayerSourceSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
