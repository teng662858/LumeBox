import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../util/lume_log.dart';
import 'abstract_player.dart';
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
class AvPlayer implements AbstractPlayer {
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

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {
    if (_disposed) return;
    await _releaseController();
    final controller = media.isNetwork
        ? VideoPlayerController.networkUrl(
            media.uri,
            httpHeaders: media.headers ?? const <String, String>{},
          )
        : VideoPlayerController.file(File.fromUri(media.uri));
    _controller = controller;
    controller.addListener(_sync);
    try {
      await controller.initialize();
      await _applySpeed();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _sync(),
      );
      _sync();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _emit(_snapshot.value, error: '$error');
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
      error: value.hasError ? value.errorDescription : null,
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
