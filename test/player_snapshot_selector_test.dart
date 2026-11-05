import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/features/video/player_snapshot_selector.dart';

void main() {
  testWidgets(
    'progress ticks do not rebuild controls while pause and errors do',
    (tester) async {
      final snapshot = ValueNotifier(const PlayerSnapshot(playing: true));
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerSnapshotSelector<(bool, String?)>(
            snapshot: snapshot,
            select: (s) => (s.playing, s.error),
            builder: (_, s) {
              builds++;
              return Text(s.error ?? (s.playing ? '播放中' : '已暂停'));
            },
          ),
        ),
      );
      for (var i = 1; i <= 10; i++) {
        snapshot.value = PlayerSnapshot(
          playing: true,
          position: Duration(milliseconds: i * 100),
        );
        await tester.pump();
      }
      expect(builds, 1);
      snapshot.value = const PlayerSnapshot(playing: false);
      await tester.pump();
      expect(builds, 2);
      expect(find.text('已暂停'), findsOneWidget);
      snapshot.value = const PlayerSnapshot(error: '错误');
      await tester.pump();
      expect(builds, 3);
      await tester.pumpWidget(const SizedBox());
      snapshot.dispose();
    },
  );
}
