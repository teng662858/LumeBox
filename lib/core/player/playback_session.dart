import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/lume_log.dart';

/// 播放会话（后台播放 + 锁屏控制）的原生后端端口。
///
/// 与画中画 / 亮度 / 语音同一套做法：平台能力做成端口，原生未接入时如实降级。
///
/// 为什么必须走原生：这两件事都发生在**播放器之外**——
/// - 后台音频继续播放：要让系统的音画会话按「播放类」工作，
///   （Android / iOS 的具体表达不同，iOS 是 `AVAudioSession` 的 category）；
/// - 锁屏 / 控制中心的媒体控制器：`MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`
///   才有「播放条 / 暂停 / 上一集 / 下一集」，Dart 侧拿不到这些对象。
abstract interface class PlaybackSessionBackend {
  /// 平台是否提供原生播放会话（iOS 走原生通道，其余平台如实为 false）。
  Future<bool> isSupported();

  /// 开始一次播放会话：[title] 等用于系统播放条，[duration] 未知时传零。
  Future<void> start({
    required String title,
    String? subtitle,
    Duration duration,
    double speed,
  });

  /// 同步播放状态（播放条上的进度与播放 / 暂停要跟着走）。
  Future<void> update({
    Duration? position,
    bool? playing,
    Duration? duration,
    double? speed,
  });

  /// 结束会话（页面退出 / 播放停止）：清掉播放条，系统控件不再指向本 App。
  Future<void> stop();

  /// 系统控件的操作事件（播放 / 暂停 / 暂停恢复 / 切集…）。
  Stream<PlaybackSessionCommand> get commands;
}

/// 系统媒体控件的操作。
enum PlaybackSessionCommand {
  play('play'),
  pause('pause'),
  toggle('toggle'),
  next('next'),
  previous('previous');

  const PlaybackSessionCommand(this.id);

  final String id;

  static PlaybackSessionCommand? fromId(String? id) {
    for (final command in values) {
      if (command.id == id) return command;
    }
    return null;
  }
}

/// 没有原生播放会话的降级实现（非 iOS）。
class UnsupportedPlaybackSessionBackend implements PlaybackSessionBackend {
  const UnsupportedPlaybackSessionBackend();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> start({
    required String title,
    String? subtitle,
    Duration duration = Duration.zero,
    double speed = 1.0,
  }) async {}

  @override
  Future<void> update({
    Duration? position,
    bool? playing,
    Duration? duration,
    double? speed,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PlaybackSessionCommand> get commands =>
      const Stream<PlaybackSessionCommand>.empty();
}

/// 方法通道 `lumebox/playback`：
/// - `isSupported` → `bool`
/// - `start` → `{title, subtitle, durationMs, speed}`
/// - `update` → `{positionMs, playing, durationMs, speed}`（缺项表示不变）
/// - `stop` → 无参
///
/// 事件通道 `lumebox/playback/events`：`{command: 'play'|'pause'|'toggle'|'next'|'previous'}`。
class MethodChannelPlaybackBackend implements PlaybackSessionBackend {
  MethodChannelPlaybackBackend({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ?? const MethodChannel(methodChannelName),
        _events = eventChannel ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'lumebox/playback';
  static const String eventChannelName = 'lumebox/playback/events';

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<bool> isSupported() async {
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
  }

  @override
  Future<void> start({
    required String title,
    String? subtitle,
    Duration duration = Duration.zero,
    double speed = 1.0,
  }) async {
    try {
      await _methods.invokeMethod<void>('start', <String, Object?>{
        'title': title,
        'subtitle': ?subtitle,
        'durationMs': duration.inMilliseconds,
        'speed': speed,
      });
    } on MissingPluginException {
      // 原生未接入：调用方已经按 isSupported 走过降级路径。
    } catch (error, stackTrace) {
      LumeLog.warn('[playback] 开始播放会话失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<void> update({
    Duration? position,
    bool? playing,
    Duration? duration,
    double? speed,
  }) async {
    try {
      await _methods.invokeMethod<void>('update', <String, Object?>{
        'positionMs': ?position?.inMilliseconds,
        'playing': ?playing,
        'durationMs': ?duration?.inMilliseconds,
        'speed': ?speed,
      });
    } on MissingPluginException {
      // 同上。
    } catch (error, stackTrace) {
      LumeLog.warn('[playback] 同步播放状态失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on MissingPluginException {
      // 同上。
    } catch (error, stackTrace) {
      LumeLog.warn('[playback] 结束播放会话失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Stream<PlaybackSessionCommand> get commands => _events
      .receiveBroadcastStream()
      .map(decodeEvent)
      .where((command) => command != null)
      .cast<PlaybackSessionCommand>();

  /// 事件载荷 → 指令；未知载荷返回 null（被过滤掉）。
  static PlaybackSessionCommand? decodeEvent(Object? payload) {
    if (payload is! Map) return null;
    return PlaybackSessionCommand.fromId('${payload['command'] ?? ''}');
  }
}

/// 按平台选择播放会话后端：iOS 走原生，其余平台如实降级。
PlaybackSessionBackend createPlatformPlaybackBackend() => Platform.isIOS
    ? MethodChannelPlaybackBackend()
    : const UnsupportedPlaybackSessionBackend();

/// 播放会话的门面：把「什么时候开始 / 更新 / 结束」收敛在一处。
///
/// 页面对它只说三件事：开始（起播时）、同步（状态变化时，自带节流）、结束
/// （退出 / 停止时）。它自己判断平台支不支持——不支持时全是空操作。
class PlaybackSession {
  PlaybackSession({PlaybackSessionBackend? backend})
      : _backend = backend ?? createPlatformPlaybackBackend();

  final PlaybackSessionBackend _backend;

  /// 当前是否已经开过一次会话（避免重复 start）。
  bool _active = false;

  /// 节流：进度更新不必每次都过通道（系统播放条不需要 0.5 秒级精度）。
  Duration _lastPosition = Duration.zero;
  static const Duration _positionInterval = Duration(seconds: 5);

  bool get isActive => _active;

  /// 开始（或重新开始）一次会话。
  Future<void> start({
    required String title,
    String? subtitle,
    Duration duration = Duration.zero,
    double speed = 1.0,
  }) async {
    if (!await _backend.isSupported()) return;
    _active = true;
    _lastPosition = Duration.zero;
    await _backend.start(
      title: title,
      subtitle: subtitle,
      duration: duration,
      speed: speed,
    );
  }

  /// 同步状态。进度按 [_positionInterval] 节流；播放 / 暂停与时长变化立即同步。
  Future<void> update({
    Duration? position,
    bool? playing,
    Duration? duration,
    double? speed,
  }) async {
    if (!_active) return;
    Duration? throttled = position;
    if (position != null) {
      final changed =
          (position - _lastPosition).abs() >= _positionInterval;
      if (!changed && playing == null && duration == null && speed == null) {
        return;
      }
      if (changed) {
        _lastPosition = position;
      } else {
        throttled = null;
      }
    }
    await _backend.update(
      position: throttled,
      playing: playing,
      duration: duration,
      speed: speed,
    );
  }

  /// 结束会话（页面退出 / 播放器释放）。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _backend.stop();
  }

  /// 系统控件事件流（不支持时是空流）。
  Stream<PlaybackSessionCommand> get commands => _backend.commands;

  @visibleForTesting
  PlaybackSessionBackend get backend => _backend;
}
