
import 'package:flutter/foundation.dart';

import 'package:flutter/widgets.dart';

import 'buffering.dart';
import 'player_capabilities.dart';

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
  /// 走 libmpv 的 `sub-delay` 属性（秒）：media_kit 的公开 Dart API 没有暴露它，
  /// 但 `NativePlayer` 把 FFI 绑定与 mpv 句柄做成了公开字段，因此
  /// [MediaKitMpvEngine] 能直接写属性（见 [EnginePropertyCapable]）。
  Future<void> setSubtitleDelay(Duration delay);

  /// 起播缓冲参数（文档 B 项）。
  ///
  /// 引擎侧写自己能写的那几项（libmpv 的 `cache` / `cache-pause-initial` /
  /// `demuxer-*`）；没有属性通道的实现如实忽略——上层不必知道哪个引擎支持哪几项。
  Future<void> setBuffering(BufferingConfig config);

  /// 硬件解码开关。
  ///
  /// 走 libmpv 的 `hwdec` 属性（`auto` / `no`）。它是**解码链初始化期**属性：
  /// 本次写入对随后打开的媒体生效，正在播的这一集要等切集后才换解码链。
  /// 写不进去（引擎没有属性通道）时如实记日志，不假装生效。
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

/// 可选能力：**引擎属性写通道**（libmpv 的 `mpv_set_property_string`）。
///
/// 为什么需要它：libmpv 里一大批能力（缓冲策略 `cache` / `demuxer-*`、硬解
/// `hwdec`、字幕延迟 `sub-delay`、音频延迟 `audio-delay`）**只有属性通道**，
/// media_kit 的高层 API 不开放（`Player` 只给轨道选择 / 倍速这类高层方法）。
///
/// 做成可选端口而不是 [MpvEngine] 的必选方法：上层只做一次能力探测
/// （`engine is EnginePropertyCapable`），没有这条通道的引擎按「不支持」如实处理，
/// 不必在每个调用点写分支。
abstract interface class EnginePropertyCapable {
  /// 写一个引擎属性。成功返回 true；通道不可用 / 属性名不被内核接受返回 false
  /// （调用方据此如实提示「本内核不支持」，而不是假装生效）。
  Future<bool> setEngineProperty(String name, String value);
}

/// 批量写属性，返回**被内核接受**的属性个数。
///
/// 单独提成函数是为了让「写不进去不算成功」这条口径可单测：调用方拿到 0 就知道
/// 这次一条都没落地（属性名写错 / 当前状态不可写时 libmpv 会回负值）。
Future<int> writeEngineProperties(
  EnginePropertyCapable engine,
  Map<String, String> properties,
) async {
  var accepted = 0;
  for (final entry in properties.entries) {
    if (await engine.setEngineProperty(entry.key, entry.value)) accepted++;
  }
  return accepted;
}

/// 可选能力：**轨道读写**（音轨 / 字幕轨 / 外挂字幕 / 音频延迟）。
///
/// 为什么是可选端口：这三件事都靠引擎的高层 API（media_kit 的
/// `setAudioTrack` / `setSubtitleTrack` / `SubtitleTrack.uri`），而替身引擎不一定
/// 实现。真实引擎（[MediaKitMpvEngine]）实现了它，因此 MPV 内核的能力矩阵里
/// 这几项为真；替身没有就为假——能力如实来自「引擎到底会不会做这件事」，
/// 不是写死的一张表。
abstract interface class TrackCapable {
  /// 可选音轨（当前选中的那条 `selected: true`）。
  Future<List<PlayerTrack>> audioTracks();

  /// 可选字幕轨（含外挂字幕）。
  Future<List<PlayerTrack>> subtitleTracks();

  /// 切音轨（[PlayerTrack.id] 原样回传）。
  Future<void> selectAudioTrack(String id);

  /// 切字幕轨；`null` = 关闭字幕。
  Future<void> selectSubtitleTrack(String? id);

  /// 加载外挂字幕文件（本地路径）。引擎没有这条通路时返回 false。
  Future<bool> loadSubtitleFile(String path);

  /// 音频延迟（正值表示音频延后）。
  Future<void> setAudioDelay(Duration delay);
}

/// MPV 属性映射：本项目写进 libmpv 的属性名与单位**在这里定死**。
///
/// 为什么要把这张表单独拿出来：真机才知道 libmpv 收不收某个属性，但「我们打算写
/// 什么名字、用什么单位」是本项目自己的一面之词——它必须能被单测钉住，否则一次
/// 手误（比如把 `sub-delay` 的秒写成毫秒）只会在真机上表现为「设置没反应」。
class MpvProperties {
  MpvProperties._();

  /// 起播缓冲参数（见 [BufferingConfig]，映射表在 `BufferingConfig.mpvProperties`）。
  static Map<String, String> buffering(BufferingConfig config) =>
      config.mpvProperties;

  /// 硬件解码开关：`auto` = 自动选硬解，`no` = 强制软解。
  static Map<String, String> hardwareDecoding(bool enabled) =>
      <String, String>{'hwdec': enabled ? 'auto' : 'no'};

  /// 字幕延迟：libmpv 的 `sub-delay` **单位是秒**（可负 = 字幕提前）。
  static Map<String, String> subtitleDelay(Duration delay) => <String, String>{
        'sub-delay': _seconds(delay),
      };

  /// 音频延迟：libmpv 的 `audio-delay` 单位同样是秒。
  static Map<String, String> audioDelay(Duration delay) => <String, String>{
        'audio-delay': _seconds(delay),
      };

  static String _seconds(Duration value) =>
      '${value.inMicroseconds / Duration.microsecondsPerSecond}';
}

/// 字幕样式：字号缩放 / 颜色 / 描边宽度 / 底色不透明度。
///
/// 与 `PlayerSettings` 的字段一一对应，但刻意独立：引擎层不认识「档位」
/// （那是设置页的表达），只认识最终要用的数值。
class SubtitleStyle {
  const SubtitleStyle({
    this.fontScale = 1.0,
    this.colorArgb = 0xFFFFFFFF,
    this.outlineWidth = 1.5,
    this.backgroundOpacity = 0.45,
    this.fontFamily = '',
    this.shadowStrength = 0.0,
    this.offsetY = 0.0,
  });

  /// 字号缩放（相对基准字号）。
  final double fontScale;

  /// 文字颜色（ARGB）。
  final int colorArgb;

  /// 描边宽度（逻辑像素）；0 表示不描边。
  final double outlineWidth;

  /// 字幕底色不透明度（0..1）：0 = 完全透明，1 = 纯黑。
  ///
  /// 底色的作用是「压在花画面上也能读」：纯透明在亮画面上白字会糊，
  /// 纯黑又太挡镜头，因此留给用户一档可调。
  final double backgroundOpacity;

  /// 字幕字体（系统字体族名）；空串 = 跟随系统默认。
  ///
  /// 说明：**思源黑体没有随包内置**（iOS / Android 都取不到这份字体文件），
  /// 因此选项只给系统字体（苹方 / 黑体 / 宋体 / 楷体…）；选一个设备上没有的
  /// 字体会被系统回落到默认字体，这是字体渲染的既有规则，不做伪装。
  final String fontFamily;

  /// 阴影强度（0..1）：0 = 不投阴影，越大越重。
  ///
  /// 与「描边」是两回事：描边是四向硬阴影（保证亮画面下也能读），阴影是往
  /// 单一方向的柔和投影（观感更自然）。两者叠加就是「描边 + 投影」。
  final double shadowStrength;

  /// 垂直偏移（-1..1）：负值上移、正值下移（0 = 保持默认位置）。
  ///
  /// 实现是改字幕层的底部内边距（见 media_kit_mpv_engine 的
  /// `SubtitleViewConfiguration.padding`）：正值把字幕推离底边（视觉上移），
  /// 负值贴近底边（视觉下移）。
  final double offsetY;

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
