import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'buffering.dart';
import 'player_capabilities.dart';
import 'player_error.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// 基于 AVPlayer 的播放器实现。
///
/// iOS 上 video_player 由 AVPlayer 驱动，符合 Phase1「优先 AVPlayer 实现原型」。
///
/// 播放设置消费情况（[applySettings]）：
/// - 倍速：真实生效（`setPlaybackSpeed`），加载完成后自动补挂；
/// - 字幕开关与字号：本内核基于 video_player 插件，插件按系统样式渲染自带字幕、
///   不暴露样式接口，因此暂不消费（缺口与落点记录在 Phase3 播放器文档里）。
///
/// 缓冲参数（[BufferingConfig]）：AVPlayer 的 `preferredForwardBufferDuration` /
/// `automaticallyWaitsToMinimizeStalling` **只存在于原生对象上**，Dart 侧写不到，
/// 因此这里走原生通道（`lumebox/buffering`）先写一次，再由 vendored 的
/// video_player_avfoundation 在建播放器时应用——详见 `third_party/
/// video_player_avfoundation/PATCHES.md`。写入只做一次：原生侧的参数一旦落定就
/// 对之后创建的每个播放器生效。
class AvPlayer extends AbstractPlayer {
  AvPlayer({BufferingBackend? buffering})
      : _buffering = buffering ?? createPlatformBufferingBackend();

  /// 缓冲参数的原生写通道（测试可注入替身）。
  final BufferingBackend _buffering;

  /// 是否已经把缓冲参数写进原生侧（只写一次，后续起播省掉通道往返）。
  bool _bufferingWritten = false;
  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  /// HUD 参数：video_player 只暴露分辨率 / 缓冲 / 缓冲中，
  /// 编码、帧率、码率它拿不到——留空由 HUD 自动省略（不编造）。
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    const PlayerStats(engineLabel: 'AVPlayer'),
  );

  VideoPlayerController? _controller;
  Timer? _ticker;
  bool _disposed = false;

  /// 最近一次应用的设置；加载完成后补挂到新控制器上。
  PlayerSettings _settings = const PlayerSettings();

  /// 当前音量（0..1）；加载完成后补挂到新控制器上。
  double _volume = 1.0;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  /// 能力矩阵：见 [PlayerCapabilities.of] 的唯一声明处（AVPlayer 那一栏）。
  @override
  PlayerCapabilities get capabilities =>
      PlayerCapabilities.of(PlayerKernel.avplayer);

  /// 可选音轨（video_player 在 iOS 上支持；不支持时如实返回空表）。
  @override
  Future<List<PlayerTrack>> audioTracks() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const <PlayerTrack>[];
    }
    if (!controller.isAudioTrackSupportAvailable()) {
      return const <PlayerTrack>[];
    }
    try {
      final tracks = await controller.getAudioTracks();
      return <PlayerTrack>[
        for (final track in tracks)
          PlayerTrack(
            id: track.id,
            label: _trackLabel(track.label, track.language, track.codec),
            language: track.language,
            selected: track.isSelected,
          ),
      ];
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return const <PlayerTrack>[];
    }
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.selectAudioTrack(id);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[avplayer] 切音轨失败（$id）：$error');
    }
  }

  /// 轨道展示名：标题 → 语言 → 编码 → 「音轨 N」兜底（与 MPV 侧同一套口径）。
  static String _trackLabel(String? label, String? language, String? codec) {
    final name = label?.trim();
    if (name != null && name.isNotEmpty) return name;
    final lang = language?.trim();
    if (lang != null && lang.isNotEmpty && lang != 'und') {
      return '音轨 ${lang.toUpperCase()}';
    }
    final code = codec?.trim();
    if (code != null && code.isNotEmpty) return '音轨 ${code.toUpperCase()}';
    return '音轨';
  }

  @override
  Future<void> load(PlayerMedia media) async {
    if (_disposed) return;
    // 缓冲参数要先落到原生侧：插件正是在下面的 initialize() 里建 AVPlayer，
    // 晚一步写就只对下一次起播生效（那正是「第一次起播慢」的那一次）。
    await _applyBufferingOnce();
    if (_disposed) return;
    await _releaseController();
    final controller = media.isNetwork
        ? VideoPlayerController.networkUrl(
            media.uri,
            httpHeaders: media.headers ?? const <String, String>{},
            // 后台音频继续播放：切到后台时画面停、声音不停（用户在听内容）。
            // `allowBackgroundPlayback` 是插件暴露的唯一后台开关，它顺带把
            // 音画会话设成播放类，与另一条原生通道（锁屏控制）配合工作。
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          )
        : VideoPlayerController.file(
            File.fromUri(media.uri),
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          );
    _controller = controller;
    controller.addListener(_sync);
    try {
      await controller.initialize();
      await _applySpeed();
      await controller.setVolume(_volume);
      _ticker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _sync(),
      );
      _sync();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _emit(_snapshot.value, error: PlayerErrorText.describe(error));
    }
  }

  /// 把缓冲参数写进原生侧（只写一次；失败只记日志，不打断起播）。
  Future<void> _applyBufferingOnce() async {
    if (_bufferingWritten) return;
    _bufferingWritten = true;
    try {
      await _buffering.apply(BufferingConfig.defaults);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[avplayer] 写缓冲参数失败，本次按系统默认缓冲策略播放');
    }
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration position) async => _controller?.seekTo(position);

  @override
  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    await controller.seekTo(Duration.zero);
    _sync();
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0);
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setVolume(_volume);
    } catch (error, stackTrace) {
      // 音量失败不影响播放主链路。
      LumeLog.error(error, stackTrace);
    }
  }

  /// 当前音量（0..1）。
  double get volume => _volume;

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    if (_disposed) return;
    _settings = settings;
    await _applySpeed();
  }

  /// 把倍速挂到当前控制器；控制器未就绪时静默跳过（加载完成后会补挂）。
  Future<void> _applySpeed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setPlaybackSpeed(_settings.speed);
    } catch (error, stackTrace) {
      // 倍速失败不影响播放主链路：记录后继续。
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Widget buildView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: Text('Lume Box'));
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    await _releaseController();
    _snapshot.dispose();
    _stats.dispose();
  }

  Future<void> _releaseController() async {
    _ticker?.cancel();
    _ticker = null;
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_sync);
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  void _sync() {
    final controller = _controller;
    if (controller == null || _disposed) return;
    final value = controller.value;
    _emit(PlayerSnapshot(
      position: value.position,
      duration: value.duration,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      error: value.hasError ? PlayerErrorText.describe(value.errorDescription) : null,
    ));
    _stats.value = PlayerStats(
      engineLabel: 'AVPlayer',
      width: value.size.width > 0 ? value.size.width.round() : null,
      height: value.size.height > 0 ? value.size.height.round() : null,
      buffered: _bufferedAhead(value),
      buffering: value.isBuffering,
    );
  }

  /// 缓冲状态：当前位置**前方**已缓冲的时长（取最远的一段）。
  static Duration? _bufferedAhead(VideoPlayerValue value) {
    Duration? ahead;
    for (final range in value.buffered) {
      if (range.end <= value.position) continue;
      final span = range.end - value.position;
      if (ahead == null || span > ahead) ahead = span;
    }
    return ahead;
  }

  void _emit(PlayerSnapshot next, {String? error}) {
    if (_disposed) return;
    _snapshot.value = error == null
        ? next
        : PlayerSnapshot(
            position: next.position,
            duration: next.duration,
            playing: false,
            buffering: false,
            error: error,
          );
  }
}
