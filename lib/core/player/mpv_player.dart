import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'abstract_player.dart';
import 'buffering.dart';
import 'mpv_engine.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// 基于 **libmpv** 的播放器实现（Phase1 的第二套内核）。
///
/// 层级：`MpvPlayer`（本文件，AbstractPlayer 的实现：命令映射、状态与 HUD
/// 组装、生命周期）→ [MpvEngine]（端口）→ `MediaKitMpvEngine`（libmpv 绑定）。
/// 这一层不 import 任何 mpv/media_kit 类型，因此：
/// - 换/升级原生绑定不用动本文件；
/// - 测试注入替身即可在无 libmpv 的机器上验证 AbstractPlayer 契约与 HUD。
///
/// 播放设置消费情况（[applySettings]）：
/// - 倍速：真实生效（libmpv `speed`）；
/// - 字幕开关：真实生效（libmpv 轨道选择，`auto` / `no`）；
/// - 字幕字号 / 颜色 / 描边：**真实生效**（media_kit 的字幕层是 Flutter Widget，
///   收完整 TextStyle；描边用多层阴影模拟）；
/// - 字幕延迟 / 硬件解码：**真实生效**（写 libmpv 的 `sub-delay` / `hwdec`，
///   见 `MediaKitMpvEngine.setEngineProperty`；hwdec 对随后打开的媒体生效）。
///
/// 缓冲参数（[BufferingConfig]）：在**每次装载前**写进 libmpv（`cache` /
/// `cache-pause-initial` / `demuxer-*`），也就是「起播前把缓冲策略定下来」。
class MpvPlayer implements AbstractPlayer {
  MpvPlayer({
    required MpvEngine engine,
    this.engineLabel = 'MPV',
    this.buffering = BufferingConfig.defaults,
  }) : _engine = engine {
    engine.listen(_onEngineSnapshot);
  }

  final MpvEngine _engine;

  /// 起播缓冲参数（见 [BufferingConfig]）。
  final BufferingConfig buffering;

  /// 引擎访问点：画中画帧转发需要直接向引擎取帧（拉取式接口）。
  /// 上层据此判断「当前内核有没有帧导出能力」，而不是猜类型。
  MpvEngine get engine => _engine;

  /// 内核显示名（HUD 上标明参数来自哪个内核）。
  final String engineLabel;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  final ValueNotifier<PlayerStats> _stats =
      ValueNotifier<PlayerStats>(PlayerStats(engineLabel: 'MPV'));

  PlayerSettings _settings = const PlayerSettings();
  double _volume = 1.0;
  bool _disposed = false;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {
    if (_disposed) return;
    // 与 AVPlayer 内核同口径：load 只装载，不自动播放。
    _emit(const PlayerSnapshot(), stats: _emptyStats());
    // 缓冲策略必须在打开媒体**之前**定下来：libmpv 的 cache / 预读时长是
    // 打开文件时读一次的属性。
    await _engine.setBuffering(buffering);
    await _engine.open(
      MpvMediaRequest(
        url: media.uri.toString(),
        headers: media.headers,
        speed: _settings.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    await _engine.play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _engine.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _engine.seek(position);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await _engine.stop();
    _emit(
      PlayerSnapshot(
        duration: _snapshot.value.duration,
        error: _snapshot.value.error,
      ),
      stats: _stats.value,
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0);
    await _engine.setVolume(_volume);
  }

  /// 当前音量（0..1）；手势层的基准。
  double get volume => _volume;

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    if (_disposed) return;
    _settings = settings;
    await _engine.setSpeed(settings.speed);
    await _engine.setSubtitleEnabled(settings.subtitlesEnabled);
    // 字幕样式（字号 / 颜色 / 描边）真实生效：media_kit 的字幕层收完整 TextStyle。
    await _engine.setSubtitleStyle(
      SubtitleStyle(
        fontScale: settings.subtitleSize.scale,
        colorArgb: settings.subtitleColor.argb,
        outlineWidth: settings.subtitleOutline.width,
      ),
    );
    // 延迟与硬解：当前内核未开放通道，引擎侧只记录（见 MpvEngine 的说明）。
    await _engine.setSubtitleDelay(settings.subtitleDelay);
    await _engine.setHardwareDecoding(settings.hardwareDecoding);
  }

  @override
  Widget buildView() => _engine.buildView();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _engine.dispose();
    _snapshot.dispose();
    _stats.dispose();
  }

  /// 引擎快照 → 播放状态 + HUD 参数。
  ///
  /// HUD 的每一项都来自引擎（libmpv）真给得出的字段；引擎没给的留空，
  /// [PlayerStats.chips] 会自动省略——上层不需要知道内核能拿到什么。
  void _onEngineSnapshot(MpvEngineSnapshot source) {
    if (_disposed) return;
    _emit(
      PlayerSnapshot(
        position: source.position,
        duration: source.duration,
        playing: source.playing,
        buffering: source.buffering,
        error: source.error,
      ),
      stats: PlayerStats(
        engineLabel: engineLabel,
        videoCodec: source.videoCodec,
        audioCodec: source.audioCodec,
        videoBitrateKbps: source.videoBitrateKbps,
        audioBitrateKbps: source.audioBitrateKbps,
        fps: source.fps,
        width: source.width,
        height: source.height,
        buffered: source.buffered,
        buffering: source.buffering,
      ),
    );
  }

  PlayerStats _emptyStats() => PlayerStats(engineLabel: engineLabel);

  void _emit(PlayerSnapshot snapshot, {PlayerStats? stats}) {
    if (_disposed) return;
    _snapshot.value = snapshot;
    if (stats != null) _stats.value = stats;
  }
}
