import 'package:flutter/widgets.dart';

/// MPV 引擎端口（libmpv 的能力面）。
///
/// [MpvPlayer] 只依赖这个端口：命令映射、状态与 HUD 组装、生命周期全在 Dart 侧，
/// 原生库（media_kit / libmpv）挡在 `MediaKitMpvEngine` 后面。这样测试注入替身
/// 就能在没有 libmpv 的机器（含 CI）上验证整条链路，也保证上层与 libmpv 无关。
abstract interface class MpvEngine {
  /// 订阅引擎快照（位置 / 时长 / 播放 / 缓冲 / HUD 原始字段）。
  ///
  /// 注册时会立刻回调一次当前状态，调用方不必额外问一次。
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot);

  /// 打开媒体。
  Future<void> open(MpvMediaRequest request);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  /// 停止播放并回到起点（不卸载媒体，与 AVPlayer 内核的 stop 同口径）。
  Future<void> stop();

  Future<void> setSpeed(double speed);

  /// 字幕总开关（MPV 由 libmpv 的轨道选择实现；字号仍待自研字幕层）。
  Future<void> setSubtitleEnabled(bool enabled);

  /// 渲染面。控制栏由上层画，引擎不自带任何 UI。
  Widget buildView();

  Future<void> dispose();
}

/// 打开媒体的请求。
class MpvMediaRequest {
  const MpvMediaRequest({
    required this.url,
    this.headers,
    this.startAt,
    this.autoplay = false,
    this.speed = 1.0,
  });

  /// 媒体地址（http/https/file 都由 libmpv 自己取；网络访问仍受宿主网络层约束
  /// 之外的部分只影响脚本，播放器请求由播放内核直接发出）。
  final String url;

  /// 请求头（部分站点需要 Referer / UA）。
  final Map<String, String>? headers;

  /// 起播位置（切换内核后把位置接回来）。
  final Duration? startAt;

  /// 是否自动播放；默认 false，由上层显式调用 [MpvEngine.play]。
  final bool autoplay;

  /// 起播倍速。
  final double speed;
}

/// 引擎快照：libmpv 给出的原始事实。
///
/// 单位口径：码率统一 **kbps**（引擎内部把 mpv 的 bps 换算过来），
/// 这样 [MpvPlayer] 到 [PlayerStats] 之间不做单位猜谜。
class MpvEngineSnapshot {
  const MpvEngineSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered,
    this.playing = false,
    this.buffering = false,
    this.videoCodec,
    this.audioCodec,
    this.videoBitrateKbps,
    this.audioBitrateKbps,
    this.fps,
    this.width,
    this.height,
    this.error,
  });

  final Duration position;
  final Duration duration;

  /// 当前位置前方已缓冲的时长。
  final Duration? buffered;

  final bool playing;
  final bool buffering;

  final String? videoCodec;
  final String? audioCodec;
  final double? videoBitrateKbps;
  final double? audioBitrateKbps;
  final double? fps;
  final int? width;
  final int? height;

  /// 引擎级错误（打开失败、解码失败等）。
  final String? error;
}
