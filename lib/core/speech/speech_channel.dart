import 'dart:io';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';
import 'speech_session.dart';
import 'speech_settings.dart';

/// iOS 原生语音合成的通道契约（Dart 侧）。
///
/// 方法通道 `lumebox/speech`：
/// - `isSupported` → `bool`：原生是否具备语音合成能力；
/// - `speak` → 参数 `{text, rate, pitch, volume}`，朗读一段文本；
/// - `stop` / `pause` / `resume` → 队列控制。
///
/// 事件通道 `lumebox/speech/events`：
/// `{kind: started|finished|progress|paused|resumed|stopped|failed, charOffset?, message?}`
/// 与 [SpeechEventKind] 一一对应。
///
/// 原生实现（Swift，AVSpeechSynthesizer）尚未接入时：`isSupported` 把
/// MissingPluginException 如实降级为 false，面板显示占位而不是报错——
/// 契约由测试固定，原生落地即生效。
class MethodChannelSpeechBackend implements SpeechBackend {
  MethodChannelSpeechBackend({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    SpeechSettings settings = const SpeechSettings(),
  })  : _methods = methodChannel ?? const MethodChannel(methodChannelName),
        _events = eventChannel ?? const EventChannel(eventChannelName),
        // 公开参数名 `settings` 与私有字段 `_settings` 不同名，无法用初始化
        // 形参（Dart 不允许下划线开头的具名参数）。
        // ignore: prefer_initializing_formals
        _settings = settings;

  static const String methodChannelName = 'lumebox/speech';
  static const String eventChannelName = 'lumebox/speech/events';

  final MethodChannel _methods;
  final EventChannel _events;

  /// 朗读参数（语速 / 音调 / 音量）。页面改设置时用 [applySettings] 更新。
  SpeechSettings _settings;

  /// 更新朗读参数（下一段生效；正在读的那段不打断）。
  void applySettings(SpeechSettings settings) => _settings = settings;

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
  Future<void> speak(String text) async {
    try {
      await _methods.invokeMethod<void>('speak', <String, Object?>{
        'text': text,
        'rate': _settings.rate,
        'pitch': _settings.pitch,
        'volume': _settings.volume,
      });
    } on MissingPluginException {
      throw const SpeechException('原生语音合成未接入');
    } on PlatformException catch (error) {
      throw SpeechException(error.message ?? error.code);
    }
  }

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> resume() => _invoke('resume');

  Future<void> _invoke(String method) async {
    try {
      await _methods.invokeMethod<void>(method);
    } on MissingPluginException {
      throw const SpeechException('原生语音合成未接入');
    } on PlatformException catch (error) {
      throw SpeechException(error.message ?? error.code);
    }
  }

  @override
  Stream<SpeechEvent> get events => _events
      .receiveBroadcastStream()
      .map(decodeEvent)
      .where((event) => event != null)
      .cast<SpeechEvent>();

  /// 解码原生事件载荷；无法识别的载荷返回 null（由流过滤）。
  static SpeechEvent? decodeEvent(Object? payload) {
    if (payload is! Map) return null;
    final kind = SpeechEventKind.fromId('${payload['kind'] ?? ''}');
    if (kind == null) return null;
    final rawOffset = payload['charOffset'];
    final message = payload['message'];
    return SpeechEvent(
      kind,
      charOffset: rawOffset is num ? rawOffset.round() : null,
      message: message == null ? null : '$message',
    );
  }
}

/// 语音合成调用失败（带可读原因）。
class SpeechException implements Exception {
  const SpeechException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 按平台选择语音后端：iOS 走原生 AVSpeechSynthesizer，其余平台如实降级为
/// 不支持（Android / Windows 只保留 UI 骨架占位）。
SpeechBackend createPlatformSpeechBackend() =>
    Platform.isIOS ? MethodChannelSpeechBackend() : const UnsupportedSpeechBackend();
