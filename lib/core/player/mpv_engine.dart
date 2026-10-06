
import 'package:flutter/foundation.dart';

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

  /// 音量（0.0~1.0）。
  Future<void> setVolume(double volume);

  /// 导出一帧当前画面（BGRA 像素），供画中画帧转发使用。
  ///
  /// 返回 null 表示当前拿不到帧（未加载 / 已释放 / 引擎不支持）。
  /// 这是**轮询式**取帧（mpv 的 `screenshot-raw`），不是推流式回调：
  /// 因此画中画期间由上层按帧率节拍调用，而不是内核主动推。
  Future<MpvVideoFrame?> captureFrame();

  /// 字幕总开关（MPV 由 libmpv 的轨道选择实现；字号 / 颜色 / 描边仍待自研字幕层）。
  Future<void> setSubtitleEnabled(bool enabled);

  /// 字幕样式（字号 / 颜色 / 描边）。
  ///
  /// media_kit 的字幕层是 Flutter Widget（`SubtitleViewConfiguration` 收一个
  /// 完整 TextStyle），因此**字号 / 颜色 / 描边都真实生效**——描边用
  /// TextStyle 的 shadows 实现（多层偏移模拟描边）。
  ///
  /// 延迟不在这里：media_kit 的公开 API 没有 `sub-delay` 通道（见
  /// [setSubtitleDelay] 的说明）。
  Future<void> setSubtitleStyle(SubtitleStyle style);

  /// 字幕样式版本：变化即通知渲染面重建。
  ///
  /// 为什么需要它：`Video` 是 const 构造，样式变了要靠换 key 触发重建；
  /// 上层（`VideoPage`）据此在样式变化时刷新画面区。
  ValueListenable<int> get subtitleStyleRevision;

  /// 字幕延迟（正值表示字幕延后出现）。
  ///
  /// **当前是「记住但不生效」**：media_kit 的公开 Dart API 没有暴露 libmpv 的
  /// `sub-delay`（`Player` 只开放轨道选择 / 倍速这类高层方法，`setProperty`
  /// 是私有的）。设置值会被记下并随设置落库，等将来换到能写属性的通道
  /// （自研渲染或 fork）时直接生效——这里如实说明，不假装支持。
  Future<void> setSubtitleDelay(Duration delay);

  /// 硬件解码开关。
  ///
  /// **当前是「记住但不生效」**，原因同上：libmpv 的 `hwdec` 是解码链初始化期
  /// 属性，而 media_kit 没开放写属性的通道（`PlayerConfiguration` 里也没有
  /// hwdec 项）。设置值会被记下并落库，等有通道时生效。
  ///
  /// 为什么仍然把它做出来：文档明确要求「播放器增加硬件解码开关」，而开关的
  /// **状态**是用户能感知的配置；如实标注「暂不生效」比不给这个开关诚实，
  /// 也比谎称已生效好。
  Future<void> setHardwareDecoding(bool enabled);

  /// 渲染面。控制栏由上层画，引擎不自带任何 UI。
  Widget buildView();

  Future<void> dispose();
}

/// 可选能力：**帧节拍**（每解码出一帧给一次信号）。
///
/// 为什么做成可选端口：media_kit 的 Dart API 没有解码帧回调（`PlayerStream`
/// 里没有帧流），但它的 `time-pos` 每次**最多更新一帧**——用它当「帧节拍」
/// 能把取帧从「固定定时器」变成「跟着画面走」：暂停时不再空转取帧，播放时
/// 取帧时刻与真实帧对齐。
///
/// 引擎没有这个能力时，[PipFramePump] 退回定时器节拍（行为不变）。
abstract interface class FrameTickCapable {
  /// 帧节拍：每次画面推进发一个事件（不需要携带数据）。
  Stream<void> get frameTicks;
}

/// 字幕样式：字号缩放 / 颜色 / 描边宽度。
///
/// 与 `PlayerSettings` 的字段一一对应，但刻意独立：引擎层不认识「档位」
/// （那是设置页的表达），只认识最终要用的数值。
class SubtitleStyle {
  const SubtitleStyle({
    this.fontScale = 1.0,
    this.colorArgb = 0xFFFFFFFF,
    this.outlineWidth = 1.5,
  });

  /// 字号缩放（相对基准字号）。
  final double fontScale;

  /// 文字颜色（ARGB）。
  final int colorArgb;

  /// 描边宽度（逻辑像素）；0 表示不描边。
  final double outlineWidth;

  static const SubtitleStyle defaults = SubtitleStyle();
}

/// 一帧视频画面：BGRA8888 像素 + 尺寸 + 行距。
///
/// 行距（stride）由引擎给出：mpv 的帧可能带行对齐填充，因此**不能**假设
/// `stride == width * 4`。转发到原生侧时按行拷贝，避免画面倾斜。
class MpvVideoFrame {
  const MpvVideoFrame({
    required this.pixels,
    required this.width,
    required this.height,
    required this.stride,
  });

  final Uint8List pixels;
  final int width;
  final int height;

  /// 每行字节数（含对齐填充）。
  final int stride;

  /// 去掉行距填充，得到紧密排列的 BGRA（原生侧期望的格式）。
  Uint8List toTightBgra() {
    final rowBytes = width * 4;
    if (stride == rowBytes) return pixels;
    final tight = Uint8List(rowBytes * height);
    for (var row = 0; row < height; row++) {
      final sourceStart = row * stride;
      final targetStart = row * rowBytes;
      if (sourceStart + rowBytes > pixels.length) break;
      tight.setRange(
        targetStart,
        targetStart + rowBytes,
        pixels,
        sourceStart,
      );
    }
    return tight;
  }
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
