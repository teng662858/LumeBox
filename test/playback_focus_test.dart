import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/playback_focus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lumebox/mediaTracks');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('same-name replacement rebinds native ownership without stale playing state', () async {
    final owners = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      owners.add(call.arguments);
      return null;
    });
    var oldStops = 0, newStops = 0;
    Future<void> oldPlayer() async {
      oldStops++;
    }

    Future<void> newPlayer() async {
      newStops++;
    }

    addTearDown(() {
      PlaybackFocus.unregister('replacement-player', oldPlayer);
      PlaybackFocus.unregister('replacement-player', newPlayer);
    });
    await PlaybackFocus.acquire('replacement-player', onRelease: oldPlayer);
    PlaybackFocus.setPlaying('replacement-player', true);
    await PlaybackFocus.acquire('replacement-player', onRelease: newPlayer);
    expect(oldStops, 1);
    expect(newStops, 0);
    expect(owners, ['replacement-player', 'replacement-player']);
    expect(PlaybackFocus.isPlaying, isFalse);
    PlaybackFocus.setPlaying('replacement-player', true);
    await PlaybackFocus.acquire('replacement-player', onRelease: newPlayer);
    expect(owners.length, 2);
    expect(PlaybackFocus.isPlaying, isTrue);
    await PlaybackFocus.acquire('after-replacement');
    expect(newStops, 1);
  });

  test(
    'failed native handoff leaves the queue available for the next player',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.arguments == 'failed-player') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      await expectLater(
        PlaybackFocus.acquire('failed-player'),
        throwsA(isA<PlatformException>()),
      );
      expect(PlaybackFocus.owner, isNull);
      await PlaybackFocus.acquire('recovered-player');
      expect(PlaybackFocus.owner, 'recovered-player');
    },
  );

  test(
    'cancelled native ownership handoff never registers a stale player',
    () async {
      final binding = Completer<void>(), finish = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.arguments == 'cancelled-player') {
          binding.complete();
          await finish.future;
        }
        return null;
      });
      var previousStops = 0, cancelledStops = 0, wanted = true;
      Future<void> previous() async {
        previousStops++;
      }

      Future<void> cancelled() async {
        cancelledStops++;
      }

      addTearDown(() {
        PlaybackFocus.unregister('previous-player', previous);
        PlaybackFocus.unregister('cancelled-player', cancelled);
      });
      await PlaybackFocus.acquire('previous-player', onRelease: previous);
      PlaybackFocus.setPlaying('previous-player', true);
      final pending = PlaybackFocus.acquire(
        'cancelled-player',
        onRelease: cancelled,
        stillWanted: () => wanted,
      );
      await binding.future;
      wanted = false;
      finish.complete();
      await pending;
      expect(PlaybackFocus.owner, isNull);
      expect(PlaybackFocus.isPlaying, isFalse);
      await PlaybackFocus.acquire('following-player');
      expect(previousStops, 1);
      expect(cancelledStops, 0);
      expect(PlaybackFocus.owner, 'following-player');
    },
  );

  test(
    'replacement cancelled while old player stops leaves no active owner',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final stopping = Completer<void>(), finish = Completer<void>();
      Future<void> previous() async {
        stopping.complete();
        await finish.future;
      }

      var wanted = true, replacementsStopped = 0;
      Future<void> replacement() async {
        replacementsStopped++;
      }

      addTearDown(() {
        PlaybackFocus.unregister('same-player', previous);
        PlaybackFocus.unregister('same-player', replacement);
      });
      await PlaybackFocus.acquire('same-player', onRelease: previous);
      PlaybackFocus.setPlaying('same-player', true);
      final pending = PlaybackFocus.acquire(
        'same-player',
        onRelease: replacement,
        stillWanted: () => wanted,
      );
      await stopping.future;
      wanted = false;
      finish.complete();
      await pending;
      expect(PlaybackFocus.owner, isNull);
      expect(PlaybackFocus.isPlaying, isFalse);
      expect(replacementsStopped, 0);
    },
  );
}
