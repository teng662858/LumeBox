/// 播放器 HUD 参数（编码格式 / 码率 / 帧率 / 缓冲状态 / 分辨率）。
///
/// 契约来自宪法「播放器抽象架构规范」：
/// - **每个内核自己填**：MPV 用 libmpv 的轨道与视频参数，AVPlayer 用 video_player
///   能拿到的字段；上层只按 [chips] 渲染，不许在上层写任何内核私有 API；
/// - **拿不到的项留空**：HUD 只显示内核真给得出的数据，自动省略缺项，不编造；
/// - 换内核时上层 UI 与 HUD 一行都不用改（数据形状在这里统一）。
class PlayerStats {
  const PlayerStats({
    this.engineLabel = '',
    this.videoCodec,
    this.audioCodec,
    this.videoBitrateKbps,
    this.audioBitrateKbps,
    this.fps,
    this.width,
    this.height,
    this.buffered,
    this.buffering = false,
  });

  /// 内核显示名（HUD 上标明数据来自哪个内核，便于核对切换）。
  final String engineLabel;

  /// 视频 / 音频编码格式（如 `hevc` / `h264` / `aac`）。
  final String? videoCodec;

  final String? audioCodec;

  /// 视频 / 音频码率，统一单位 **kbps**（内核负责把底层单位换算到 kbps）。
  final double? videoBitrateKbps;

  final double? audioBitrateKbps;

  /// 帧率。
  final double? fps;

  /// 分辨率（像素）。
  final int? width;

  final int? height;

  /// 缓冲状态：当前位置**前方**已缓冲的时长。
  final Duration? buffered;

  /// 是否正在缓冲（等待数据）。
  final bool buffering;

  /// 空参数：HUD 什么都不显示。
  static const PlayerStats empty = PlayerStats();

  /// 分辨率文本，如 `1920×1080`；拿不到返回 null。
  String? get resolutionText {
    final w = width;
    final h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return '$w×$h';
  }

  /// 码率文本：视频优先、其次音频；`1.8Mbps` / `320kbps`。
  String? get bitrateText {
    final kbps = videoBitrateKbps ?? audioBitrateKbps;
    if (kbps == null || kbps <= 0) return null;
    if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(1)}Mbps';
    return '${kbps.round()}kbps';
  }

  /// 帧率文本，如 `30FPS` / `29.97FPS`；拿不到返回 null。
  String? get fpsText {
    final value = fps;
    if (value == null || value <= 0) return null;
    final rounded = value.roundToDouble();
    final text = (value - rounded).abs() < 0.005
        ? rounded.toStringAsFixed(0)
        : value.toStringAsFixed(2);
    return '${text}FPS';
  }

  /// 编码文本：视频编码优先，只有音频时给音频编码。
  String? get codecText {
    final video = _clean(videoCodec);
    if (video != null) return video.toUpperCase();
    final audio = _clean(audioCodec);
    return audio?.toUpperCase();
  }

  /// 缓冲文本：`缓冲中`（正在等数据）/ `缓冲 12s`（前方已缓冲）。
  String? get bufferText {
    if (buffering) return '缓冲中';
    final value = buffered;
    if (value == null || value <= Duration.zero) return null;
    final seconds = value.inMilliseconds / 1000;
    if (seconds >= 60) {
      final minutes = seconds ~/ 60;
      return '缓冲 ${minutes}m${(seconds - minutes * 60).round()}s';
    }
    return '缓冲 ${seconds.round()}s';
  }

  /// HUD 展示片段：固定顺序「编码 / 分辨率 / 帧率 / 码率 / 缓冲」，
  /// 缺项自动省略（顺序稳定，换内核时 HUD 的读法一致）。
  List<String> get chips {
    final out = <String>[];
    final engine = _clean(engineLabel);
    if (engine != null) out.add(engine);
    for (final piece in <String?>[
      codecText,
      resolutionText,
      fpsText,
      bitrateText,
      bufferText,
    ]) {
      if (piece != null) out.add(piece);
    }
    return out;
  }

  bool get isEmpty => chips.isEmpty;

  /// 参数是否有任何一项来自底层（不看内核名）。
  bool get hasParameters => chips.length > (engineLabel.trim().isEmpty ? 0 : 1);

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
