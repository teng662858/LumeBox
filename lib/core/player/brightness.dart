import 'dart:io';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';

/// 屏幕亮度后端：播放器手势调亮度时用。
///
/// 与画中画 / 语音同构：平台能力做成端口，原生未接入时如实降级为「不支持」，
/// 由调用方回退到页面内遮罩（见播放页的亮度遮罩）。
///
/// 为什么不做成必选能力：Android / Windows 也能改亮度，但接口完全不同
/// （Android 要 WindowManager.LayoutParams，Windows 要 SetDeviceGammaRamp），
/// 当前项目只做 iOS，其余平台如实降级比写三个半成品实现诚实。
abstract interface class BrightnessBackend {
  /// 平台是否支持改系统亮度。
  Future<bool> isSupported();

  /// 设置系统亮度（0.0~1.0）。越界值由实现方钳制。
  Future<void> setBrightness(double value);

  /// 读回当前系统亮度（0.0~1.0）；拿不到时返回 null。
  ///
  /// 进播放页时用它把滑块对齐到真实亮度：否则用户一滑就跳到别的值，
  /// 手感像「亮度被我改了」。
  Future<double?> currentBrightness();
}

/// 不支持改系统亮度的后端（非 iOS 与原生未接入）。
class UnsupportedBrightnessBackend implements BrightnessBackend {
  const UnsupportedBrightnessBackend();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> setBrightness(double value) async {}

  @override
  Future<double?> currentBrightness() async => null;
}

/// 方法通道 `lumebox/brightness`：
/// - `isSupported` → `bool`；
/// - `set` → 参数 `{value: double}`；
/// - `current` → `double?`。
///
/// 原生未接入时 `isSupported` 把 MissingPluginException 如实降级为 false。
class MethodChannelBrightnessBackend implements BrightnessBackend {
  MethodChannelBrightnessBackend({MethodChannel? methodChannel})
      : _methods = methodChannel ?? const MethodChannel(channelName);

  static const String channelName = 'lumebox/brightness';

  final MethodChannel _methods;

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
  Future<void> setBrightness(double value) async {
    try {
      await _methods.invokeMethod<void>('set', <String, Object?>{
        'value': value.clamp(0.0, 1.0),
      });
    } on MissingPluginException {
      // 原生未接入：调用方已经按 isSupported 走过降级路径，这里静默。
    } catch (error, stackTrace) {
      // 亮度失败不该影响播放：记一条日志就好。
      LumeLog.warn('[brightness] 设置亮度失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  @override
  Future<double?> currentBrightness() async {
    try {
      final value = await _methods.invokeMethod<double>('current');
      if (value == null) return null;
      return value.clamp(0.0, 1.0);
    } on MissingPluginException {
      return null;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return null;
    }
  }
}

/// 按平台选择亮度后端：iOS 走原生，其余平台如实降级。
BrightnessBackend createPlatformBrightnessBackend() => Platform.isIOS
    ? MethodChannelBrightnessBackend()
    : const UnsupportedBrightnessBackend();
