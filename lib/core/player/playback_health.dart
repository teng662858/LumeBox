import 'abstract_player.dart';
import 'player_stats.dart';

/// Conclusions remain tentative when a kernel cannot expose network/renderer data.
abstract final class PlaybackHealth {
  static String describe(
    PlayerSnapshot state,
    PlayerStats stats, {
    String? operation,
  }) {
    if (operation != null) return operation;
    if (state.error != null) return '播放失败，请尝试其他线路或内核';
    if (!state.playing && !state.buffering) return '已暂停';
    if (!state.buffering) return '播放正常';
    final reserve = stats.buffered;
    if (reserve == null) return '正在等待数据；当前内核未提供足够信息判断原因';
    if (reserve >= const Duration(seconds: 5)) {
      return '已有缓存仍在等待，可能是解码或渲染较慢，可尝试其他内核';
    }
    final speed = stats.downloadBytesPerSecond;
    final bitrate = stats.videoBitrateKbps;
    if (speed != null &&
        speed > 0 &&
        bitrate != null &&
        bitrate > 0 &&
        speed * 8 / 1000 < bitrate + (stats.audioBitrateKbps ?? 0)) {
      return '当前下载速度低于媒体码率，建议换线路或降低画质';
    }
    if (speed == 0) return '缓存不足且暂未收到数据，可能是线路响应慢或网络中断';
    return '缓存不足，正在等待线路数据';
  }
}

/// Uses observed progress rather than the engine's optimistic playing flag.
class PlaybackStallGuard {
  Duration? _position;
  DateTime? _since;
  String? _identity;
  bool observe(
    String identity,
    PlayerSnapshot state,
    DateTime now, {
    required bool eligible,
  }) {
    if (!eligible ||
        identity != _identity ||
        _position == null ||
        (state.position - _position!).abs() >
            const Duration(milliseconds: 200)) {
      _identity = identity;
      _position = state.position;
      _since = eligible ? now : null;
      return false;
    }
    _since ??= now;
    if (now.difference(_since!) < const Duration(seconds: 15)) return false;
    _since = now;
    return true;
  }
}
