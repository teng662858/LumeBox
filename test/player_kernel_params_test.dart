import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/av_player.dart';
import 'package:lume_box/core/player/buffering.dart';
import 'package:lume_box/core/player/mdk_engine.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';

/// 三套内核在「缓冲 / 请求头」两条通道上的行为（B 项收尾）。
///
/// 这一层不依赖原生库：AVPlayer 用替身缓冲后端 + 替身 video_player 平台驱动，
/// MDK 只验**纯字符串拼装**与内核能力声明；真正「libmpv / libmdk / AVFoundation
/// 收不收」只能在真机看，本文件负责把「我们发出去了什么」钉死——真机排障时
/// 两者对照即可定位。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AVPlayer：缓冲参数走原生通道', () {
    late _FakeVideoPlayerPlatform platform;

    setUp(() {
      platform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = platform;
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

      expect(
        platform.created.single.dataSource.httpHeaders,
        <String, String>{'Referer': 'https://example.com/'},
        reason: '防盗链地址丢掉 Referer 就是 CDN 403 + 退避重试（等一两分钟）',
      );
      await player.dispose();
    });

    test('写通道抛错不影响起播链路（只记日志）', () async {
      final backend = _RecordingBufferingBackend()..failure = StateError('boom');
      final player = AvPlayer(buffering: backend);

      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      expect(backend.applied, isEmpty);
      expect(platform.created, hasLength(1), reason: '缓冲通道失败照样起播');

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
          reason: '${kernel.label}：请求头通路（AVPlayer httpHeaders / '
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
}

/// 替身 video_player 平台：把「创建播放器」与「请求头」记下来，并推一个
/// initialized 事件让 controller 走完初始化。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<VideoCreationOptions> created = <VideoCreationOptions>[];
  final Map<int, StreamController<VideoEvent>> _streams =
      <int, StreamController<VideoEvent>>{};
  int _nextId = 0;

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
  Future<void> dispose(int playerId) async => _streams.remove(playerId)?.close();

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

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
  Future<void> setWebOptions(int playerId, VideoPlayerWebOptions options) async {}
}
