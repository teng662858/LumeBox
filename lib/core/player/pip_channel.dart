import 'dart:io';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';
import 'pip.dart';

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
/// 原生实现（Swift）尚未接入：此时 `isSupported` 会把 MissingPluginException
/// 如实降级为 false，页面显示占位而不是报错——契约由测试固定，原生落地即生效。
class MethodChannelPipBackend implements PipBackend {
  MethodChannelPipBackend({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ?? const MethodChannel(methodChannelName),
        _events = eventChannel ?? const EventChannel(eventChannelName);

  static const String methodChannelName = 'lumebox/pip';
  static const String eventChannelName = 'lumebox/pip/events';

  final MethodChannel _methods;
  final EventChannel _events;

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
  Future<void> start() => _methods.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

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
