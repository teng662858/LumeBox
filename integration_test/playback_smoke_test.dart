import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/av_player.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final file in ['smoke.mp4', 'smoke.m3u8']) {
    testWidgets('real AVPlayer plays and seeks through disk cache: $file', (
      tester,
    ) async {
      expect(Platform.isIOS, isTrue, reason: 'Run this test on iOS Simulator');
      final directory = await Directory.systemTemp.createTemp(
        'playback-smoke-',
      );
      final cache = VideoDiskCache();
      await cache.boot(directory: directory);
      final player = AvPlayer();
      addTearDown(() async {
        await player.dispose();
        await cache.close();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: player.buildView())),
      );
      final media = PlayerMedia(uri: Uri.parse('http://127.0.0.1:18765/$file'));
      await cache.load(player, media).timeout(const Duration(seconds: 45));
      expect(player.snapshot.value.error, isNull);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: player.buildView())),
      );
      await player.play();
      Future<void> waitFor(bool Function() condition) async {
        for (var i = 0; i < 100 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(player.snapshot.value.error, isNull);
        expect(condition(), isTrue);
      }

      await waitFor(
        () =>
            player.snapshot.value.position > const Duration(milliseconds: 500),
      );
      expect(cache.downloadedBytes, greaterThan(0));
      expect(player.stats.value.width, greaterThan(0));
      await player.seek(const Duration(seconds: 3));
      await waitFor(
        () => player.snapshot.value.position >= const Duration(seconds: 3),
      );
      await player.pause();
      expect(
        player.snapshot.value.duration,
        greaterThan(const Duration(seconds: 5)),
      );
      debugPrint(
        'PLAYBACK_SMOKE_OK $file position=${player.snapshot.value.position} size=${player.stats.value.width}x${player.stats.value.height}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
