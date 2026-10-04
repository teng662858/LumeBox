/// 播放器设置模型（纯 Dart，不认识平台、存储与 UI）。
///
/// 三套内核与宪法一致：AVPlayer / MPV / MDK；设置项覆盖内核选择、倍速与字幕
/// 基础配置。持久化由所在板块负责——播放器设置落在「自定义视频」板块自己的
/// 库里（见 `lib/features/video/video_player_settings.dart`），模型本身不带
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

/// 字幕字号档位（字幕基础配置）。
enum SubtitleSize {
  small('small', '小', 0.85),
  standard('standard', '标准', 1.0),
  large('large', '大', 1.25);

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

/// 播放器设置：内核、倍速、字幕基础配置。
class PlayerSettings {
  const PlayerSettings({
    this.kernel = PlayerKernel.avplayer,
    this.speed = defaultSpeed,
    this.subtitlesEnabled = true,
    this.subtitleSize = SubtitleSize.standard,
  });

  /// 可选倍速档位（设置页按此渲染）。
  static const List<double> speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  static const double defaultSpeed = 1.0;

  /// 播放内核。
  final PlayerKernel kernel;

  /// 播放倍速，取值必然落在 [speeds] 内。
  final double speed;

  /// 字幕总开关。
  final bool subtitlesEnabled;

  /// 字幕字号档位。
  final SubtitleSize subtitleSize;

  PlayerSettings copyWith({
    PlayerKernel? kernel,
    double? speed,
    bool? subtitlesEnabled,
    SubtitleSize? subtitleSize,
  }) {
    return PlayerSettings(
      kernel: kernel ?? this.kernel,
      speed: speed == null ? this.speed : normalizeSpeed(speed),
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      subtitleSize: subtitleSize ?? this.subtitleSize,
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

  @override
  bool operator ==(Object other) =>
      other is PlayerSettings &&
      other.kernel == kernel &&
      other.speed == speed &&
      other.subtitlesEnabled == subtitlesEnabled &&
      other.subtitleSize == subtitleSize;

  @override
  int get hashCode =>
      Object.hash(kernel, speed, subtitlesEnabled, subtitleSize);
}
