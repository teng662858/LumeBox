/// 播放器设置模型（纯 Dart，不认识平台、存储与 UI）。
///
/// 三套内核与宪法一致：AVPlayer / MPV / MDK；设置项覆盖内核选择、倍速、字幕
/// （开关 / 字号 / 颜色 / 描边 / 延迟）与硬件解码开关。持久化由所在板块负责
/// ——播放器设置落在「自定义视频」板块自己的库里
/// （见 `lib/features/video/video_player_settings.dart`），模型本身不带
/// 板块字段，也不认识 sqlite。
library;

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

  /// 相对基准字号的缩放：字幕层按它取字号（自研字幕层落地后生效）。
  final double scale;

  /// 读取落库值；无法识别时回退「标准」。
  static SubtitleSize fromId(String? id) {
    for (final size in values) {
      if (size.id == id) return size;
    }
    return SubtitleSize.standard;
  }
}

/// 字幕颜色（文档「字幕字号/颜色/描边」）。
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

/// 字幕描边强度（文档「字幕字号/颜色/描边」）。
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

/// 播放器设置：内核、倍速、字幕、硬件解码。
class PlayerSettings {
  const PlayerSettings({
    this.kernel = PlayerKernel.avplayer,
    this.speed = defaultSpeed,
    this.subtitlesEnabled = true,
    this.subtitleSize = SubtitleSize.standard,
    this.subtitleColor = SubtitleColor.white,
    this.subtitleOutline = SubtitleOutline.thin,
    this.subtitleDelay = Duration.zero,
    this.hardwareDecoding = true,
  });

  /// 可选倍速档位（设置页按此渲染）。
  static const List<double> speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  static const double defaultSpeed = 1.0;

  /// 字幕延迟的可调范围（文档要求「字幕延迟调节」）。
  ///
  /// ±10 秒足够覆盖常见的「字幕比画面早/晚一点」；再大就不是延迟问题，
  /// 而是拿错了字幕文件。
  static const Duration minSubtitleDelay = Duration(seconds: -10);
  static const Duration maxSubtitleDelay = Duration(seconds: 10);

  /// 播放内核。
  final PlayerKernel kernel;

  /// 播放倍速，取值必然落在 [speeds] 内。
  final double speed;

  /// 字幕总开关。
  final bool subtitlesEnabled;

  /// 字幕字号档位。
  final SubtitleSize subtitleSize;

  /// 字幕颜色。
  final SubtitleColor subtitleColor;

  /// 字幕描边强度。
  final SubtitleOutline subtitleOutline;

  /// 字幕延迟：正值表示字幕**延后**出现，负值表示提前。
  final Duration subtitleDelay;

  /// 硬件解码开关（文档「部分设备硬解 HEVC 失败时可以切软解」）。
  ///
  /// 默认开启（硬解是常态，省电且流畅）；关掉即走软解——当某台设备硬解
  /// HEVC 花屏 / 黑屏时，用户有一个不用换播放器的出口。
  final bool hardwareDecoding;

  PlayerSettings copyWith({
    PlayerKernel? kernel,
    double? speed,
    bool? subtitlesEnabled,
    SubtitleSize? subtitleSize,
    SubtitleColor? subtitleColor,
    SubtitleOutline? subtitleOutline,
    Duration? subtitleDelay,
    bool? hardwareDecoding,
  }) {
    return PlayerSettings(
      kernel: kernel ?? this.kernel,
      speed: speed == null ? this.speed : normalizeSpeed(speed),
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      subtitleSize: subtitleSize ?? this.subtitleSize,
      subtitleColor: subtitleColor ?? this.subtitleColor,
      subtitleOutline: subtitleOutline ?? this.subtitleOutline,
      subtitleDelay: subtitleDelay == null
          ? this.subtitleDelay
          : normalizeSubtitleDelay(subtitleDelay),
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    );
  }

  /// 倍速归一：非档位值（含 NaN）夹到最近档位，库被改坏时也不会拿到奇怪倍速。
  static double normalizeSpeed(double? value) {
    if (value == null || value.isNaN) return defaultSpeed;
    var best = speeds.first;
    for (final speed in speeds) {
      if ((speed - value).abs() < (best - value).abs()) best = speed;
    }
    return best;
  }

  /// 字幕延迟归一：夹到 ±10 秒，并归到 0.1 秒。
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
  bool operator ==(Object other) =>
      other is PlayerSettings &&
      other.kernel == kernel &&
      other.speed == speed &&
      other.subtitlesEnabled == subtitlesEnabled &&
      other.subtitleSize == subtitleSize &&
      other.subtitleColor == subtitleColor &&
      other.subtitleOutline == subtitleOutline &&
      other.subtitleDelay == subtitleDelay &&
      other.hardwareDecoding == hardwareDecoding;

  @override
  int get hashCode => Object.hash(
        kernel,
        speed,
        subtitlesEnabled,
        subtitleSize,
        subtitleColor,
        subtitleOutline,
        subtitleDelay,
        hardwareDecoding,
      );
}
