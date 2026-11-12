import 'package:lume_box/core/intro/intro_store.dart';

import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/playback_orientation.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 播放器全套功能对齐（真机反馈的第 5 项）：能力矩阵、按内核分别记住、
/// 统一控制面板、清晰度切换、统一提示。
///
/// 这一份把「界面层的契约」钉住：控件**不随内核变化显隐**、不支持的项点了弹统一
/// 提示、倍速 / 画面 / 字幕按内核分别记住、清晰度只在图源给了多线路时弹菜单。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_player_full');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    await SectionScope.open(Section.video);
    await ReadingLibrary.open(Section.video);
    await IntroStore.open();
  });

  tearDown(() async {
    await IntroStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  setUp(() => PlayerFactory.clearMpvInitFailure());

  // 方向偏好是应用级单例：每条用例从「自动」起步，免得相互串。
  setUp(PlaybackOrientationController.instance.resetForTesting);
  tearDown(PlaybackOrientationController.instance.resetForTesting);

  /// 三套内核各一份能力矩阵（**唯一声明处**）。
  group('能力矩阵：控件不随内核显隐，差异只在提示', () {
    test('每一项都有明确归属：AVPlayer / MPV / MDK', () {
      final avplayer = PlayerCapabilities.of(PlayerKernel.avplayer);
      final mpv = PlayerCapabilities.of(PlayerKernel.mpv);
      final mdk = PlayerCapabilities.of(PlayerKernel.mdk);

      // 音轨：三套都能（avfoundation 明确支持音频轨选择）。
      expect(avplayer.audioTracks, isTrue);
      expect(mpv.audioTracks, isTrue);
      expect(mdk.audioTracks, isTrue);

      // 字幕样式：只有 MPV（Flutter 字幕层）；AVPlayer 按系统样式、MDK 内嵌渲染。
      expect(mpv.subtitleStyle, isTrue);
      expect(avplayer.subtitleStyle, isFalse);
      expect(mdk.subtitleStyle, isFalse);

      // 外挂字幕：AVPlayer 的文字字幕层支持 SRT / VTT；MPV / MDK 走内核。
      expect(mpv.externalSubtitle, isTrue);
      expect(mdk.externalSubtitle, isTrue);
      expect(avplayer.externalSubtitle, isTrue);
      expect(avplayer.subtitleTracks, isTrue);

      // 延迟与硬解：只有 MPV 两项俱全（libmpv 属性通道）。
      expect(mpv.subtitleDelay, isTrue);
      expect(mpv.audioDelay, isTrue);
      expect(mpv.hardwareDecoding, isTrue);
      expect(avplayer.audioDelay, isFalse);
      expect(mdk.audioDelay, isFalse);
      expect(mdk.hardwareDecoding, isTrue);
      expect(mdk.subtitleDelay, isTrue);

      // 后台音频 / 锁屏控制 / 缓冲参数：走宿主原生通道，与内核无关。
      for (final caps in <PlayerCapabilities>[avplayer, mpv, mdk]) {
        expect(caps.backgroundAudio, isTrue);
        expect(caps.nowPlaying, isTrue);
      }
      expect(avplayer.bufferingParams, isTrue);
      expect(mpv.bufferingParams, isTrue);
      expect(mdk.bufferingParams, isTrue);
    });

    test('统一提示文案（用户点名的口径）', () {
      expect(PlayerCapabilities.unsupportedMessage, '当前播放器内核不支持该功能，请切换其它播放器');
    });

    test('替身播放器默认「什么都不支持」：能力必须显式声明', () {
      final player = _FakePlayer();
      expect(player.capabilities, PlayerCapabilities.none);
    });
  });

  group('按内核分别记住（倍速 / 画面 / 字幕）', () {
    test('切内核读的是那个内核自己的值', () {
      var settings = const PlayerSettings();
      // AVPlayer：1.5x 速 + 旋转 90
      settings = settings.copyWith(speed: 1.5, rotation: RotationMode.cw90);
      expect(settings.speed, 1.5);
      expect(settings.rotation, RotationMode.cw90);

      // 切到 MPV：拿到的是 MPV 自己的默认值，不是 AVPlayer 调好的
      settings = settings.copyWith(kernel: PlayerKernel.mpv);
      expect(settings.speed, PlayerSettings.defaultSpeed);
      expect(settings.rotation, RotationMode.none);

      // 在 MPV 上调 2.0x + 填充
      settings = settings.copyWith(speed: 2.0, zoom: ZoomMode.fill);
      expect(settings.speed, 2.0);

      // 切回 AVPlayer：1.5x 与旋转 90 还在
      settings = settings.copyWith(kernel: PlayerKernel.avplayer);
      expect(settings.speed, 1.5, reason: 'AVPlayer 的倍速按内核记住');
      expect(settings.rotation, RotationMode.cw90);
      expect(settings.zoom, ZoomMode.fit);

      // MPV 那份也没丢
      settings = settings.copyWith(kernel: PlayerKernel.mpv);
      expect(settings.speed, 2.0);
      expect(settings.zoom, ZoomMode.fill);
    });

    test('倍速档位：0.25~4.0、步长 0.25', () {
      expect(PlayerSettings.minSpeed, 0.25);
      expect(PlayerSettings.maxSpeed, 4.0);
      expect(PlayerSettings.speeds.first, 0.25);
      expect(PlayerSettings.speeds.last, 4.0);
      for (var index = 1; index < PlayerSettings.speeds.length; index++) {
        expect(
          PlayerSettings.speeds[index] - PlayerSettings.speeds[index - 1],
          closeTo(0.25, 1e-9),
          reason: '相邻档位差 0.25',
        );
      }
    });

    test('倍速归一：非档位值落到最近档位', () {
      expect(PlayerSettings.normalizeSpeed(0.3), 0.25);
      expect(PlayerSettings.normalizeSpeed(1.6), 1.5);
      expect(PlayerSettings.normalizeSpeed(3.9), 4.0);
      expect(PlayerSettings.normalizeSpeed(9), 4.0);
      expect(PlayerSettings.normalizeSpeed(double.nan), 1.0);
    });

    test('字幕底色归一：夹到 0..1 并归到 0.05', () {
      expect(KernelPrefs.normalizeSubtitleBackground(0.42), 0.4);
      expect(KernelPrefs.normalizeSubtitleBackground(-1), 0.0);
      expect(KernelPrefs.normalizeSubtitleBackground(3), 1.0);
      expect(
        KernelPrefs.normalizeSubtitleBackground(double.nan),
        KernelPrefs.defaultSubtitleBackground,
      );
    });

    test('偏好 JSON 往返：坏值只影响那一项', () {
      const prefs = KernelPrefs(
        speed: 1.25,
        zoom: ZoomMode.stretch,
        rotation: RotationMode.cw270,
        mirrored: true,
        subtitleSize: SubtitleSize.large,
        subtitleColor: SubtitleColor.yellow,
        subtitleOutline: SubtitleOutline.thick,
        subtitleBackground: 0.8,
        subtitleDelay: Duration(milliseconds: -1500),
        audioDelay: Duration(milliseconds: 500),
      );
      expect(KernelPrefs.fromJson(prefs.toJson()), prefs);

      final broken = KernelPrefs.fromJson(<String, Object?>{
        'speed': 'not-a-number',
        'zoom': 'nope',
        'rotation': 90,
        'mirrored': true,
        'subtitleDelayMs': 999999,
      });
      expect(broken.speed, PlayerSettings.defaultSpeed);
      expect(broken.zoom, ZoomMode.fit);
      expect(broken.rotation, RotationMode.cw90, reason: '角度也能反查');
      expect(broken.mirrored, isTrue);
      expect(broken.subtitleDelay, const Duration(seconds: 10), reason: '越界夹回');
    });
  });

  group('设置持久化：每内核一格 + 老库迁移', () {
    test('写库后按内核各读各的', () async {
      final store = await VideoPlayerSettingsStore.open();
      var settings = const PlayerSettings().copyWith(
        kernel: PlayerKernel.avplayer,
        speed: 1.5,
      );
      settings = settings.copyWith(kernel: PlayerKernel.mpv, speed: 2.0);
      store.save(settings);

      final reloaded = store.load();
      expect(reloaded.kernel, PlayerKernel.mpv);
      expect(reloaded.speed, 2.0, reason: 'MPV 那一格是自己存进去的');
      expect(
        reloaded.copyWith(kernel: PlayerKernel.avplayer).speed,
        1.5,
        reason: 'AVPlayer 那一格也在（上次保存时的值）',
      );
    });

    test('老库（只有全局键）能读出来并迁给当前内核', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting(VideoPlayerSettingsStore.keyKernel, 'avplayer');
      library.setSetting(VideoPlayerSettingsStore.keySpeed, '1.75');
      library.setSetting(VideoPlayerSettingsStore.keySubtitleSize, 'large');
      library.setSetting(VideoPlayerSettingsStore.keySubtitleDelay, '-2000');

      final store = VideoPlayerSettingsStore(library);
      final loaded = store.load();
      expect(loaded.kernel, PlayerKernel.avplayer);
      expect(loaded.speed, 1.75, reason: '老键里的倍速迁过来');
      expect(loaded.subtitleSize, SubtitleSize.large);
      expect(loaded.subtitleDelay, const Duration(seconds: -2));

      // 迁移后写一次：老键仍镜像（回退到旧版本也读得懂）。
      store.save(loaded);
      expect(library.setting(VideoPlayerSettingsStore.keySpeed), '1.75');
      expect(
        library.setting(
          VideoPlayerSettingsStore.keyPrefsFor(PlayerKernel.avplayer),
        ),
        isNotNull,
      );
    });
  });
}

class _FakePlayer extends AbstractPlayer {
  _FakePlayer();

  final PlayerKernel? kernel = null;

  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(),
  );
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: 'fake'),
  );

  final subtitleSelections = <String?>[];
  @override
  Future<void> selectSubtitleTrack(String? id) async {
    subtitleSelections.add(id);
  }

  PlayerMedia? media;
  final List<Duration> seeks = <Duration>[];

  /// 拖动中的快 seek（内核允许落到关键帧那一档）。
  final List<Duration> fastSeeks = <Duration>[];

  /// 非 null 时 seek / seekFast 都挂在它上面：模拟「内核的跳转回调不来」。
  Completer<void>? seekGate;

  Object? seekError;
  Object? loadError;
  int plays = 0, pauses = 0, stops = 0, disposals = 0, loads = 0;
  double volume = 1;
  PlayerSettings? lastAppliedSettings;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  void pushStats(PlayerStats next) => _stats.value = next;

  void emit({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    String? error,
  }) {
    _snapshot.value = PlayerSnapshot(
      position: position ?? _snapshot.value.position,
      duration: duration ?? _snapshot.value.duration,
      playing: playing ?? _snapshot.value.playing,
      buffering: buffering ?? _snapshot.value.buffering,
      error: error,
    );
  }

  @override
  Future<void> load(PlayerMedia media) async {
    if (loadError case final error?) throw error;
    loads++;
    this.media = media;
  }

  @override
  Future<void> play() async {
    plays++;
    emit(playing: true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    emit(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    if (seekError case final error?) throw error;
    seeks.add(position);
    final gate = seekGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> seekFast(Duration position) async {
    fastSeeks.add(position);
    final gate = seekGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    lastAppliedSettings = settings;
  }

  @override
  Widget buildView() => const Text('fake-view');

  @override
  Future<void> dispose() async {
    disposals++;
  }
}
