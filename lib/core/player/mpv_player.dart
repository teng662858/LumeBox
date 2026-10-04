import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'abstract_player.dart';
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
/// - 字幕字号：仍待自研字幕层（与 AVPlayer 内核同一待办，见 Phase3 播放器文档）。
class MpvPlayer implements AbstractPlayer {
  MpvPlayer({
    required MpvEngine engine,
    this.engineLabel = 'MPV',
  }) : _engine = engine {
    engine.listen(_onEngineSnapshot);
  }

  final MpvEngine _engine;

  /// 内核显示名（HUD 上标明参数来自哪个内核）。
  final String engineLabel;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  final ValueNotifier<PlayerStats> _stats =
      ValueNotifier<PlayerStats>(PlayerStats(engineLabel: 'MPV'));

  PlayerSettings _settings = const PlayerSettings();
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
  Future<void> applySettings(PlayerSettings settings) async {
    if (_disposed) return;
    _settings = settings;
    await _engine.setSpeed(settings.speed);
    await _engine.setSubtitleEnabled(settings.subtitlesEnabled);
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
