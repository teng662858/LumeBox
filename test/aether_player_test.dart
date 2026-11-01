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
  setUp(() {
    calls.clear();
    loading = null;
    creating = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AetherPlayer.channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'create':
              return creating == null ? 42 : await creating!.future;
            case 'load':
              await loading?.future;
              return null;
            case 'snapshot':
              return <String, Object?>{
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
