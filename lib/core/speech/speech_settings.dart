import 'dart:convert';

import 'speech_mode.dart';
export 'speech_mode.dart';

/// 漫画朗读设置：语速、音调、音量、跟读翻页、每片字数、后台播放。
///
/// 设置保存在漫画阅读库中。所有数值都在 [decode] / [copyWith] 里收敛到合法范围，
/// 库被改坏也不会把非法值送到引擎（引擎拿到越界值会直接抛错）。
class SpeechSettings {
  const SpeechSettings({
    this.rate = 0.5,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.followAlong = true,
    this.maxCharsPerSegment = 1000,
    this.backgroundPlayback = true,
    this.mode = SpeechMode.system,
    this.autoDialogue = false,
    this.narratorVoice = '',
    this.maleVoice = '',
    this.femaleVoice = '',
    this.profiles = const {},
  });

  static const String settingKey = 'speech.settings';
  final SpeechMode mode;
  final bool autoDialogue;
  final String narratorVoice, maleVoice, femaleVoice;
  final Map<String, Map<String, Object?>> profiles;
  Map<String, Object?> get _profile => {
    'rate': rate,
    'pitch': pitch,
    'volume': volume,
    'narratorVoice': narratorVoice,
    'maleVoice': maleVoice,
    'femaleVoice': femaleVoice,
  };

  /// 语速范围。0.5 是系统 TTS 的「正常语速」，1.0 已相当快。
  static const double minRate = 0.2;
  static const double maxRate = 1.0;

  /// 音调范围。
  static const double minPitch = 0.5;
  static const double maxPitch = 2.0;

  /// 音量范围。
  static const double minVolume = 0.0;
  static const double maxVolume = 1.0;

  /// 单片字数范围：太短会让断句频繁，太长则进度回报变粗。
  static const int minSegmentChars = 200;
  static const int maxSegmentChars = 3000;

  /// 语速（0.2~1.0；1.0 最快）。
  final double rate;

  /// 音调（0.5~2.0；1.0 为原声）。
  final double pitch;

  /// 音量（0~1）。
  final double volume;

  /// 朗读时是否自动翻页跟读（翻到当前朗读位置所在页）。
  final bool followAlong;

  /// 每次交给引擎的字数上限。
  final int maxCharsPerSegment;

  /// 是否允许后台播放（离开 App 后继续朗读，并由锁屏控件接管）。
  ///
  /// 默认开：听书的常见用法就是锁屏听。关掉后离开 App 会停止朗读
  /// （由原生侧决定是否停用音频会话）。
  final bool backgroundPlayback;

  SpeechSettings copyWith({
    double? rate,
    double? pitch,
    double? volume,
    bool? followAlong,
    int? maxCharsPerSegment,
    bool? backgroundPlayback,
    SpeechMode? mode,
    bool? autoDialogue,
    String? narratorVoice,
    String? maleVoice,
    String? femaleVoice,
  }) {
    final target = mode ?? this.mode;
    final saved = {...profiles, this.mode.name: _profile};
    if (target != this.mode) {
      final profile = saved[target.name] ?? {};
      final defaults = target == SpeechMode.kokoro
          ? ['3', '58', '3']
          : target == SpeechMode.local
          ? ['66', '0', '66']
          : target == SpeechMode.system
          ? ['', '', '']
          : ['alloy', 'onyx', 'nova'];
      return SpeechSettings(
        mode: target,
        profiles: saved,
        autoDialogue: autoDialogue ?? this.autoDialogue,
        rate: _number(profile['rate'], .5).clamp(minRate, maxRate),
        pitch: _number(profile['pitch'], 1).clamp(minPitch, maxPitch),
        volume: _number(profile['volume'], 1).clamp(minVolume, maxVolume),
        narratorVoice: profile['narratorVoice'] is String
            ? profile['narratorVoice'] as String
            : defaults[0],
        maleVoice: profile['maleVoice'] is String
            ? profile['maleVoice'] as String
            : defaults[1],
        femaleVoice: profile['femaleVoice'] is String
            ? profile['femaleVoice'] as String
            : defaults[2],
        followAlong: followAlong ?? this.followAlong,
        maxCharsPerSegment: maxCharsPerSegment ?? this.maxCharsPerSegment,
        backgroundPlayback: backgroundPlayback ?? this.backgroundPlayback,
      );
    }
    return SpeechSettings(
      mode: target,
      profiles: saved,
      autoDialogue: autoDialogue ?? this.autoDialogue,
      narratorVoice: narratorVoice ?? this.narratorVoice,
      maleVoice: maleVoice ?? this.maleVoice,
      femaleVoice: femaleVoice ?? this.femaleVoice,
      rate: (rate ?? this.rate).clamp(minRate, maxRate).toDouble(),
      pitch: (pitch ?? this.pitch).clamp(minPitch, maxPitch).toDouble(),
      volume: (volume ?? this.volume).clamp(minVolume, maxVolume).toDouble(),
      followAlong: followAlong ?? this.followAlong,
      maxCharsPerSegment: (maxCharsPerSegment ?? this.maxCharsPerSegment).clamp(
        minSegmentChars,
        maxSegmentChars,
      ),
      backgroundPlayback: backgroundPlayback ?? this.backgroundPlayback,
    );
  }

  String encode() => jsonEncode(<String, Object?>{
    'mode': mode.name,
    'autoDialogue': autoDialogue,
    'narratorVoice': narratorVoice,
    'maleVoice': maleVoice,
    'femaleVoice': femaleVoice,
    'profiles': {...profiles, mode.name: _profile},
    'rate': rate,
    'pitch': pitch,
    'volume': volume,
    'followAlong': followAlong,
    'maxCharsPerSegment': maxCharsPerSegment,
    'backgroundPlayback': backgroundPlayback,
  });

  static SpeechSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return const SpeechSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SpeechSettings();
      final mode = SpeechMode.parse(decoded['mode']);
      final saved = <String, Map<String, Object?>>{};
      final rawProfiles = decoded['profiles'];
      if (rawProfiles is Map) {
        for (final mode in SpeechMode.values) {
          final profile = rawProfiles[mode.name];
          if (profile is Map) {
            saved[mode.name] = {
              for (final item in profile.entries)
                if (item.key is String) item.key as String: item.value,
            };
          }
        }
      }
      final base = SpeechSettings(
        mode: mode,
        profiles: saved,
        autoDialogue: decoded['autoDialogue'] == true,
        narratorVoice: decoded['narratorVoice'] is String
            ? decoded['narratorVoice'] as String
            : '',
        maleVoice: decoded['maleVoice'] is String
            ? decoded['maleVoice'] as String
            : '',
        femaleVoice: decoded['femaleVoice'] is String
            ? decoded['femaleVoice'] as String
            : '',
      );
      return base.copyWith(
        rate: _number(decoded['rate'], base.rate),
        pitch: _number(decoded['pitch'], base.pitch),
        volume: _number(decoded['volume'], base.volume),
        followAlong: decoded['followAlong'] is bool
            ? decoded['followAlong'] as bool
            : base.followAlong,
        maxCharsPerSegment: decoded['maxCharsPerSegment'] is num
            ? (decoded['maxCharsPerSegment'] as num).round()
            : base.maxCharsPerSegment,
        backgroundPlayback: decoded['backgroundPlayback'] is bool
            ? decoded['backgroundPlayback'] as bool
            : base.backgroundPlayback,
      );
    } on FormatException {
      return const SpeechSettings();
    }
  }

  static double _number(Object? value, double fallback) =>
      value is num && value.isFinite ? value.toDouble() : fallback;
}
