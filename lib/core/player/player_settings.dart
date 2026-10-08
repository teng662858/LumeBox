/// 播放器设置模型（纯 Dart，不认识平台、存储与 UI）。
///
/// 三套内核与宪法一致：AVPlayer / MPV / MDK；设置项覆盖内核选择、倍速、字幕
/// （开关 / 字号 / 颜色 / 描边 / 背景透明度 / 延迟）、音频延迟、画面（缩放 /
/// 旋转 / 镜像）与硬件解码开关。持久化由所在板块负责——播放器设置落在「视频」
/// 板块自己的库里（见 `lib/features/video/video_player_settings.dart`），
/// 模型本身不带板块字段，也不认识 sqlite。
///
/// **按内核分别记住**（用户点名的约束）：倍速、画面（缩放 / 旋转 / 镜像）与字幕
/// 设置存在 [KernelPrefs] 里，按内核各存一份——切到 MPV 调好的字幕样式，切回
/// AVPlayer 时不会跟着漂过去。全局仍共享的是「选哪个内核」「字幕总开关」
/// 「硬件解码」这三项：它们的内核语义本来就不同，共享会误导。
library;

import 'package:flutter/foundation.dart';

/// 播放内核。只保留宪法允许的三套。
enum PlayerKernel {
  avplayer('avplayer', 'AVPlayer'),
  mpv('mpv', 'MPV'),
  mdk('mdk', 'MDK');

  const PlayerKernel(this.id, this.label);

  /// 稳定标识：落库与日志用。
  final String id;

  /// 显示名。
  final String label;

  /// 读取落库值；无法识别时回退 AVPlayer（默认内核）。
  static PlayerKernel fromId(String? id) {
    for (final kernel in values) {
      if (kernel.id == id) return kernel;
    }
    return PlayerKernel.avplayer;
  }
}

/// 字幕字号档位。
enum SubtitleSize {
  small('small', '小', 0.85),
  standard('standard', '标准', 1.0),
  large('large', '大', 1.25),
  huge('huge', '特大', 1.5);

  const SubtitleSize(this.id, this.label, this.scale);

  /// 稳定标识：落库与日志用。
  final String id;

  /// 显示名。
  final String label;

  /// 相对基准字号的缩放：字幕层按它取字号。
  final double scale;

  /// 读取落库值；无法识别时回退「标准」。
  static SubtitleSize fromId(String? id) {
    for (final size in values) {
      if (size.id == id) return size;
    }
    return SubtitleSize.standard;
  }
}

/// 字幕颜色。
///
/// 只给几个常用档位而不是任意取色器：字幕压在画面上，颜色太少不够用、
/// 完全自由又容易选出看不清的（亮画面上的亮字幕）。这几档都保证了对比度。
enum SubtitleColor {
  white('white', '白色', 0xFFFFFFFF),
  yellow('yellow', '黄色', 0xFFFFE066),
  green('green', '绿色', 0xFF7FE38A),
  cyan('cyan', '青色', 0xFF7FD8F0);

  const SubtitleColor(this.id, this.label, this.argb);

  final String id;
  final String label;

  /// ARGB 值（落库为十进制整数）。
  final int argb;

  static SubtitleColor fromId(String? id) {
    for (final color in values) {
      if (color.id == id) return color;
    }
    return SubtitleColor.white;
  }
}

/// 字幕描边强度。
///
/// 描边的作用是「压在亮画面上也能读」：无描边的白字幕遇到白背景会消失。
enum SubtitleOutline {
  none('none', '无', 0),
  thin('thin', '细', 1.5),
  thick('thick', '粗', 3.0);

  const SubtitleOutline(this.id, this.label, this.width);

  final String id;
  final String label;

  /// 描边宽度（逻辑像素）。
  final double width;

  static SubtitleOutline fromId(String? id) {
    for (final outline in values) {
      if (outline.id == id) return outline;
    }
    return SubtitleOutline.thin;
  }
}

/// 画面缩放模式（文档要求：0.75x / 1.0 / 1.25x / 1.5x / 填充 / 适应）。
///
/// 「适应」与「填充」是两种**取景方式**（留黑边 vs 裁满框），其余四档是在
/// 「适应」基础上的倍率——两组语义放在同一个菜单里，因为用户就是这么用的：
/// 先在「适应 / 填充」里挑一个取景，再用倍率微调。
enum ZoomMode {
  fit('fit', '适应', 1.0, false),
  fill('fill', '填充', 1.0, true),
  scale75('0.75', '0.75x', 0.75, false),
  scale100('1.0', '1.0x', 1.0, false),
  scale125('1.25', '1.25x', 1.25, false),
  scale150('1.5', '1.5x', 1.5, false);

  const ZoomMode(this.id, this.label, this.scale, this.covers);

  final String id;
  final String label;

  /// 在取景尺寸之上的倍率。
  final double scale;

  /// 是否「裁满整框」（填充）：true 时按 cover 取景，false 时按 contain 取景。
  final bool covers;

  static ZoomMode fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return ZoomMode.fit;
  }
}

/// 画面旋转档位（文档要求 90 / 180 / 270）。
///
/// 用枚举而不是任意角度：视频旋转只有这四个方向有实际意义（任意角度在播放器里
/// 是「画面歪着」，没人这么看片）；枚举也让它能被落库后原样还原。
enum RotationMode {
  none('0', '不旋转', 0),
  cw90('90', '顺时针 90°', 90),
  cw180('180', '180°', 180),
  cw270('270', '顺时针 270°', 270);

  const RotationMode(this.id, this.label, this.degrees);

  final String id;
  final String label;

  /// 顺时针角度。
  final int degrees;

  /// 旋转 90 / 270 时画面宽高互换（取景要跟着换，否则会留下大片黑边）。
  bool get swapsAxes => degrees == 90 || degrees == 270;

  static RotationMode fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return RotationMode.none;
  }

  /// 从角度反查档位（未知角度回落「不旋转」）。
  static RotationMode fromDegrees(int? degrees) =>
      fromId(degrees?.toString());
}

/// 一套内核的播放偏好：**按内核分别记住**的那几项（用户点名）。
///
/// 为什么按内核分开：这三组值都直接依赖内核实现——同一条字幕在 MPV 的字幕层
/// 与 MDK 的内嵌渲染下需要不同的偏移与字号，「切内核把设置带过去」只会让用户
/// 每切一次都要重调一遍。
@immutable
class KernelPrefs {
  const KernelPrefs({
    this.speed = PlayerSettings.defaultSpeed,
    this.zoom = ZoomMode.fit,
    this.rotation = RotationMode.none,
    this.mirrored = false,
    this.subtitleSize = SubtitleSize.standard,
    this.subtitleColor = SubtitleColor.white,
    this.subtitleOutline = SubtitleOutline.thin,
    this.subtitleBackground = defaultSubtitleBackground,
    this.subtitleDelay = Duration.zero,
    this.audioDelay = Duration.zero,
  });

  /// 字幕底色默认值：半透明黑——纯透明在亮画面下读不清，纯黑太挡画面。
  static const double defaultSubtitleBackground = 0.45;

  /// 字幕底色可调范围（0 = 完全透明，1 = 纯黑）。
  static const double minSubtitleBackground = 0.0;
  static const double maxSubtitleBackground = 1.0;

  /// 倍速，取值必然落在 [PlayerSettings.speeds] 内。
  final double speed;

  /// 画面缩放模式。
  final ZoomMode zoom;

  /// 画面旋转。
  final RotationMode rotation;

  /// 是否水平镜像。
  final bool mirrored;

  /// 字幕字号档位。
  final SubtitleSize subtitleSize;

  /// 字幕颜色。
  final SubtitleColor subtitleColor;

  /// 字幕描边强度。
  final SubtitleOutline subtitleOutline;

  /// 字幕底色不透明度（0..1）。
  final double subtitleBackground;

  /// 字幕延迟：正值表示字幕**延后**出现，负值表示提前。
  final Duration subtitleDelay;

  /// 音频延迟：正值表示音频**延后**出现（音画不同步时用）。
  final Duration audioDelay;

  KernelPrefs copyWith({
    double? speed,
    ZoomMode? zoom,
    RotationMode? rotation,
    bool? mirrored,
    SubtitleSize? subtitleSize,
    SubtitleColor? subtitleColor,
    SubtitleOutline? subtitleOutline,
    double? subtitleBackground,
    Duration? subtitleDelay,
    Duration? audioDelay,
  }) {
    return KernelPrefs(
      speed: speed == null ? this.speed : PlayerSettings.normalizeSpeed(speed),
      zoom: zoom ?? this.zoom,
      rotation: rotation ?? this.rotation,
      mirrored: mirrored ?? this.mirrored,
      subtitleSize: subtitleSize ?? this.subtitleSize,
      subtitleColor: subtitleColor ?? this.subtitleColor,
      subtitleOutline: subtitleOutline ?? this.subtitleOutline,
      subtitleBackground: subtitleBackground == null
          ? this.subtitleBackground
          : normalizeSubtitleBackground(subtitleBackground),
      subtitleDelay: subtitleDelay == null
          ? this.subtitleDelay
          : PlayerSettings.normalizeSubtitleDelay(subtitleDelay),
      audioDelay: audioDelay == null
          ? this.audioDelay
          : PlayerSettings.normalizeSubtitleDelay(audioDelay),
    );
  }

  /// 底色不透明度归一：夹到 0..1 并归到 0.05 的整数倍（滑杆给的就是这个精度）。
  static double normalizeSubtitleBackground(double? value) {
    if (value == null || value.isNaN) return defaultSubtitleBackground;
    final clamped = value.clamp(minSubtitleBackground, maxSubtitleBackground);
    return (clamped * 20).round() / 20;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'speed': speed,
        'zoom': zoom.id,
        'rotation': rotation.id,
        'mirrored': mirrored,
        'subtitleSize': subtitleSize.id,
        'subtitleColor': subtitleColor.id,
        'subtitleOutline': subtitleOutline.id,
        'subtitleBackground': subtitleBackground,
        'subtitleDelayMs': subtitleDelay.inMilliseconds,
        'audioDelayMs': audioDelay.inMilliseconds,
      };

  /// 从落库的 JSON 还原；任何一项坏掉都只影响那一项（回落默认值），
  /// 不让「库被改坏」变成「播放设置整块丢失」。
  static KernelPrefs fromJson(Object? json) {
    if (json is! Map) return const KernelPrefs();
    double? number(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
    // 字符串项也要宽容：库里可能是数字（历史版本 / 手改），直接 `as String?`
    // 会整份偏好都读不出来——「坏值只影响那一项」这条纪律在这里落地。
    String? text(Object? value) {
      if (value == null) return null;
      final parsed = '$value'.trim();
      return parsed.isEmpty ? null : parsed;
    }

    return KernelPrefs(
      speed: number(json['speed']) ?? PlayerSettings.defaultSpeed,
      zoom: ZoomMode.fromId(text(json['zoom'])),
      rotation: RotationMode.fromId(text(json['rotation'])),
      mirrored: json['mirrored'] == true,
      subtitleSize: SubtitleSize.fromId(text(json['subtitleSize'])),
      subtitleColor: SubtitleColor.fromId(text(json['subtitleColor'])),
      subtitleOutline: SubtitleOutline.fromId(text(json['subtitleOutline'])),
      subtitleBackground: normalizeSubtitleBackground(
        number(json['subtitleBackground']),
      ),
      subtitleDelay: PlayerSettings.normalizeSubtitleDelay(
        Duration(milliseconds: (number(json['subtitleDelayMs']) ?? 0).round()),
      ),
      audioDelay: PlayerSettings.normalizeSubtitleDelay(
        Duration(milliseconds: (number(json['audioDelayMs']) ?? 0).round()),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KernelPrefs &&
      other.speed == speed &&
      other.zoom == zoom &&
      other.rotation == rotation &&
      other.mirrored == mirrored &&
      other.subtitleSize == subtitleSize &&
      other.subtitleColor == subtitleColor &&
      other.subtitleOutline == subtitleOutline &&
      other.subtitleBackground == subtitleBackground &&
      other.subtitleDelay == subtitleDelay &&
      other.audioDelay == audioDelay;

  @override
  int get hashCode => Object.hash(
        speed,
        zoom,
        rotation,
        mirrored,
        subtitleSize,
        subtitleColor,
        subtitleOutline,
        subtitleBackground,
        subtitleDelay,
        audioDelay,
      );
}

/// 播放器设置：内核 + 全局开关 + **每个内核各一份**的偏好。
class PlayerSettings {
  const PlayerSettings({
    this.kernel = PlayerKernel.avplayer,
    this.subtitlesEnabled = true,
    this.hardwareDecoding = true,
    this.autoHideControls = true,
    this.gestureSensitivity = defaultGestureSensitivity,
    this.prefs = const <PlayerKernel, KernelPrefs>{},
  });

  /// 手势灵敏度默认值（1.0 = 一屏高度对应 100% 变化）。
  static const double defaultGestureSensitivity = 1.0;

  /// 手势灵敏度可调范围（用户口径：在播放器设置里可自定义）。
  static const double minGestureSensitivity = 0.5;
  static const double maxGestureSensitivity = 2.0;

  /// 便捷构造：给某个内核一份偏好（测试与非 const 场景用）。
  ///
  /// 日常读写的参数名在 [copyWith] 里，写法是
  /// `PlayerSettings().copyWith(kernel: ..., speed: 1.5)`。
  factory PlayerSettings.forKernel(
    PlayerKernel kernel, {
    KernelPrefs? prefs,
    bool subtitlesEnabled = true,
    bool hardwareDecoding = true,
  }) {
    return PlayerSettings(
      kernel: kernel,
      subtitlesEnabled: subtitlesEnabled,
      hardwareDecoding: hardwareDecoding,
      prefs: prefs == null
          ? const <PlayerKernel, KernelPrefs>{}
          : <PlayerKernel, KernelPrefs>{kernel: prefs},
    );
  }

  /// 可选倍速档位：文档要求 0.25~4.0、步长 0.25。
  static const List<double> speeds = <double>[
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
    2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0,
  ];

  static const double defaultSpeed = 1.0;

  /// 倍速下限 / 上限（滑杆与归一都用它们，避免两处各写一遍）。
  static const double minSpeed = 0.25;
  static const double maxSpeed = 4.0;

  /// 字幕延迟 / 音频延迟的可调范围（文档要求「字幕延迟」与「音频延迟」）。
  ///
  /// ±10 秒足够覆盖常见的「字幕比画面早/晚一点」与音画不同步；再大就不是延迟
  /// 问题，而是拿错了字幕文件 / 源本身有问题。
  static const Duration minSubtitleDelay = Duration(seconds: -10);
  static const Duration maxSubtitleDelay = Duration(seconds: 10);

  /// 播放内核。
  final PlayerKernel kernel;

  /// 字幕总开关。
  final bool subtitlesEnabled;

  /// 硬件解码开关（文档「部分设备硬解 HEVC 失败时可以切软解」）。
  ///
  /// 默认开启（硬解是常态，省电且流畅）；关掉即走软解——当某台设备硬解
  /// HEVC 花屏 / 黑屏时，用户有一个不用换播放器的出口。
  final bool hardwareDecoding;

  /// 全屏控制栏自动隐藏（用户要求；默认开）。
  ///
  /// 播放中 N 秒无操作就把进度条与按钮收起来，点屏幕再唤回；关掉则一直显示。
  /// 与内核无关（三套内核共用一份），因此放在全局项里而不是 KernelPrefs。
  final bool autoHideControls;

  /// 手势灵敏度倍率（亮度 / 音量垂直滑动用）：
  /// 1.0 = 现在的口径（一屏高度 = 100% 变化），调大更灵敏、调小更稳。
  final double gestureSensitivity;

  /// 按内核分别记住的偏好（键是内核，没记录过的内核用默认值）。
  final Map<PlayerKernel, KernelPrefs> prefs;

  /// 当前内核的偏好（没记录过就是默认值）。
  KernelPrefs get current => prefs[kernel] ?? const KernelPrefs();

  // ---- 下面这些读法与「当前内核」绑定：切内核后读到的就是那个内核自己的值 ----

  /// 播放倍速。
  double get speed => current.speed;

  /// 画面缩放模式。
  ZoomMode get zoom => current.zoom;

  /// 画面旋转。
  RotationMode get rotation => current.rotation;

  /// 是否水平镜像。
  bool get mirrored => current.mirrored;

  /// 字幕字号档位。
  SubtitleSize get subtitleSize => current.subtitleSize;

  /// 字幕颜色。
  SubtitleColor get subtitleColor => current.subtitleColor;

  /// 字幕描边强度。
  SubtitleOutline get subtitleOutline => current.subtitleOutline;

  /// 字幕底色不透明度（0..1）。
  double get subtitleBackground => current.subtitleBackground;

  /// 字幕延迟：正值表示字幕**延后**出现，负值表示提前。
  Duration get subtitleDelay => current.subtitleDelay;

  /// 音频延迟：正值表示音频**延后**出现。
  Duration get audioDelay => current.audioDelay;

  /// 改设置：**[kernel] 指到哪个内核，这几项偏好就写进哪个内核的那一格**。
  ///
  /// 因此 `copyWith(kernel: PlayerKernel.mpv)` 之后 `speed` 读到的就是 MPV 自己
  /// 记住的倍速——「按内核分别记住」这条约束是在这里落地，而不是在页面上。
  PlayerSettings copyWith({
    PlayerKernel? kernel,
    double? speed,
    bool? subtitlesEnabled,
    bool? autoHideControls,
    double? gestureSensitivity,
    SubtitleSize? subtitleSize,
    SubtitleColor? subtitleColor,
    SubtitleOutline? subtitleOutline,
    double? subtitleBackground,
    Duration? subtitleDelay,
    Duration? audioDelay,
    ZoomMode? zoom,
    RotationMode? rotation,
    bool? mirrored,
    bool? hardwareDecoding,
    Map<PlayerKernel, KernelPrefs>? prefs,
  }) {
    final target = kernel ?? this.kernel;
    final source = prefs ?? this.prefs;
    // 没有一项偏好被改到时不落格：`copyWith()` 必须是**幂等**的
    // （否则空改一次就会给当前内核凭空造出一格默认值，等值判断随之失效）。
    final prefChanged = speed != null ||
        zoom != null ||
        rotation != null ||
        mirrored != null ||
        subtitleSize != null ||
        subtitleColor != null ||
        subtitleOutline != null ||
        subtitleBackground != null ||
        subtitleDelay != null ||
        audioDelay != null;
    final nextPrefs = prefChanged
        ? <PlayerKernel, KernelPrefs>{
            ...source,
            target: (source[target] ?? const KernelPrefs()).copyWith(
              speed: speed,
              zoom: zoom,
              rotation: rotation,
              mirrored: mirrored,
              subtitleSize: subtitleSize,
              subtitleColor: subtitleColor,
              subtitleOutline: subtitleOutline,
              subtitleBackground: subtitleBackground,
              subtitleDelay: subtitleDelay,
              audioDelay: audioDelay,
            ),
          }
        : source;
    return PlayerSettings(
      kernel: target,
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
      autoHideControls: autoHideControls ?? this.autoHideControls,
      gestureSensitivity: gestureSensitivity == null
          ? this.gestureSensitivity
          : gestureSensitivity
              .clamp(minGestureSensitivity, maxGestureSensitivity)
              .toDouble(),
      prefs: nextPrefs,
    );
  }

  /// 倍速归一：非档位值（含 NaN）夹到最近档位，库被改坏时也不会拿到奇怪倍速。
  ///
  /// 档位从 0.25 到 4.0 步长 0.25（文档要求），因此 1.3 会落到 1.25。
  static double normalizeSpeed(double? value) {
    if (value == null || value.isNaN) return defaultSpeed;
    var best = speeds.first;
    for (final speed in speeds) {
      if ((speed - value).abs() < (best - value).abs()) best = speed;
    }
    return best;
  }

  /// 延迟归一：夹到 ±10 秒，并归到 0.1 秒。
  ///
  /// 归一而不是拒绝：库被改坏（或旧版本写了越界值）时，最坏情况是延迟不准，
  /// 不该让播放起不来。
  static Duration normalizeSubtitleDelay(Duration? value) {
    if (value == null) return Duration.zero;
    var micros = value.inMicroseconds;
    const minMicros = -10 * 1000 * 1000;
    const maxMicros = 10 * 1000 * 1000;
    if (micros < minMicros) micros = minMicros;
    if (micros > maxMicros) micros = maxMicros;
    // 归到 0.1 秒：滑杆给的就是这个精度，避免落库一堆无意义的尾数。
    const step = 100 * 1000;
    final rounded = (micros / step).round() * step;
    return Duration(microseconds: rounded);
  }

  @override
  bool operator ==(Object other) {
    if (other is! PlayerSettings) return false;
    if (other.kernel != kernel ||
        other.subtitlesEnabled != subtitlesEnabled ||
        other.hardwareDecoding != hardwareDecoding ||
        other.autoHideControls != autoHideControls ||
        other.gestureSensitivity != gestureSensitivity) {
      return false;
    }
    // 逐格比较：Map 的 == 是引用比较，必须按内容比。
    final a = prefs;
    final b = other.prefs;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        kernel,
        subtitlesEnabled,
        hardwareDecoding,
        autoHideControls,
        Object.hashAllUnordered(
          prefs.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      );
}
