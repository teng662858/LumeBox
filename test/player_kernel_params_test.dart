import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player/video_player.dart' show VideoPlayerValue;

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/av_player.dart';
import 'package:lume_box/core/player/buffering.dart';
import 'package:lume_box/core/player/mdk_engine.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

/// 三套内核在「缓冲 / 请求头」两条通道上的行为（B 项收尾）。
///
/// 这一层不依赖原生库：AVPlayer 用替身缓冲后端 + 替身 video_player 平台驱动，
/// MDK 只验**纯字符串拼装**与内核能力声明；真正「libmpv / libmdk / AVFoundation
/// 收不收」只能在真机看，本文件负责把「我们发出去了什么」钉死——真机排障时
/// 两者对照即可定位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AVPlayer 只统计当前位置连续的缓冲，不把远处片段算进去', () {
    VideoPlayerValue value(List<DurationRange> ranges) => VideoPlayerValue(
      duration: const Duration(minutes: 10),
      position: const Duration(seconds: 10),
      buffered: ranges,
    );
    expect(
      AvPlayer.bufferedAhead(
        value([
          DurationRange(
            const Duration(seconds: 30),
            const Duration(seconds: 90),
          ),
        ]),
      ),
      isNull,
    );
    expect(
      AvPlayer.bufferedAhead(
        value([
          DurationRange(
            const Duration(seconds: 15),
            const Duration(seconds: 25),
          ),
          DurationRange(
            const Duration(seconds: 8),
            const Duration(seconds: 15),
          ),
          DurationRange(
            const Duration(seconds: 40),
            const Duration(seconds: 90),
          ),
        ]),
      ),
      const Duration(seconds: 15),
    );
  });

  group('AVPlayer：缓冲参数走原生通道', () {
    late _FakeVideoPlayerPlatform platform;

    setUp(() {
      platform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = platform;
    });

    test('AVPlayer 初始化卡住会超时退出，随后可加载新媒体', () async {
      platform.holdFirst = true;
      final player = AvPlayer(
        buffering: _RecordingBufferingBackend(),
        mediaLoadTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(player.dispose);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/stuck.mp4')),
      );
      expect(player.snapshot.value.error, contains('超时'));
      expect(player.snapshot.value.buffering, false);
      expect(player.mediaInitialized, false);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/good.mp4')),
      );
      expect(player.mediaInitialized, true);
      expect(player.snapshot.value.error, isNull);
    });

    test('网络重连的初始化也会超时退出，不能停在缓冲态', () async {
      platform.failures = 1;
      platform.holdIds.add(1);
      final player = AvPlayer(
        buffering: _RecordingBufferingBackend(),
        mediaLoadTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(player.dispose);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/retry.mp4')),
      );
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      expect(platform.created, hasLength(2));
      expect(player.snapshot.value.buffering, false);
      expect(player.snapshot.value.error, contains('超时'));
    });

    test('换集加载期间清空上一集时长、79 秒缓冲和分辨率', () async {
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      addTearDown(player.dispose);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/first.mp4')),
      );
      platform._streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [DurationRange(Duration.zero, const Duration(seconds: 79))],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(player.stats.value.buffered, const Duration(seconds: 79));
      platform.holdIds.add(1);
      final pending = player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/second.mp4')),
      );
      for (var i = 0; i < 20 && platform.created.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(player.snapshot.value.duration, Duration.zero);
      expect(player.snapshot.value.position, Duration.zero);
      expect(player.snapshot.value.buffering, true);
      expect(player.stats.value.buffered, isNull);
      expect(player.stats.value.width, isNull);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.test/third.mp4')),
      );
      await pending;
      expect(player.mediaInitialized, true);
    });

    test('已初始化但仍显示缓冲的 AVPlayer 不阻塞页面接管起播', () async {
      final player = _InitializedBufferingAvPlayer();
      addTearDown(player.dispose);
      final cache = VideoDiskCache();
      addTearDown(cache.close);
      await cache
          .load(
            player,
            PlayerMedia(uri: Uri.parse('https://example.test/paused.m3u8')),
          )
          .timeout(const Duration(seconds: 1));
      expect(player.snapshot.value.buffering, true);
    });

    test(
      'buffering follows playback intent and stops on an explicit pause',
      () async {
        final player = AvPlayer(buffering: _RecordingBufferingBackend());
        addTearDown(player.dispose);
        await player.load(
          PlayerMedia(uri: Uri.parse('https://example.test/movie.mp4')),
        );
        await player.play();
        platform._streams.values.single.add(
          VideoEvent(eventType: VideoEventType.bufferingStart),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.snapshot.value.buffering, isTrue);
        await player.pause();
        expect(player.snapshot.value.buffering, isFalse);
        await player.play();
        expect(player.snapshot.value.buffering, isTrue);
      },
    );

    test('HDR display switches retain playback and position while subtitle changes do not reload video', () async {
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/video.mp4')),
      );
      expect(platform.created.single.viewType, VideoViewType.platformView);
      await player.seek(const Duration(seconds: 42));
      await player.play();
      await player.selectAudioTrack('en');
      await player.applySettings(
        const PlayerSettings(
          presentation: PlaybackPresentation(hdrEnabled: false),
        ),
      );
      expect(platform.created.length, 2);
      expect(platform.created.last.viewType, VideoViewType.textureView);
      expect(platform.positions.values, contains(const Duration(seconds: 42)));
      expect(player.snapshot.value.playing, true);
      expect(
        (await player.audioTracks()).singleWhere((t) => t.selected).id,
        'en',
      );
      await player.applySettings(
        const PlayerSettings(
          presentation: PlaybackPresentation(hdrEnabled: false),
        ).copyWith(subtitleColor: SubtitleColor.yellow),
      );
      expect(platform.created.length, 2);
      await player.dispose();
    });

    test('首播网络瞬断自动恢复并继续播放，不显示终止错误', () async {
      platform.failures = 1;
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      final errors = <String>[];
      player.snapshot.addListener(() {
        final error = player.snapshot.value.error;
        if (error != null) errors.add(error);
      });
      final loading = player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/video.mp4')),
      );
      await Future<void>.delayed(Duration.zero);
      await loading;
      await player.play();
      expect(player.snapshot.value.buffering, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      for (var i = 0; i < 20 && platform.created.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(Duration.zero);
      expect(platform.created, hasLength(2));
      expect(player.snapshot.value.error, isNull);
      expect(player.snapshot.value.playing, isTrue);
      expect(errors, isEmpty);
      await player.dispose();
    });

    test('连续失败最多重连三次，之后显示错误', () async {
      platform.failures = 10;
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/fail.mp4')),
      );
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 7400));
      expect(platform.created, hasLength(4));
      expect(player.snapshot.value.error, isNotNull);
      expect(player.snapshot.value.buffering, isFalse);
      await player.dispose();
    });

    test('重连等待中暂停取消自动起播', () async {
      platform.failures = 1;
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/pause.mp4')),
      );
      await player.play();
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(platform.created, hasLength(1));
      expect(player.snapshot.value.playing, isFalse);
      await player.dispose();
    });

    test('旧媒体初始化未完成时换内容，新加载成功且旧Future收尾', () async {
      platform.holdFirst = true;
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      final old = player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/old.mp4')),
      );
      for (var i = 0; i < 20 && platform.created.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(platform.created.length, 1);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/new.mp3')),
      );
      await old.timeout(const Duration(seconds: 1));
      expect(player.snapshot.value.error, isNull);
      expect(platform.created.length, 2);
      await player.dispose();
    });

    test('第一次起播前写一次，之后不再重复往返', () async {
      final backend = _RecordingBufferingBackend();
      final player = AvPlayer(buffering: backend);

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      expect(backend.applied, <BufferingConfig>[BufferingConfig.defaults]);

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/b.mp4')),
      );
      expect(
        backend.applied.length,
        1,
        reason: '原生侧的参数一旦落定，就对之后创建的每个 AVPlayer 生效',
      );

      await player.dispose();
    });

    test('每次换媒体前归零拖动容差，不继承上一轮关键帧档', () async {
      final backend = _RecordingBufferingBackend();
      final player = AvPlayer(buffering: backend);

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      expect(backend.seekTolerances, <Duration>[Duration.zero]);

      await player.seekFast(const Duration(seconds: 30));
      expect(
        backend.seekTolerances.last,
        AvPlayer.fastSeekTolerance,
        reason: '拖动预览允许落到关键帧',
      );

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/b.mp4')),
      );
      expect(
        backend.seekTolerances.last,
        Duration.zero,
        reason: '换集 / 换地址前必须恢复精确 seek',
      );
      await player.dispose();
    });

    test('交互跳转使用有限容差，精确跳转归零且不继承关键帧实验开关', () async {
      final backend = _RecordingBufferingBackend();
      final player = AvPlayer(buffering: backend);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      player.setFastSeekSnapToKeyframe(true);
      await player.seekInteractive(const Duration(seconds: 42));
      expect(backend.seekTolerances.last, AvPlayer.interactiveSeekTolerance);
      expect(platform.seekCalls.last, const Duration(seconds: 42));
      await player.seek(const Duration(seconds: 60));
      expect(backend.seekTolerances.last, Duration.zero);
      await player.dispose();
    });

    test('停止作废仍在设置容差的交互跳转，不把停止后的进度拉回旧目标', () async {
      final backend = _RecordingBufferingBackend();
      final player = AvPlayer(buffering: backend);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      final gate = Completer<void>();
      backend.nonZeroToleranceGate = gate;
      final pending = player.seekInteractive(const Duration(seconds: 42));
      await Future<void>.delayed(Duration.zero);
      await player.stop();
      gate.complete();
      await pending;
      expect(platform.seekCalls, [Duration.zero]);
      await player.dispose();
    });

    test('松手精确 seek 作废仍在写容差的旧 fast seek', () async {
      final backend = _RecordingBufferingBackend();
      final player = AvPlayer(buffering: backend);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );

      final gate = Completer<void>();
      backend.nonZeroToleranceGate = gate;
      final fast = player.seekFast(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(backend.seekTolerances.last, AvPlayer.fastSeekTolerance);

      await player.seek(const Duration(seconds: 40));
      gate.complete();
      await fast;

      expect(platform.seekCalls, <Duration>[
        const Duration(seconds: 40),
      ], reason: '旧快 seek 恢复后不能晚到覆盖松手目标');
      await player.dispose();
    });

    test('缓冲参数先于播放器创建：起播那一次就吃到新参数', () async {
      final backend = _RecordingBufferingBackend();
      // 平台侧记录「创建播放器时缓冲参数写过没有」——这是本项的要害：
      // 晚一步写只对下一次起播生效，而那正是「第一次起播慢」的那一次。
      platform.onCreated = () => expect(backend.applied, isNotEmpty);

      final player = AvPlayer(buffering: backend);
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      expect(platform.created, hasLength(1));
      await player.dispose();
    });

    test('逐媒体请求头原样到达平台层（A 项的回归）', () async {
      final player = AvPlayer(buffering: _RecordingBufferingBackend());
      await player.load(
        PlayerMedia(
          uri: Uri.parse('https://example.com/a.mp4'),
          headers: const <String, String>{'Referer': 'https://example.com/'},
        ),
      );

      expect(platform.created.single.dataSource.httpHeaders, <String, String>{
        'Referer': 'https://example.com/',
      }, reason: '防盗链地址丢掉 Referer 就是 CDN 403 + 退避重试（等一两分钟）');
      await player.dispose();
    });

    test('写通道抛错不影响起播链路（只记日志）', () async {
      final backend = _RecordingBufferingBackend()
        ..failure = StateError('boom');
      final player = AvPlayer(buffering: backend);

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      expect(backend.applied, isEmpty);
      expect(platform.created, hasLength(1), reason: '缓冲通道失败照样起播');
      backend.failure = null;
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/b.mp4')),
      );
      expect(backend.applied, [
        BufferingConfig.defaults,
      ], reason: '下次装载应重试失败的参数写入');

      await player.dispose();
    });

    test('非 iOS 平台：后端如实降级为「没有通道」，调用静默', () async {
      final backend = createPlatformBufferingBackend();
      await backend.apply(BufferingConfig.defaults);
      expect(await backend.isSupported(), isFalse);
    });
  });

  group('MDK：请求头走 avio.headers，缓冲参数如实声明边界', () {
    test('请求头拼装：每行 `Key: Value\\r\\n`（fvp 自己的写法）', () {
      expect(
        MdkEngine.headersText(const <String, String>{
          'Referer': 'https://example.com/',
          'User-Agent': 'LumeBox',
        }),
        'Referer: https://example.com/\r\nUser-Agent: LumeBox\r\n',
      );
      expect(
        MdkEngine.headersText(const <String, String>{
          'Referer': 'https://example.com/',
        }),
        'Referer: https://example.com/\r\n',
      );
    });

    test('空请求头拼成空串（用它清掉上一集的头，避免串味）', () {
      expect(MdkEngine.headersText(const <String, String>{}), '');
    });

    test('内核能力声明：三套内核都能携带逐媒体请求头', () {
      for (final kernel in PlayerKernel.values) {
        expect(
          PlayerFactory.supportsMediaHeaders(kernel),
          isTrue,
          reason:
              '${kernel.label}：请求头通路（AVPlayer httpHeaders / '
              'MPV httpHeaders / MDK avio.headers）都已接通',
        );
      }
    });
  });
}

/// 记录写入了什么的缓冲后端替身。
class _RecordingBufferingBackend implements BufferingBackend {
  final List<BufferingConfig> applied = <BufferingConfig>[];

  /// 非空时 apply 抛这个错（验证失败不影响播放链路）。
  Object? failure;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<void> apply(BufferingConfig config) async {
    final error = failure;
    if (error != null) throw error;
    applied.add(config);
  }

  @override
  Future<void> applySeekTolerance(Duration tolerance) async {
    seekTolerances.add(tolerance);
    if (tolerance != Duration.zero) {
      final gate = nonZeroToleranceGate;
      if (gate != null) await gate.future;
    }
  }

  Completer<void>? nonZeroToleranceGate;
  final List<Duration> seekTolerances = <Duration>[];
}

/// 替身 video_player 平台：把「创建播放器」与「请求头」记下来，并推一个
/// initialized 事件让 controller 走完初始化。
class _InitializedBufferingAvPlayer extends AvPlayer {
  final state = ValueNotifier(const PlayerSnapshot(buffering: true));
  @override
  ValueListenable<PlayerSnapshot> get snapshot => state;
  @override
  bool get mediaInitialized => true;
  @override
  Future<void> load(PlayerMedia media) async {}
  @override
  Future<void> dispose() async {
    state.dispose();
    await super.dispose();
  }
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<VideoCreationOptions> created = <VideoCreationOptions>[];
  final Map<int, StreamController<VideoEvent>> _streams =
      <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final seekCalls = <Duration>[];
  int _nextId = 0;
  bool holdFirst = false;
  final holdIds = <int>{};
  int failures = 0;

  /// 创建播放器时的钩子（用来断言「缓冲参数已经写过了」）。
  void Function()? onCreated;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => null;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    created.add(options);
    onCreated?.call();
    final stream = StreamController<VideoEvent>();
    _streams[id] = stream;
    // 事件必须在 controller 订阅之后再推，否则首帧状态会丢。
    scheduleMicrotask(() {
      if (holdFirst && id == 0 || holdIds.contains(id)) return;
      if (id < failures) {
        stream.addError(
          PlatformException(
            code: 'VideoError',
            message: 'Network connection lost -1005',
          ),
        );
        return;
      }
      stream.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1280, 720),
          duration: const Duration(minutes: 2),
        ),
      );
    });
    return id;
  }

  @override
  Future<void> dispose(int playerId) async =>
      _streams.remove(playerId)?.close();

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  final selectedAudio = <int, String>{};
  @override
  bool isAudioTrackSupportAvailable() => true;
  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) async => [
    for (final language in ['zh', 'en'])
      VideoAudioTrack(
        id: language,
        label: language,
        language: language,
        isSelected: (selectedAudio[playerId] ?? 'zh') == language,
      ),
  ];
  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async {
    selectedAudio[playerId] = trackId;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCalls.add(position);
    positions[playerId] = position;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleep,
  ) async {}

  @override
  Future<void> setWebOptions(
    int playerId,
    VideoPlayerWebOptions options,
  ) async {}
}
