import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lume_box/core/player/native_video_bridge.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final bridge = NativeVideoBridge();
  const channel = MethodChannel('lumebox/native_video');
  Future<Map<String, Object?>> inspect(
    NativeVideoConnection connection, [
    Map<String, Object?> args = const {},
  ]) async => Map<String, Object?>.from(
    await channel
            .invokeMapMethod<String, Object?>('debug', {
              'session': connection.id,
              ...args,
            })
            .timeout(const Duration(seconds: 3)) ??
        const {},
  );
  Future<Map<String, Object?>> waitFor(
    WidgetTester tester,
    NativeVideoConnection connection,
    bool Function(Map<String, Object?>) condition,
  ) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 35)) {
      final state = await inspect(connection);
      expect(state['error'], isNull, reason: '$state');
      if (condition(state)) return state;
      // A full-screen UIKit controller hides Flutter's surface. Waiting for a
      // Flutter frame here can never complete, although native playback keeps
      // running. Poll native state using the live test clock instead.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('Native playback condition timed out: ${await inspect(connection)}');
  }

  for (final kernel in ['avplayer', 'mpv']) {
    for (final file in ['smoke.mp4', 'smoke.m3u8']) {
      testWidgets(
        'native $kernel video, UIKit controls, seek, PiP preparation: $file',
        (tester) async {
          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(body: Text('Native playback host')),
            ),
          );
          final connection = bridge.connect(
            request: (_, _) async => {},
            event: (_) {},
          );
          addTearDown(connection.close);
          final watch = Stopwatch()..start();
          await VideoDiskCache.instance.boot();
          final media = await VideoDiskCache.instance.wrap(
            PlayerMedia(
              uri: Uri.parse('http://127.0.0.1:18765/protected/$file'),
              headers: const {'X-Lume-Test': r'ticket=a,b\c'},
            ),
            appleHls: kernel == 'avplayer',
          );
          await connection.open(
            {
              'url': media.uri.toString(),
              'headers': media.headers ?? const <String, String>{},
              'title': 'Native $kernel $file',
              'identity': '$kernel-$file',
            },
            {'kernel': kernel, 'headlessAudio': true, 'autoNext': false},
          );
          final ready = await waitFor(
            tester,
            connection,
            (s) =>
                s['firstFrame'] == true && (s['position'] as num? ?? 0) > 0.5,
          );
          expect(ready['viewAttached'], isTrue);
          expect(ready['closeWidth'], 44);
          expect(ready['closeLeadingInset'], closeTo(16, 1));
          if (kernel == 'mpv') expect(ready['frameUpright'], isTrue);
          expect(ready['pipSupported'], kernel == 'avplayer');
          expect(
            ready['playHitTest'],
            isTrue,
            reason: 'UIKit hit testing must reach the native play button',
          );
          expect(
            ready['closeHitTest'],
            isTrue,
            reason: 'the native back button must remain reachable',
          );
          expect(ready['nativeControls'] as num, greaterThanOrEqualTo(10));
          expect(ready['duration'] as num, greaterThan(5));
          expect(VideoDiskCache.instance.downloadedBytes, greaterThan(0));
          await inspect(connection, {'action': 'tap', 'control': 'play'});
          final paused = await waitFor(
            tester,
            connection,
            (s) => s['playing'] == false && s['wantsPlay'] == false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 800));
          final after = await inspect(connection);
          expect(
            ((after['position'] as num) - (paused['position'] as num)).abs(),
            lessThan(0.5),
          );
          await inspect(connection, {'action': 'seek', 'position': 3.0});
          await inspect(connection, {'action': 'tap', 'control': 'play'});
          await waitFor(
            tester,
            connection,
            (s) => (s['position'] as num? ?? 0) > 3.3,
          );
          await inspect(connection, {'action': 'pip'});
          await waitFor(
            tester,
            connection,
            (s) => s['viewAttached'] == true && s['firstFrame'] == true,
          );
          debugPrint(
            'NATIVE_VIDEO_OK $kernel $file firstProgressMs=${watch.elapsedMilliseconds}',
          );
          await connection.close();
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    }
  }
  testWidgets(
    'native engine replacement and closing during startup remain responsive',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final media = {
        'url': 'http://127.0.0.1:18765/protected/smoke.mp4',
        'headers': {'X-Lume-Test': r'ticket=a,b\c'},
        'identity': 'switch',
      };
      final connection = bridge.connect(
        request: (action, arguments) async => action == 'kernel'
            ? {'media': media, 'speed': arguments['id'] == 'mpv' ? 2.5 : 1.0}
            : {},
        event: (_) {},
      );
      addTearDown(connection.close);
      await connection.open(
        media,
        {'headlessAudio': true, 'autoNext': false},
      );
      await waitFor(
        tester,
        connection,
        (s) => (s['position'] as num? ?? 0) > 0.5,
      );
      for (final kernel in ['mpv', 'avplayer', 'mpv']) {
        await inspect(connection, {'action': 'kernel', 'kernel': kernel});
        await waitFor(
          tester,
          connection,
          (s) =>
              s['kernel'] == kernel &&
              s['speed'] == (kernel == 'mpv' ? 2.5 : 1.0) &&
              s['firstFrame'] == true &&
              s['switching'] == false,
        );
      }
      await connection.close();
      await tester.pump(const Duration(milliseconds: 300));
      final stalled = bridge.connect(
        request: (_, _) async => {},
        event: (_) {},
      );
      addTearDown(stalled.close);
      await stalled.open({
        'url': 'http://127.0.0.1:18765/missing.m3u8',
        'identity': 'missing',
      }, {});
      await stalled.close().timeout(const Duration(seconds: 4));
      debugPrint('NATIVE_VIDEO_SWITCH_OK');
    },
  );
}
