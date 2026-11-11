import 'package:lume_box/core/player/buffering.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/aether_player.dart';
import 'package:lume_box/core/player/player_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Completer<void>? loading;
  Completer<int>? creating;
  var nativeGeneration = 0;
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/aether/42/events'),
          (_) async => null,
        );
    loading = null;
    creating = null;
    nativeGeneration = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AetherPlayer.channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'create':
              return creating == null ? 42 : await creating!.future;
            case 'load':
              nativeGeneration = (call.arguments as Map)['generation'] as int;
              await loading?.future;
              return null;
            case 'snapshot':
              return <String, Object?>{
                'generation': nativeGeneration,
                'position': 12.5,
                'duration': 100.0,
                'playing': true,
                'width': 3840,
                'height': 2160,
                'videoCodec': 'hevc',
                'presentation': ['片源：Dolby Vision', '输出待设备确认'],
              };
            case 'audioTracks':
              return [
                {'id': 7, 'label': '中文', 'language': 'zh', 'selected': true},
              ];
            default:
              return null;
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/aether/42/events'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AetherPlayer.channel, null);
  });

  test('settings, headers, native state and non-contiguous track IDs survive the bridge', () async {
    final player = AetherPlayer();
    addTearDown(player.dispose);
    await player.applySettings(
      const PlayerSettings(
        kernel: PlayerKernel.aether,
        presentation: PlaybackPresentation(dolbyVision: false),
      ),
    );
    await player.load(
      PlayerMedia(
        uri: Uri.file('/movie.mkv'),
        headers: const {'Referer': 'https://example.org/'},
      ),
    );
    final load = calls.firstWhere((c) => c.method == 'load').arguments as Map;
    expect(load['id'], 42);
    expect((load['headers'] as Map)['Referer'], 'https://example.org/');
    expect((load['options'] as Map)['dolbyVision'], false);
    expect((load['options'] as Map)['wantsHdr'], true);
    expect(player.snapshot.value.position, const Duration(milliseconds: 12500));
    expect(player.stats.value.width, 3840);
    expect(player.presentationStatus.value.last, '输出待设备确认');
    expect((await player.audioTracks()).single.id, '7');
    await player.selectAudioTrack('7');
    expect((calls.last.arguments as Map)['track'], 7);
    expect(PlayerKernel.fromId('aether'), PlayerKernel.aether);
  });

  test('subtitle, audio delay, decoder and buffering settings reach the real native option names', () async {
    final player = AetherPlayer();
    addTearDown(player.dispose);
    await player.applySettings(
      const PlayerSettings(
        kernel: PlayerKernel.aether,
        hardwareDecoding: false,
      ).copyWith(
        subtitleColor: SubtitleColor.yellow,
        subtitleDelay: const Duration(milliseconds: 400),
        audioDelay: const Duration(milliseconds: -200),
      ),
    );
    await player.setBuffering(
      const BufferingConfig(
        readAhead: Duration(seconds: 30),
        maxBufferBytes: 128 * 1024 * 1024,
      ),
    );
    final args =
        calls.lastWhere((c) => c.method == 'settings').arguments as Map;
    final options = args['options'] as Map;
    expect(options['hardwareDecoding'], false);
    expect(options['subtitleArgb'], SubtitleColor.yellow.argb);
    expect(options['subtitleDelaySeconds'], 0.4);
    expect(options['audioDelaySeconds'], -0.2);
    expect(options['forwardBufferSeconds'], 30);
    expect(options['maxBufferBytes'], 128 * 1024 * 1024);
    expect(player.capabilities.subtitleStyle, true);
    expect(player.capabilities.hardwareDecoding, true);
  });

  test('native first-frame events are accepted only for the current load generation', () async {
    final player = AetherPlayer();
    addTearDown(player.dispose);
    await player.load(PlayerMedia(uri: Uri.file('/movie.mkv')));
    Future<void> event(Map<String, Object?> data) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'lumebox/aether/42/events',
            const StandardMethodCodec().encodeSuccessEnvelope(data),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);
    }

    await event({
      'generation': 1,
      'firstFrameReady': true,
      'position': 0,
      'width': 1920,
      'height': 1080,
    });
    expect(player.stats.value.firstFrameReady, true);
    await event({
      'generation': 0,
      'firstFrameReady': false,
      'width': 1,
      'height': 1,
    });
    expect(player.stats.value.firstFrameReady, true);
    expect(player.stats.value.width, 1920);
  });

  test(
    'buffer-slider bursts collapse into one native session correction',
    () async {
      final player = AetherPlayer();
      addTearDown(player.dispose);
      await player.load(PlayerMedia(uri: Uri.file('/movie.mkv')));
      final count = calls.where((c) => c.method == 'settings').length;
      final one = player.setBuffering(
        const BufferingConfig(readAhead: Duration(seconds: 30)),
      );
      final two = player.setBuffering(
        const BufferingConfig(readAhead: Duration(seconds: 60)),
      );
      await Future.wait([one, two]);
      expect(calls.where((c) => c.method == 'settings').length, count + 1);
      expect(
        ((calls.lastWhere((c) => c.method == 'settings').arguments
                as Map)['options']
            as Map)['forwardBufferSeconds'],
        60,
      );
    },
  );

  test('native load timeout releases the command queue and rejects late load events', () async {
    loading = Completer<void>();
    final blocked = loading!;
    final player = AetherPlayer(
      mediaLoadTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(player.dispose);
    await expectLater(
      player.load(PlayerMedia(uri: Uri.file('/stuck.mkv'))),
      throwsA(isA<TimeoutException>()),
    );
    expect(player.snapshot.value.buffering, isFalse);
    expect(player.snapshot.value.error, contains('TimeoutException'));
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'stop'), isTrue);
    // Older/native event-less sessions still poll after a cancelled load.
    // Their old ready snapshot must not erase the timeout error.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(calls.any((c) => c.method == 'snapshot'), isTrue);
    expect(player.snapshot.value.error, contains('TimeoutException'));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'lumebox/aether/42/events',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'generation': 1,
            'playing': true,
            'position': 99.0,
          }),
          (_) {},
        );
    await Future<void>.delayed(Duration.zero);
    expect(player.snapshot.value.error, contains('TimeoutException'));
    loading = null;
    await player
        .load(PlayerMedia(uri: Uri.file('/good.mkv')))
        .timeout(const Duration(seconds: 1));
    expect(player.snapshot.value.error, isNull);
    blocked.complete();
  });

  test('dispose bypasses a blocked load and stale completions cannot update notifiers', () async {
    loading = Completer<void>();
    final player = AetherPlayer();
    final pending = player.load(PlayerMedia(uri: Uri.file('/movie.mkv')));
    while (!calls.any((c) => c.method == 'load')) {
      await Future<void>.delayed(Duration.zero);
    }
    await player.dispose().timeout(const Duration(seconds: 1));
    expect(calls.last.method, 'dispose');
    loading!.complete();
    await pending;
    await player.dispose();
    expect(calls.where((c) => c.method == 'dispose').length, 1);
  });
  test('late native creation is disposed without blocking fallback', () async {
    creating = Completer<int>();
    final player = AetherPlayer();
    final initialization = player.initialize();
    await Future<void>.delayed(Duration.zero);
    await player.dispose().timeout(const Duration(seconds: 1));
    creating!.complete(91);
    await initialization;
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'dispose');
    expect((calls.last.arguments as Map)['id'], 91);
  });
}
