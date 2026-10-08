import 'dart:convert';

import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/util/lume_log.dart';

/// 「视频」板块的播放器设置持久化。
///
/// 存储落在本板块独占的 `sections/video/reading.db`（reading_setting 表），
/// 与图源库分文件、与其他板块分库，隔离机制沿用阅读底座的路径校验与库内自证；
/// 播放器设置不会跨板块共享。
///
/// ## 按内核分别记住（用户点名）
///
/// 倍速 / 画面（缩放 · 旋转 · 镜像）/ 字幕设置每个内核各存一格，键是
/// `video.player.prefs.<内核 id>`，值是一份 [KernelPrefs] 的 JSON。
/// 切内核时读的是那一格——这正是「切到 MPV 调好的字幕样式不会漂到 AVPlayer」。
///
/// ## 老库兼容
///
/// 早期版本把这些值存在全局键里（`video.player.speed` 等）。读的时候先看新键，
/// 没有就用全局键**迁移一次**（迁给当前内核），因此升级后设置不会丢；
/// 写的时候同时镜像一份到全局键，方便回退到旧版本时也读得到。
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
  static const String keyAutoHideControls = 'video.player.autoHideControls';

  /// 手势灵敏度（亮度 / 音量垂直滑动）。
  static const String keyGestureSensitivity = 'video.player.gestureSensitivity';

  /// 自动连播（缺键按「开」；与模块设置页同一步数据）。
  static const String keyAutoNext = 'video.player.autoNext';

  /// 字幕字体 / 阴影强度 / 垂直偏移（用户口径三项）。
  static const String keySubtitleFont = 'video.player.subtitleFont';
  static const String keySubtitleShadow = 'video.player.subtitleShadow';
  static const String keySubtitleOffsetY = 'video.player.subtitleOffsetY';

  /// 每内核一格偏好的键前缀（后缀是内核 id）。
  static const String keyPrefsPrefix = 'video.player.prefs.';

  /// 某个内核的偏好键。
  static String keyPrefsFor(PlayerKernel kernel) =>
      '$keyPrefsPrefix${kernel.id}';

  final ReadingLibrary _library;

  /// 读取设置；缺项或值非法时回退默认值。
  PlayerSettings load() {
    final kernel = PlayerKernel.fromId(_library.setting(keyKernel));

    // 先收各内核存过的偏好，再把「老全局键」作为**兜底**迁给当前内核。
    final prefs = <PlayerKernel, KernelPrefs>{};
    for (final candidate in PlayerKernel.values) {
      final raw = _library.setting(keyPrefsFor(candidate));
      if (raw == null || raw.trim().isEmpty) continue;
      try {
        prefs[candidate] = KernelPrefs.fromJson(jsonDecode(raw));
      } catch (error) {
        // 单格坏掉只影响那一格，其余内核照常。
        LumeLog.warn('[video] 内核 ${candidate.id} 的播放偏好解析失败：$error');
      }
    }
    // 老库迁移：只在**确实存过非默认值**时才给当前内核补一格。
    // 空库不凭空造格——那会让「全新安装」与「读过一次」两种状态的设置对象不相等。
    final legacy = _legacyPrefs();
    if (legacy != const KernelPrefs()) prefs.putIfAbsent(kernel, () => legacy);

    return PlayerSettings(
      kernel: kernel,
      // 旧库没有这一项时（键缺失）按「开」处理——与历史行为一致。
      subtitlesEnabled: _library.setting(keySubtitles) != 'false',
      hardwareDecoding: _library.setting(keyHardwareDecoding) != 'false',
      // 缺键按「开」处理（默认开启自动隐藏）。
      autoHideControls: _library.setting(keyAutoHideControls) != 'false',
      // 同上：缺键按「开」（历史行为就是一集播完自动进下一集）。
      autoNext: _library.setting(keyAutoNext) != 'false',
      gestureSensitivity: _gestureSensitivityOf(_library),
      prefs: prefs,
    );
  }

  /// 写回本板块的库（**各内核那一格都写** + 全局键镜像）。
  ///
  /// 为什么要写全部而不是只写当前内核那一格：设置对象里带着各内核的偏好
  /// （切来切去时它们都在内存里），一次保存把它们一起落库——否则「在 MPV 上调过、
  /// 之后一直在用 AVPlayer」的情况下，MPV 那一格要等下次选中它才被写到，
  /// 中间重启就丢了。
  void save(PlayerSettings settings) {
    _library.setSetting(keyKernel, settings.kernel.id);
    _library.setSetting(keyAutoNext, settings.autoNext ? 'true' : 'false');
    for (final entry in settings.prefs.entries) {
      _library.setSetting(
        keyPrefsFor(entry.key),
        jsonEncode(entry.value.toJson()),
      );
    }
    // 当前内核那一格一定要有：内存里没记录过时用默认值补一份，
    // 免得下次 load 又走一遍「从老键迁移」。
    if (!settings.prefs.containsKey(settings.kernel)) {
      _library.setSetting(
        keyPrefsFor(settings.kernel),
        jsonEncode(settings.current.toJson()),
      );
    }

    // 全局键镜像：值为**当前内核**的那一份，回退到旧版本时仍读得出意义。
    _library.setSetting(keySpeed, settings.speed.toStringAsFixed(2));
    _library.setSetting(
      keySubtitles,
      settings.subtitlesEnabled ? 'true' : 'false',
    );
    _library.setSetting(keySubtitleSize, settings.subtitleSize.id);
    _library.setSetting(keySubtitleFont, settings.subtitleFont);
    _library.setSetting(keySubtitleShadow, '${settings.subtitleShadow}');
    _library.setSetting(keySubtitleOffsetY, '${settings.subtitleOffsetY}');
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
    _library.setSetting(
      keyAutoHideControls,
      settings.autoHideControls ? 'true' : 'false',
    );
    _library.setSetting(keyGestureSensitivity, '${settings.gestureSensitivity}');
  }

  /// 老版本的全局键 → 一份偏好（迁移用）。
  KernelPrefs _legacyPrefs() => KernelPrefs(
        speed: PlayerSettings.normalizeSpeed(
          double.tryParse(_library.setting(keySpeed) ?? ''),
        ),
        subtitleSize: SubtitleSize.fromId(_library.setting(keySubtitleSize)),
      subtitleFont: _library.setting(keySubtitleFont) ?? '',
      subtitleShadow: _double(_library, keySubtitleShadow, 0.0, 0.0, 1.0),
      subtitleOffsetY: _double(_library, keySubtitleOffsetY, 0.0, -1.0, 1.0),
        subtitleColor: SubtitleColor.fromId(_library.setting(keySubtitleColor)),
        subtitleOutline:
            SubtitleOutline.fromId(_library.setting(keySubtitleOutline)),
        subtitleDelay: PlayerSettings.normalizeSubtitleDelay(
          _intMillis(_library.setting(keySubtitleDelay)),
        ),
      );

  /// 读毫秒值；缺失或非法返回 null（由归一函数回退到零延迟）。
  static Duration? _intMillis(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = int.tryParse(raw.trim());
    return value == null ? null : Duration(milliseconds: value);
  }

  /// 释放本板块的库（页面退出时调用）。
  void close() => ReadingLibrary.close(Section.video);
}

/// 读手势灵敏度：没写过 / 解析失败 / 越界都回落到默认 1.0。
double _gestureSensitivityOf(ReadingLibrary library) {
  final raw = library.setting(VideoPlayerSettingsStore.keyGestureSensitivity);
  final value = double.tryParse((raw ?? '').trim());
  if (value == null || value.isNaN) return PlayerSettings.defaultGestureSensitivity;
  return value
      .clamp(
        PlayerSettings.minGestureSensitivity,
        PlayerSettings.maxGestureSensitivity,
      )
      .toDouble();
}

/// 读一个 double 设置：没写过 / 解析失败 / 越界都回落到 [fallback] 并夹进范围。
double _double(ReadingLibrary library, String key, double fallback, double min, double max) {
  final raw = library.setting(key);
  final value = double.tryParse((raw ?? '').trim());
  if (value == null || value.isNaN) return fallback;
  return value.clamp(min, max).toDouble();
}
