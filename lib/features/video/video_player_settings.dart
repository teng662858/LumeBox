import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';

/// 「自定义视频」板块的播放器设置持久化。
///
/// 存储落在本板块独占的 `sections/video/reading.db`（reading_setting 表），
/// 与图源库分文件、与其他板块分库，隔离机制沿用阅读底座的路径校验与库内自证；
/// 播放器设置不会跨板块共享。
class VideoPlayerSettingsStore {
  const VideoPlayerSettingsStore(this._library);

  /// 打开本板块的库并返回设置存储。页面退出时由调用方 [close]。
  static Future<VideoPlayerSettingsStore> open() async =>
      VideoPlayerSettingsStore(await ReadingLibrary.open(Section.video));

  static const String keyKernel = 'video.player.kernel';
  static const String keySpeed = 'video.player.speed';
  static const String keySubtitles = 'video.player.subtitles';
  static const String keySubtitleSize = 'video.player.subtitleSize';
  static const String keySubtitleColor = 'video.player.subtitleColor';
  static const String keySubtitleOutline = 'video.player.subtitleOutline';
  static const String keySubtitleDelay = 'video.player.subtitleDelayMs';
  static const String keyHardwareDecoding = 'video.player.hardwareDecoding';

  final ReadingLibrary _library;

  /// 读取设置；缺项或值非法时回退默认值。
  PlayerSettings load() => PlayerSettings(
        kernel: PlayerKernel.fromId(_library.setting(keyKernel)),
        speed: PlayerSettings.normalizeSpeed(
          double.tryParse(_library.setting(keySpeed) ?? ''),
        ),
        // 旧库没有这一项时（键缺失）按「开」处理——与历史行为一致。
        subtitlesEnabled: _library.setting(keySubtitles) != 'false',
        subtitleSize: SubtitleSize.fromId(_library.setting(keySubtitleSize)),
        subtitleColor: SubtitleColor.fromId(_library.setting(keySubtitleColor)),
        subtitleOutline:
            SubtitleOutline.fromId(_library.setting(keySubtitleOutline)),
        subtitleDelay: PlayerSettings.normalizeSubtitleDelay(
          _intMillis(_library.setting(keySubtitleDelay)),
        ),
        hardwareDecoding: _library.setting(keyHardwareDecoding) != 'false',
      );

  /// 写回本板块的库。
  void save(PlayerSettings settings) {
    _library.setSetting(keyKernel, settings.kernel.id);
    _library.setSetting(keySpeed, settings.speed.toStringAsFixed(2));
    _library.setSetting(
      keySubtitles,
      settings.subtitlesEnabled ? 'true' : 'false',
    );
    _library.setSetting(keySubtitleSize, settings.subtitleSize.id);
    _library.setSetting(keySubtitleColor, settings.subtitleColor.id);
    _library.setSetting(keySubtitleOutline, settings.subtitleOutline.id);
    _library.setSetting(
      keySubtitleDelay,
      '${settings.subtitleDelay.inMilliseconds}',
    );
    _library.setSetting(
      keyHardwareDecoding,
      settings.hardwareDecoding ? 'true' : 'false',
    );
  }

  /// 读毫秒值；缺失或非法返回 null（由归一函数回退到零延迟）。
  static Duration? _intMillis(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = int.tryParse(raw.trim());
    return value == null ? null : Duration(milliseconds: value);
  }

  /// 释放本板块的库（页面退出时调用）。
  void close() => ReadingLibrary.close(Section.video);
}
