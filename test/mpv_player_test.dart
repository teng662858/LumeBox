import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/buffering.dart';
import 'package:lume_box/core/player/media_kit_mpv_engine.dart';
import 'package:lume_box/core/player/mpv_engine.dart';
import 'package:lume_box/core/player/mpv_player.dart';
import 'package:lume_box/core/player/player_settings.dart';

/// MPV 内核的验证：AbstractPlayer 全量契约、命令映射、状态与 HUD 组装。
///
/// 用替身引擎驱动 [MpvPlayer]——libmpv 通过 [MpvEngine] 端口挡在外面，
/// 因此没有原生库的机器（含 CI）也能把这条链路验完。
void main() {
  late _FakeMpvEngine engine;
  late MpvPlayer player;

  setUp(() {
    engine = _FakeMpvEngine();
    player = MpvPlayer(engine: engine, engineLabel: 'MPV');
  });

  tearDown(() async {
    await player.dispose();
  });

  test('load：媒体与请求头交给引擎，且不自动播放（与 AVPlayer 同口径）', () async {
    await player.load(
      PlayerMedia(
        uri: Uri.parse('https://example.com/a.mp4'),
        headers: const <String, String>{'Referer': 'https://example.com'},
      ),
    );

    final request = engine.opened!;
    expect(request.url, 'https://example.com/a.mp4');
    expect(request.headers, <String, String>{'Referer': 'https://example.com'});
    expect(request.autoplay, isFalse, reason: 'load 只装载，播放由上层显式发起');
    expect(request.speed, 1.0, reason: '起播倍速取当前设置');
    expect(request.startAt, isNull);
  });

  test('play / pause / seek / stop：逐个映射到引擎', () async {
    await player.load(PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')));
    await player.play();
    await player.pause();
    await player.seek(const Duration(seconds: 42));
    await player.stop();

    expect(engine.calls, <String>['open', 'play', 'pause', 'seek:42', 'stop']);
    // stop 之后上层看到的是「回到起点且未播放」。
    expect(player.snapshot.value.position, Duration.zero);
    expect(player.snapshot.value.playing, isFalse);
  });

  test('applySettings：倍速与字幕开关都下发给引擎', () async {
    await player.applySettings(
      const PlayerSettings(kernel: PlayerKernel.mpv, speed: 1.5, subtitlesEnabled: false),
    );

    expect(engine.speed, 1.5);
    expect(engine.subtitleEnabled, isFalse);

    await player.applySettings(
      const PlayerSettings(kernel: PlayerKernel.mpv, speed: 2.0, subtitlesEnabled: true),
    );
    expect(engine.speed, 2.0);
    expect(engine.subtitleEnabled, isTrue);
  });

  test('setVolume：钳制到 0..1 后下发给引擎，供手势直接调用', () async {
    await player.setVolume(0.35);
    expect(engine.volume, 0.35);
    expect(player.volume, 0.35);

    // 手势换算可能算出越界值（滑过头），播放器层兜底钳制。
    await player.setVolume(1.4);
    expect(engine.volume, 1.0);
    await player.setVolume(-0.2);
    expect(engine.volume, 0.0);
    expect(player.volume, 0.0);
  });

  test('状态映射：位置 / 时长 / 播放 / 缓冲 / 错误都取自引擎快照', () async {
    engine.emit(
      const MpvEngineSnapshot(
        position: Duration(seconds: 30),
        duration: Duration(minutes: 45),
        playing: true,
        buffering: true,
      ),
    );

    final snapshot = player.snapshot.value;
    expect(snapshot.position, const Duration(seconds: 30));
    expect(snapshot.duration, const Duration(minutes: 45));
    expect(snapshot.playing, isTrue);
    expect(snapshot.buffering, isTrue);
    expect(snapshot.error, isNull);

    engine.emit(const MpvEngineSnapshot(error: '打开失败：连接超时'));
    expect(player.snapshot.value.error, '打开失败：连接超时');
    expect(player.snapshot.value.playing, isFalse);
  });

  test('HUD：编码 / 分辨率 / 帧率 / 码率 / 缓冲全部来自引擎', () async {
    engine.emit(
      const MpvEngineSnapshot(
        videoCodec: 'hevc',
        audioCodec: 'aac',
        videoBitrateKbps: 1800,
        fps: 30,
        width: 1920,
        height: 1080,
        buffered: Duration(seconds: 12),
      ),
    );

    expect(player.stats.value.chips, <String>[
      'MPV',
      'HEVC',
      '1920×1080',
      '30FPS',
      '1.8Mbps',
      '缓冲 12s',
    ]);
  });

  test('HUD：引擎拿不到的项自动省略，不编造', () async {
    // 纯音频：没有分辨率与帧率。
    engine.emit(
      const MpvEngineSnapshot(audioCodec: 'mp3', audioBitrateKbps: 320),
    );

    expect(player.stats.value.chips, <String>['MPV', 'MP3', '320kbps']);

    // 什么参数都还没有时只剩内核名（HUD 仍标明当前内核）。
    engine.emit(const MpvEngineSnapshot());
    expect(player.stats.value.chips, <String>['MPV']);
    expect(player.stats.value.hasParameters, isFalse);
  });

  test('HUD：加载新媒体的瞬间清空上一部片子的参数（不留残留）', () async {
    engine.emit(
      const MpvEngineSnapshot(videoCodec: 'h264', width: 1280, height: 720),
    );
    expect(player.stats.value.chips, contains('1280×720'));

    await player.load(PlayerMedia(uri: Uri.parse('https://example.com/b.mp4')));
    expect(
      player.stats.value.chips,
      <String>['MPV'],
      reason: '换片后旧参数必须消失，等引擎给出新参数再显示',
    );
  });

  test('buildView：用引擎给的渲染面（上层不感知 media_kit）', () {
    final view = player.buildView();
    expect(view, isA<Text>());
    expect((view as Text).data, 'mpv-view');
  });

  test('dispose：释放引擎且之后的调用安全', () async {
    await player.dispose();
    expect(engine.disposed, isTrue);

    await player.load(PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')));
    await player.play();
    await player.seek(const Duration(seconds: 1));
    await player.applySettings(const PlayerSettings(speed: 1.5));
    expect(engine.opened, isNull, reason: '已释放后不再触达引擎');
    // 重复释放是安全的。
    await player.dispose();
  });

  test('单位换算：mpv 的 bps 在引擎层换算成 kbps（HUD 口径统一）', () {
    expect(MediaKitMpvEngine.toKbps(1800000), 1800);
    expect(MediaKitMpvEngine.toKbps(320000), 320);
    expect(MediaKitMpvEngine.toKbps(null), isNull);
    expect(MediaKitMpvEngine.toKbps(0), isNull);
    expect(MediaKitMpvEngine.toKbps(-1), isNull);
  });

  group('引擎属性写通道（缓冲 / 硬解 / 字幕延迟）', () {
    test('属性映射：写进 libmpv 的名字与单位在这里定死', () {
      // 缓冲参数
      expect(
        MpvProperties.buffering(BufferingConfig.defaults),
        <String, String>{
          'cache': 'yes',
          'cache-pause-initial': 'no',
          'demuxer-readahead-secs': '15',
          'demuxer-max-bytes': '${64 * 1024 * 1024}',
          'demuxer-max-back-bytes': '${16 * 1024 * 1024}',
        },
      );
      // 硬解
      expect(MpvProperties.hardwareDecoding(true), <String, String>{'hwdec': 'auto'});
      expect(MpvProperties.hardwareDecoding(false), <String, String>{'hwdec': 'no'});
      // 延迟：libmpv 的单位是**秒**，可负
      expect(
        MpvProperties.subtitleDelay(const Duration(milliseconds: -1500)),
        <String, String>{'sub-delay': '-1.5'},
      );
      expect(
        MpvProperties.subtitleDelay(const Duration(milliseconds: 2000)),
        <String, String>{'sub-delay': '2.0'},
      );
      expect(
        MpvProperties.audioDelay(const Duration(milliseconds: 250)),
        <String, String>{'audio-delay': '0.25'},
      );
    });

    test('批量写入：计数只算被内核接受的（拒绝写入 = 0）', () async {
      final sink = _PropertyFakeEngine();
      expect(
        await writeEngineProperties(sink, <String, String>{'a': '1', 'b': '2'}),
        2,
      );
      expect(sink.properties, <String, String>{'a': '1', 'b': '2'});

      sink.reject = true;
      expect(
        await writeEngineProperties(sink, <String, String>{'c': '3'}),
        0,
        reason: '内核回负值时不假装生效',
      );
      expect(sink.properties.containsKey('c'), isFalse);
    });

    test('没有属性通道的引擎：整条链路照常跑（如实降级，不抛异常）', () async {
      // engine 是 _FakeMpvEngine：没有实现 EnginePropertyCapable。
      await player.load(
        PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
      );
      await player.applySettings(
        const PlayerSettings(kernel: PlayerKernel.mpv, hardwareDecoding: false),
      );

      expect(engine.buffering, BufferingConfig.defaults,
          reason: '缓冲配置照样下发到引擎端口（写不写得进去由引擎自己决定）');
      expect(engine.hardwareDecoding, isFalse);
      expect(engine.opened, isNotNull);
    });
  });
}

/// 替身 MPV 引擎：记录命令、按需推快照。
class _FakeMpvEngine implements MpvEngine {
  final List<String> calls = <String>[];
  MpvMediaRequest? opened;
  double? speed;
  double? volume;
  bool? subtitleEnabled;
  bool disposed = false;

  void Function(MpvEngineSnapshot snapshot)? _listener;

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {
    _listener = onSnapshot;
  }

  /// 测试驱动：模拟 libmpv 推来一份快照。
  void emit(MpvEngineSnapshot snapshot) => _listener?.call(snapshot);

  @override
  Future<void> open(MpvMediaRequest request) async {
    calls.add('open');
    opened = request;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inSeconds}');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setSpeed(double value) async => speed = value;

  @override
  Future<void> setVolume(double value) async => volume = value;

  /// 测试可注入的帧（为空时 captureFrame 返回 null，模拟「拿不到帧」）。
  MpvVideoFrame? nextFrame;

  @override
  Future<MpvVideoFrame?> captureFrame() async => nextFrame;

  @override
  Future<void> setSubtitleEnabled(bool enabled) async =>
      subtitleEnabled = enabled;

  /// 字幕样式（引擎端口新增能力；假引擎只记录）。
  SubtitleStyle? subtitleStyle;

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async =>
      subtitleStyle = style;

  @override
  final ValueNotifier<int> subtitleStyleRevision = ValueNotifier<int>(0);

  /// 字幕延迟（引擎端口新增能力；假引擎只记录）。
  Duration? subtitleDelay;

  @override
  Future<void> setSubtitleDelay(Duration delay) async =>
      subtitleDelay = delay;

  /// 硬件解码开关（引擎端口新增能力；假引擎只记录）。
  bool? hardwareDecoding;

  @override
  Future<void> setHardwareDecoding(bool enabled) async =>
      hardwareDecoding = enabled;

  /// 起播缓冲参数（引擎端口新增能力；假引擎只记录）。
  BufferingConfig? buffering;

  @override
  Future<void> setBuffering(BufferingConfig config) async => buffering = config;

  @override
  Widget buildView() => const Text('mpv-view');

  @override
  Future<void> dispose() async => disposed = true;
}

/// 带属性写通道的替身引擎（`EnginePropertyCapable`）。
///
/// 比 [_FakeMpvEngine] 只多一件事：记录写过的属性——用来钉住「哪些参数真的写进
/// 了 libmpv、单位换算对不对」，以及「引擎没有写通道时不假装支持」。
class _PropertyFakeEngine extends _FakeMpvEngine
    implements EnginePropertyCapable {
  /// 属性名 → 值（后写的覆盖先写的）。
  final Map<String, String> properties = <String, String>{};

  /// 是否拒绝写入（模拟 libmpv 回负值 / 属性名不被内核接受）。
  bool reject = false;

  @override
  Future<bool> setEngineProperty(String name, String value) async {
    if (reject) return false;
    properties[name] = value;
    return true;
  }
}
