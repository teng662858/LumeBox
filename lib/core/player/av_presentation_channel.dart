import 'dart:async';

import 'package:flutter/services.dart';

/// Addresses the same native player instance used by video_player and PiP.
class AvPresentationChannel {
  static const channel = MethodChannel('lumebox/av_presentation');
  static Future<T?> invoke<T>(
    int? playerId,
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (playerId == null) return null;
    try {
      return await channel
          .invokeMethod<T>(method, {'playerId': playerId, ...args})
          .timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
