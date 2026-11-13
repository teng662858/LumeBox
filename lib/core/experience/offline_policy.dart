import 'package:flutter/services.dart';

import 'content_center.dart';
import '../media/playback_focus.dart';

class OfflinePolicy {
  static const channel = MethodChannel('lumebox/experience');
  static Future<String?> blocked({
    Future<Map<Object?, Object?>> Function()? inspect,
    bool? playing,
    bool needsNetwork = true,
  }) async {
    final settings = ContentCenter.instance;
    if (settings.enabled('pauseDuringPlayback') &&
        (playing ?? PlaybackFocus.isPlaying)) {
      return '播放时暂停下载';
    }
    final wifiRequired = needsNetwork && settings.enabled('wifiOnly');
    if (!wifiRequired && settings.number('reserveMB', 0) <= 0) {
      return null;
    }
    Map<Object?, Object?> facts;
    try {
      facts =
          await (inspect?.call() ??
              channel
                  .invokeMethod<Map<Object?, Object?>>('networkAndStorage')
                  .then((v) => v ?? {}));
    } catch (_) {
      return '无法确认网络或可用空间，请稍后重试或调整离线策略';
    }
    if (wifiRequired && facts['wifi'] != true) {
      return '等待 Wi-Fi 网络';
    }
    final reserve = settings.number('reserveMB', 0) * 1024 * 1024;
    if (reserve > 0 && ((facts['freeBytes'] as num?)?.toInt() ?? 0) < reserve) {
      return '可用空间不足，保留空间策略已暂停下载';
    }
    return null;
  }
}

class OfflinePolicyPaused implements Exception {
  const OfflinePolicyPaused(this.reason);
  final String reason;
  @override
  String toString() => reason;
}
