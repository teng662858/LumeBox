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
      expect(settings.controlStyle, PlayerControlStyle.icons);
      expect(settings.subtitlesEnabled, isTrue);
      expect(settings.subtitleSize, SubtitleSize.standard);
    });

    test('倍速归一：非档位值夹到最近档位，NaN 回默认', () {
      expect(PlayerSettings.normalizeSpeed(1.0), 1.0);
      expect(PlayerSettings.normalizeSpeed(1.3), 1.25);
      expect(PlayerSettings.normalizeSpeed(1.9), 2.0);
      expect(PlayerSettings.normalizeSpeed(0.1), 0.25, reason: '档位下限是 0.25');
      expect(PlayerSettings.normalizeSpeed(double.nan), 1.0);
      expect(PlayerSettings.normalizeSpeed(null), 1.0);
    });

    test('copyWith 只改传入项，倍速仍走归一', () {
      const base = PlayerSettings();
      // 3.0 是合法档位（0.25 步长，上限 4.0）；5.0 会被夹到 4.0。
      final next = base.copyWith(speed: 3.0, subtitleSize: SubtitleSize.large);
      expect(next.speed, 3.0);
      expect(base.copyWith(speed: 5.0).speed, PlayerSettings.maxSpeed);
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
      expect(
        SubtitleSize.fromId('huge'),
        SubtitleSize.huge,
        reason: '「特大」是新增的合法档位，不再是无法识别的值',
      );
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
          subtitlesEnabled: false,
        ).copyWith(speed: 1.5, subtitleSize: SubtitleSize.large),
      );
      store.close();

      final reopened = await VideoPlayerSettingsStore.open();
      final loaded = reopened.load();
      expect(loaded.kernel, PlayerKernel.mdk);
      expect(loaded.speed, 1.5);
      expect(loaded.subtitlesEnabled, isFalse);
      expect(loaded.subtitleSize, SubtitleSize.large);
    });

    test('解码预设和独立跳转步长保存后可恢复', () async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(
        store.load().copyWith(
          decodingPreset: DecodingPreset.software,
          gestures: const PlayerGestureOptions(
            forwardSeconds: 90,
            backwardSeconds: 5,
          ),
        ),
      );
      final next = (await VideoPlayerSettingsStore.open()).load();
      expect(next.decodingPreset, DecodingPreset.software);
      expect(next.hardwareDecoding, false);
      expect(next.gestures.forwardSeconds, 90);
      expect(next.gestures.backwardSeconds, 5);
      expect(
        next
            .copyWith(decodingPreset: DecodingPreset.automatic)
            .hardwareDecoding,
        true,
      );
    });

    test('presentation switches and subtitle appearance persist in the video database', () async {
      final store = await VideoPlayerSettingsStore.open();
      final next = store.load().copyWith(
        presentation: const PlaybackPresentation(
          hdrEnabled: false,
          dolbyVision: false,
          dolbyAudio: false,
          enhancementEnabled: true,
          preset: EnhancementPreset.anime,
          sharpen: false,
          subtitleLanguage: 'en',
          originalSubtitleStyle: false,
        ),
        subtitleFont: 'PingFang SC',
        subtitleShadow: 0.75,
        subtitleOffsetY: 0.5,
      );
      store.save(next);
      final reopened = await VideoPlayerSettingsStore.open();
      expect(reopened.load().presentation, next.presentation);
      expect(reopened.load().subtitleFont, 'PingFang SC');
      expect(reopened.load().subtitleShadow, 0.75);
      expect(reopened.load().subtitleOffsetY, 0.5);
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting('video.player.presentation', '{broken');
      expect(store.load().presentation, const PlaybackPresentation());
    });

    test('gesture switches and adjustment values persist and survive kernel switches', () async {
      final store = await VideoPlayerSettingsStore.open();
      final next = store.load().copyWith(
        gestures: const PlayerGestureOptions(
          enabled: true,
          brightness: false,
          volume: false,
          seek: true,
          boost: false,
          seekSeconds: 150,
          boostMultiplier: 1.5,
        ),
      );
      store.save(next);
      final reopened = await VideoPlayerSettingsStore.open();
      expect(reopened.load().gestures, next.gestures);
      expect(next.copyWith(kernel: PlayerKernel.mpv).gestures, next.gestures);
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting('video.player.gestures', '{bad');
      expect(store.load().gestures, const PlayerGestureOptions());
      library.setSetting(
        'video.player.gestures',
        '{"seekSeconds":999,"boostMultiplier":-2,"volume":false}',
      );
      expect(store.load().gestures.seekSeconds, 180);
      expect(store.load().gestures.boostMultiplier, 1.5);
      expect(store.load().gestures.volume, false);
    });

    test('启动选项与手动画质名本地持久化；缺项按 A 开、记忆关', () async {
      final store = await VideoPlayerSettingsStore.open();
      expect(store.load().backgroundSourceValidation, isTrue);
      expect(store.load().rememberManualQuality, isFalse);
      store.save(
        store.load().copyWith(
          backgroundSourceValidation: false,
          rememberManualQuality: true,
          manualQualityLabel: '720P',
          defaultQuality: DefaultQuality.hd,
          playbackGlass: false,
        ),
      );
      store.close();
      ReadingLibrary.close(Section.video);
      final reopened = await VideoPlayerSettingsStore.open();
      expect(reopened.load().backgroundSourceValidation, isFalse);
      expect(reopened.load().rememberManualQuality, isTrue);
      expect(reopened.load().manualQualityLabel, '720P');
      expect(reopened.load().defaultQuality, DefaultQuality.hd);
      expect(reopened.load().playbackGlass, isFalse);
    });

    test('按钮样式保存后重开仍保留，未知值回退图标模式', () async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(store.load().copyWith(controlStyle: PlayerControlStyle.text));
      expect(store.load().controlStyle, PlayerControlStyle.text);
      store.close();
      ReadingLibrary.close(Section.video);
      final reopened = await VideoPlayerSettingsStore.open();
      expect(reopened.load().controlStyle, PlayerControlStyle.text);
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting(VideoPlayerSettingsStore.keyControlStyle, 'invalid');
      expect(reopened.load().controlStyle, PlayerControlStyle.icons);
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
      store.save(const PlayerSettings().copyWith(speed: 1.5));

      // 视频板块的库文件在 sections/video/reading.db（与图源库分文件）。
      final videoDb = File('${root.path}/sections/video/reading.db');
      expect(videoDb.existsSync(), isTrue);

      // 其他板块的库里没有这个键；小说库是另一个文件。
      final novel = await ReadingLibrary.open(Section.cat);
      expect(novel.setting(VideoPlayerSettingsStore.keySpeed), isNull);
      expect(novel.setting(VideoPlayerSettingsStore.keyKernel), isNull);
      expect(
        File('${root.path}/sections/cat/reading.db').path,
        isNot(videoDb.path),
      );
    });
  });
}
