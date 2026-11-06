import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/source_playback_profiles.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('source-playback-profile-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  test('源A的内核、字幕与缓冲不覆盖源B或全局；无独立配置仍继承全局', () {
    final global = VideoPlayerSettingsStore(library);
    final profiles = SourcePlaybackProfiles(library);
    global.save(const PlayerSettings());
    final defaults = global.load();
    final a = defaults.copyWith(
      kernel: PlayerKernel.mpv,
      speed: 1.5,
      subtitleDelay: const Duration(seconds: 2),
      subtitlesEnabled: false,
    );
    profiles.save('source:a', a, 15);
    final loaded = profiles.load('source:a', global.load());
    expect(loaded.kernel, a.kernel);
    expect(loaded.current, a.current);
    expect(loaded.subtitlesEnabled, isFalse);
    expect(profiles.load('source:b', global.load()), defaults);
    expect(global.load(), defaults);
    expect(profiles.bufferSeconds('source:a', 5), 15);
    expect(profiles.bufferSeconds('source:b', 5), 5);
    final restored = SourcePlaybackProfiles(library);
    expect(restored.load('source:a', defaults).speed, 1.5);
    global.save(defaults.copyWith(autoNext: false));
    expect(profiles.load('source:a', global.load()).autoNext, isFalse);
    profiles.clear('source:a');
    expect(profiles.contains('source:a'), isFalse);
    expect(
      profiles.load('source:a', global.load()).kernel,
      PlayerKernel.avplayer,
    );
  });
  test('源名隔离与坏配置回退，缓冲值有界', () {
    final profiles = SourcePlaybackProfiles(library);
    profiles.save('a/b', const PlayerSettings(), 999999);
    expect(profiles.contains('a%2Fb'), isFalse);
    expect(profiles.bufferSeconds('a/b', 0), lessThan(999999));
    library.setSetting('video.player.source.bad', '{broken');
    expect(
      profiles.load('bad', const PlayerSettings()),
      const PlayerSettings(),
    );
  });
}
