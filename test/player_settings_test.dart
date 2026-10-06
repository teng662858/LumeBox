import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 播放器设置模型与「自定义视频」板块持久化的验证。
///
/// 持久化对着临时目录里的真实 sqlite 断言：保存 / 读回 / 脏值回退，
/// 以及板块隔离——视频板块的设置不会出现在其他板块的库里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('设置模型', () {
    test('默认值：AVPlayer + 1.0x + 字幕开 + 标准字号', () {
      const settings = PlayerSettings();
      expect(settings.kernel, PlayerKernel.avplayer);
      expect(settings.speed, 1.0);
      expect(settings.subtitlesEnabled, isTrue);
      expect(settings.subtitleSize, SubtitleSize.standard);
    });

    test('倍速归一：非档位值夹到最近档位，NaN 回默认', () {
      expect(PlayerSettings.normalizeSpeed(1.0), 1.0);
      expect(PlayerSettings.normalizeSpeed(1.3), 1.25);
      expect(PlayerSettings.normalizeSpeed(1.9), 2.0);
      expect(PlayerSettings.normalizeSpeed(0.1), 0.5);
      expect(PlayerSettings.normalizeSpeed(double.nan), 1.0);
      expect(PlayerSettings.normalizeSpeed(null), 1.0);
    });

    test('copyWith 只改传入项，倍速仍走归一', () {
      const base = PlayerSettings();
      final next = base.copyWith(speed: 3.0, subtitleSize: SubtitleSize.large);
      expect(next.speed, 2.0);
      expect(next.subtitleSize, SubtitleSize.large);
      expect(next.kernel, base.kernel);
      expect(next.subtitlesEnabled, base.subtitlesEnabled);
      expect(base.copyWith(), base);
    });

    test('落库值无法识别时回退默认', () {
      expect(PlayerKernel.fromId('vlc'), PlayerKernel.avplayer);
      expect(PlayerKernel.fromId(null), PlayerKernel.avplayer);
      expect(PlayerKernel.fromId('mpv'), PlayerKernel.mpv);
      expect(SubtitleSize.fromId('gigantic'), SubtitleSize.standard);
      expect(SubtitleSize.fromId('large'), SubtitleSize.large);
      expect(SubtitleSize.fromId('huge'), SubtitleSize.huge,
          reason: '「特大」是新增的合法档位，不再是无法识别的值');
    });
  });

  group('板块隔离的持久化', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('lume_box_player');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? root.path
            : null,
      );
    });

    tearDown(() async {
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('保存后可读回，关库重开仍在', () async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(
        const PlayerSettings(
          kernel: PlayerKernel.mdk,
          speed: 1.5,
          subtitlesEnabled: false,
          subtitleSize: SubtitleSize.large,
        ),
      );
      store.close();

      final reopened = await VideoPlayerSettingsStore.open();
      final loaded = reopened.load();
      expect(loaded.kernel, PlayerKernel.mdk);
      expect(loaded.speed, 1.5);
      expect(loaded.subtitlesEnabled, isFalse);
      expect(loaded.subtitleSize, SubtitleSize.large);
    });

    test('缺项回退默认；脏值回退默认或最近档位', () async {
      final store = await VideoPlayerSettingsStore.open();
      expect(store.load(), const PlayerSettings());

      final library = await ReadingLibrary.open(Section.video);
      library.setSetting(VideoPlayerSettingsStore.keyKernel, 'vlc');
      library.setSetting(VideoPlayerSettingsStore.keySpeed, '1.30');
      library.setSetting(VideoPlayerSettingsStore.keySubtitles, 'maybe');
      library.setSetting(VideoPlayerSettingsStore.keySubtitleSize, 'gigantic');

      final loaded = store.load();
      expect(loaded.kernel, PlayerKernel.avplayer);
      expect(loaded.speed, 1.25);
      // 非 'false' 一律按开启处理：字幕默认开，脏值不改变这个口径。
      expect(loaded.subtitlesEnabled, isTrue);
      expect(loaded.subtitleSize, SubtitleSize.standard);
    });

    test('隔离：设置落在视频板块自己的库文件，其他板块读不到', () async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(const PlayerSettings(speed: 1.5));

      // 视频板块的库文件在 sections/video/reading.db（与图源库分文件）。
      final videoDb = File('${root.path}/sections/video/reading.db');
      expect(videoDb.existsSync(), isTrue);

      // 其他板块的库里没有这个键；小说库是另一个文件。
      final novel = await ReadingLibrary.open(Section.novel);
      expect(novel.setting(VideoPlayerSettingsStore.keySpeed), isNull);
      expect(novel.setting(VideoPlayerSettingsStore.keyKernel), isNull);
      expect(
        File('${root.path}/sections/novel/reading.db').path,
        isNot(videoDb.path),
      );
    });
  });
}
