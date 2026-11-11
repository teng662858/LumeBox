import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/av_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/mpv_engine.dart';
import 'package:lume_box/core/player/mpv_player.dart';
import 'package:lume_box/core/player/buffering.dart';
import 'package:lume_box/core/player/pip_channel.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void stage(String message) {
  final line = 'KERNEL_SMOKE_STAGE $message';
  // Keep a host-readable trace even if the VM test channel stops forwarding.
  File('${Directory.systemTemp.path}/lumebox-playback-stage.log')
      .writeAsStringSync('$line\n', mode: FileMode.append);
  debugPrint(line);
}

void main() {
  stage('main');
  debugPrint(
    'KERNEL_SMOKE_TRACE ${Directory.systemTemp.path}/lumebox-playback-stage.log',
  );
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive
    ..defaultTestTimeout = const Timeout(Duration(minutes: 2));
  const onlyKernel = String.fromEnvironment('KERNEL_SMOKE');
  for (final kernel in [
    PlayerKernel.mpv,
    PlayerKernel.mdk,
    PlayerKernel.aether,
  ]) {
    if (onlyKernel.isNotEmpty && onlyKernel != kernel.name) continue;
    for (final file in ['smoke.mp4', 'smoke.m3u8']) {
      testWidgets('real ${kernel.name} startup, pause and seek: $file', (
        tester,
      ) async {
        stage('${kernel.name} $file begin');
        final watch = Stopwatch()..start();
        final cache = VideoDiskCache();
        final directory = await Directory.systemTemp.createTemp(
          'kernel-smoke-',
        );
        await cache.boot(directory: directory);
        stage('${kernel.name} $file create');
        final player = PlayerFactory.create(kernel: kernel)!;
        stage('${kernel.name} $file created');
        addTearDown(() async {
          await player.dispose();
          await cache.close();
          await directory.delete(recursive: true);
        });
        await player.initialize().timeout(const Duration(seconds: 10));
        if (player is MpvPlayer &&
            const bool.fromEnvironment('KERNEL_SMOKE_HEADLESS_AUDIO')) {
          expect(
            await (player.engine as EnginePropertyCapable).setEngineProperty(
              'ao',
              'null',
            ),
            isTrue,
          );
          stage('${kernel.name} $file timed null audio sink');
        }
        await player.setBuffering(BufferingConfig.defaults);
        await player.applySettings(PlayerSettings(kernel: kernel));
        stage('${kernel.name} $file load');
        final load = Stopwatch()..start();
        await cache
            .load(
              player,
              PlayerMedia(uri: Uri.parse('http://127.0.0.1:18765/$file')),
            )
            .timeout(const Duration(seconds: 45));
        final readyMs = load.elapsedMilliseconds;
        stage('${kernel.name} $file loaded');
        expect(player.snapshot.value.error, isNull);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: player.buildView())),
        );
        await player.play();
        stage('${kernel.name} $file play');
        Future<void> waitFor(bool Function() condition) async {
          for (var i = 0; i < 150 && !condition(); i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(player.snapshot.value.error, isNull);
          expect(
            condition(),
            isTrue,
            reason: '${kernel.name} $file must advance its real clock',
          );
        }

        await waitFor(
          () =>
              player.snapshot.value.position >
              const Duration(milliseconds: 500),
        );
        final firstProgressMs = watch.elapsedMilliseconds;
        expect(player.stats.value.width, greaterThan(0));
        await player.pause();
        await tester.pump(const Duration(milliseconds: 300));
        final paused = player.snapshot.value.position;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          (player.snapshot.value.position - paused).abs(),
          lessThan(const Duration(milliseconds: 500)),
          reason: 'buffer updates must respect explicit pause',
        );
        await player
            .seek(const Duration(seconds: 3))
            .timeout(const Duration(seconds: 10));
        await player.play();
        await waitFor(
          () =>
              player.snapshot.value.position >
              const Duration(milliseconds: 3500),
        );
        debugPrint(
          'KERNEL_SMOKE_OK ${kernel.name} $file loadMs=$readyMs firstProgressMs=$firstProgressMs',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  if (onlyKernel.isNotEmpty && onlyKernel != 'avplayer') return;
  for (final file in ['smoke.mp4', 'smoke.m3u8']) {
    testWidgets('real AVPlayer plays and seeks through disk cache: $file', (
      tester,
    ) async {
      stage('avplayer $file begin');
      expect(Platform.isIOS, isTrue, reason: 'Run this test on iOS Simulator');
      final directory = await Directory.systemTemp.createTemp(
        'playback-smoke-',
      );
      final cache = VideoDiskCache();
      await cache.boot(directory: directory);
      stage('avplayer $file create');
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
      stage('avplayer $file load');
      await cache.load(player, media).timeout(const Duration(seconds: 45));
      stage('avplayer $file loaded');
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
      // A progressing clock alone missed the black-screen regression. Check the
      // visible native layer before and after automatic PiP preparation.
      const network = MethodChannel('lumebox/av_network');
      Future<bool> pictureReady() async {
        final state = await network.invokeMapMethod<String, Object?>(
          'readVideoState',
          {'playerId': player.nativePlayerId},
        );
        return state?['attached'] == true && state?['readyForDisplay'] == true;
      }

      for (var i = 0; i < 50 && !await pictureReady(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await pictureReady(), isTrue);
      final pip = MethodChannelPipBackend();
      addTearDown(pip.resetFrames);
      for (final enabled in [false, true, false]) {
        await pip.updateDanmaku(
          {'pipEnabled': enabled},
          [
            {'time': 1000, 'text': 'PiP fixture', 'mode': 'scroll'},
          ],
        );
        await pip.prepareAvPlayer(player.nativePlayerId!);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          await pictureReady(),
          isTrue,
          reason: 'PiP preparation must leave the inline picture visible',
        );
      }
      await pip.resetFrames();
      expect(
        await pictureReady(),
        isTrue,
        reason: 'PiP teardown must not clear the plugin-owned layer',
      );
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
      // Exercise the texture PiP path too: no competing AVPlayerLayer is created.
      await player.applySettings(
        const PlayerSettings(
          presentation: PlaybackPresentation(hdrEnabled: false),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: player.buildView())),
      );
      await player.play();
      await pip.prepareAvPlayer(player.nativePlayerId!);
      final textureState = await network.invokeMapMethod<String, Object?>(
        'readVideoState',
        {'playerId': player.nativePlayerId},
      );
      expect(textureState?['inlineLayer'], isFalse);
      await waitFor(() => player.stats.value.firstFrameReady == true);
      await pip.resetFrames();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
