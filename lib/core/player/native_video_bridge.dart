import 'dart:async';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';

typedef NativeVideoRequest = Future<Map<String, Object?>> Function(
  String action,
  Map<String, Object?> arguments,
);

/// Only source/persistence messages cross this bridge. Native code exclusively
/// owns transport, rendering, controls, PiP and the audio session.
class NativeVideoBridge {
  NativeVideoBridge({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('lumebox/native_video') {
    this.channel.setMethodCallHandler(_receive);
  }
  static final shared = NativeVideoBridge();
  final MethodChannel channel;
  final _sessions = <String, NativeVideoConnection>{};
  int _sequence = 0;

  NativeVideoConnection connect({
    required NativeVideoRequest request,
    required void Function(Map<String, Object?>) event,
  }) {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    final connection = NativeVideoConnection._(this, id, request, event);
    _sessions[id] = connection;
    return connection;
  }

  Future<Object?> _receive(MethodCall call) async {
    final raw = call.arguments;
    if (raw is! Map) return null;
    final data = Map<String, Object?>.from(raw);
    final session = _sessions[data['session']];
    if (session == null || session._closed) return null;
    if (call.method == 'event') {
      session.event(data);
      if (data['type'] == 'closed') session._finish();
      return null;
    }
    if (call.method == 'request') {
      try {
        return await session.request(
          data['action'] as String? ?? '',
          Map<String, Object?>.from(data['arguments'] as Map? ?? const {}),
        );
      } catch (error) {
        return <String, Object?>{'error': '$error'};
      }
    }
    return null;
  }
}

class NativeVideoConnection {
  NativeVideoConnection._(this._bridge, this.id, this.request, this.event);
  final NativeVideoBridge _bridge;
  final String id;
  final NativeVideoRequest request;
  final void Function(Map<String, Object?>) event;
  final _finished = Completer<void>();
  bool _closed = false, _opened = false;
  Future<void> get finished => _finished.future;

  Future<void> open(
    Map<String, Object?> media,
    Map<String, Object?> options,
  ) async {
    if (_closed || _opened) throw StateError('播放会话已经打开或关闭');
    _opened = true;
    try {
      await _bridge.channel
          .invokeMethod<Object?>('open', {
            'session': id,
            'media': media,
            'options': options,
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // A late presentation must still receive its close command.
      unawaited(close());
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _finish();
    if (!_opened) return;
    try {
      await _bridge.channel
          .invokeMethod<void>('close', {'session': id})
          .timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      // The route may be disposed before native presentation was possible.
    } on PlatformException catch (error) {
      LumeLog.warn('[native-video] 关闭原生播放页失败：${error.code}');
    } on TimeoutException {
      // UIKit dismisses immediately; decoder teardown continues natively.
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _bridge._sessions.remove(id);
    if (!_finished.isCompleted) _finished.complete();
  }
}
