import 'dart:io';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';
import 'pip.dart';
import 'pip_frame_source.dart';

/// iOS 原生画中画的通道契约（Dart 侧）。
///
/// 方法通道 `lumebox/pip`：
/// - `isSupported` → `bool`：原生是否具备画中画能力（AVPlayerLayer 就绪）；
/// - `start` → 开启画中画（原生自行决定窗口内容）；
/// - `stop` → 关闭画中画。
///
/// 事件通道 `lumebox/pip/events`：`{kind: entered|exited|restored|failed, message?}`
/// 四种事件与 [PipEventKind] 一一对应。
///
/// AVPlayer 使用原生 playerLayer，MDK / MPV 使用解码帧内容源。
class MethodChannelPipBackend implements PipBackend {
  MethodChannelPipBackend({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    MethodChannel? frameChannel,
  }) : _methods = methodChannel ?? const MethodChannel(methodChannelName),
       _events = eventChannel ?? const EventChannel(eventChannelName),
       _frames = frameChannel ?? const MethodChannel(frameChannelName);

  static const String methodChannelName = 'lumebox/pip';
  static const String eventChannelName = 'lumebox/pip/events';

  /// 帧通道：Dart 帧源每送一帧走这里（BGRA 字节 → 原生 CMSampleBuffer）。
  static const String frameChannelName = 'lumebox/pip/frames';

  final MethodChannel _methods;
  final EventChannel _events;
  final MethodChannel _frames;

  @override
  Future<bool> isSupported() async {
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      // 原生侧未接入：如实降级，不把异常抛给页面。
      return false;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
  }

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  Future<void> prepareAvPlayer(int playerId) async {
    final ready = await const MethodChannel('lumebox/av_pip')
        .invokeMethod<bool>('prepare', {'playerId': playerId});
    if (ready != true) throw const PipException('系统播放器画中画内容源未就绪');
  }

  Future<void> updateDanmaku(
    Map<String, Object?> settings,
    List<Map<String, Object?>> items,
  ) async {
    try {
      await _frames.invokeMethod<void>('setDanmaku', {
        'settings': settings,
        'items': items,
      });
    } catch (error) {
      LumeLog.info('[pip] 弹幕配置同步失败：$error');
    }
  }

  Future<void> updatePlaybackState({
    required bool playing,
    required Duration duration,
    double playbackRate = 1,
  }) async {
    try {
      await _methods.invokeMethod<void>('updateState', {
        'playing': playing,
        'durationMs': duration.inMilliseconds.toDouble(),
        'playbackRate': playbackRate,
      });
    } catch (error) {
      LumeLog.info('[pip] 同步播放状态失败：$error');
    }
  }

  /// 调用原生并把 [PlatformException] 转成可读的 [PipException]。
  ///
  /// 原生会用 `code` / `message` 说明为什么开不了（系统版本、设备能力、内容源
  /// 未就绪），这些原因要原样带到界面——一句「画中画失败」帮不了用户。
  Future<void> _invoke(String method) async {
    try {
      await _methods.invokeMethod<void>(method);
    } on MissingPluginException {
      throw const PipException('原生画中画未接入');
    } on PlatformException catch (error) {
      throw PipException(error.message ?? error.code);
    }
  }

  /// 帧源：内核解码帧 → 本对象 → 原生帧泵。
  ///
  /// 通道建好即绑定（[PipFrameSource.attach]）；原生未接入时 `submitFrame`
  /// 会收到 `MissingPluginException`，帧源如实丢弃并计数，不影响播放。
  late final PipFrameSource frameSource = PipFrameSource()
    ..attach(_submitFrame);

  /// 把一帧送到原生（失败只记日志：画中画是增强功能，不该影响播放）。
  Future<void> _submitFrame(Map<String, Object?> frame) async {
    try {
      final accepted = await _frames.invokeMethod<bool>('submitFrame', frame);
      if (accepted != true) throw const PipException('原生画中画未接收视频帧');
    } on MissingPluginException {
      throw const PipException('原生画中画帧通道未接入');
    } catch (error, stackTrace) {
      LumeLog.warn('[pip] 帧提交失败: $error');
      LumeLog.error(error, stackTrace);
      rethrow;
    }
  }

  /// 释放原生帧泵（退出画中画 / 页面销毁）。
  Future<void> teardownFrames() async {
    frameSource.detach();
    await resetFrames();
  }

  /// Clear an obsolete media source while retaining the reusable Dart channel.
  Future<void> resetFrames() async {
    frameSource.resetStats();
    try {
      await _frames.invokeMethod<void>('teardown');
    } catch (_) {
      // 原生未接入：无需处理。
    }
  }

  @override
  Stream<PipEvent> get events => _events
      .receiveBroadcastStream()
      .map(decodeEvent)
      .where((event) => event != null)
      .cast<PipEvent>();

  /// 解码原生事件载荷；无法识别的载荷返回 null（由流过滤）。
  static PipEvent? decodeEvent(Object? payload) {
    if (payload is! Map) return null;
    final kind = PipEventKind.fromId('${payload['kind'] ?? ''}');
    if (kind == null) return null;
    final message = payload['message'];
    return PipEvent(kind, message: message == null ? null : '$message');
  }
}

/// 按平台选择画中画后端：iOS 走原生通道，其余平台如实降级为不支持
/// （Android / Windows 只保留 UI 骨架占位，不实现 PiP 业务逻辑）。
PipBackend createPlatformPipBackend() =>
    Platform.isIOS ? MethodChannelPipBackend() : const UnsupportedPipBackend();
