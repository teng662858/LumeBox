import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/reading/reading.dart';
import '../../../core/session/section.dart';
import '../../../core/util/lume_log.dart';
import 'danmaku_models.dart';

/// 弹幕设置：开关、透明度、字号、显示区域、速度、描边。
///
/// 存本板块阅读库（与视频进度同库）：弹幕是视频板块的显示偏好，不该跨板块共享。
class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = true,
    this.opacity = 0.9,
    this.fontScale = 1.0,
    this.displayArea = 0.5,
    this.speedScale = 1.0,
    this.strokeWidth = 1.2,
    this.maxOnScreen = 60,
  });

  /// 总开关。
  final bool enabled;

  /// 透明度 0.1~1.0。
  final double opacity;

  /// 字号倍数 0.5~2.0。
  final double fontScale;

  /// 显示区域：屏幕高度的比例 0.2~1.0（顶部固定弹幕与滚动弹幕共用）。
  final double displayArea;

  /// 速度倍数 0.5~2.0（越大滚得越快）。
  final double speedScale;

  /// 描边宽度 0~3（浅色背景下保证可读）。
  final double strokeWidth;

  /// 同屏最大条数 10~200（防止刷屏卡顿）。
  final int maxOnScreen;

  static const DanmakuSettings defaults = DanmakuSettings();

  static const String settingKey = 'video.danmaku.settings';

  /// 每项的取值范围（UI 滑杆与解码共用，避免两处写死不同值）。
  static const double minOpacity = 0.1;
  static const double maxOpacity = 1.0;
  static const double minFontScale = 0.5;
  static const double maxFontScale = 2.0;
  static const double minArea = 0.2;
  static const double maxArea = 1.0;
  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;
  static const double minStroke = 0.0;
  static const double maxStroke = 3.0;
  static const int minOnScreen = 10;
  static const int maxOnScreenLimit = 200;

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? displayArea,
    double? speedScale,
    double? strokeWidth,
    int? maxOnScreen,
  }) {
    return DanmakuSettings(
      enabled: enabled ?? this.enabled,
      opacity: opacity ?? this.opacity,
      fontScale: fontScale ?? this.fontScale,
      displayArea: displayArea ?? this.displayArea,
      speedScale: speedScale ?? this.speedScale,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      maxOnScreen: maxOnScreen ?? this.maxOnScreen,
    );
  }

  /// 收敛到合法区间（坏配置不会让渲染崩）。
  DanmakuSettings clamped() => DanmakuSettings(
        enabled: enabled,
        opacity: opacity.clamp(minOpacity, maxOpacity),
        fontScale: fontScale.clamp(minFontScale, maxFontScale),
        displayArea: displayArea.clamp(minArea, maxArea),
        speedScale: speedScale.clamp(minSpeed, maxSpeed),
        strokeWidth: strokeWidth.clamp(minStroke, maxStroke),
        maxOnScreen: maxOnScreen.clamp(minOnScreen, maxOnScreenLimit),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'opacity': opacity,
        'fontScale': fontScale,
        'displayArea': displayArea,
        'speedScale': speedScale,
        'strokeWidth': strokeWidth,
        'maxOnScreen': maxOnScreen,
      };

  static DanmakuSettings fromJson(Object? json) {
    if (json is! Map) return defaults;
    const base = DanmakuSettings();
    return DanmakuSettings(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : base.enabled,
      opacity: _double(json['opacity'], base.opacity),
      fontScale: _double(json['fontScale'], base.fontScale),
      displayArea: _double(json['displayArea'], base.displayArea),
      speedScale: _double(json['speedScale'], base.speedScale),
      strokeWidth: _double(json['strokeWidth'], base.strokeWidth),
      maxOnScreen: _int(json['maxOnScreen'], base.maxOnScreen),
    ).clamped();
  }

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  static int _int(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuSettings &&
      other.enabled == enabled &&
      other.opacity == opacity &&
      other.fontScale == fontScale &&
      other.displayArea == displayArea &&
      other.speedScale == speedScale &&
      other.strokeWidth == strokeWidth &&
      other.maxOnScreen == maxOnScreen;

  @override
  int get hashCode => Object.hash(
        enabled,
        opacity,
        fontScale,
        displayArea,
        speedScale,
        strokeWidth,
        maxOnScreen,
      );
}

/// 弹幕设置的持久化（本板块阅读库的 `reading_setting` 表）。
class DanmakuSettingsStore {
  const DanmakuSettingsStore(this._library);

  final ReadingLibrary _library;

  DanmakuSettings load() => DanmakuSettings.fromJson(
        _decode(_library.setting(DanmakuSettings.settingKey)),
      );

  void save(DanmakuSettings settings) {
    _library.setSetting(
      DanmakuSettings.settingKey,
      jsonEncode(settings.clamped().toJson()),
    );
  }

  static Object? _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (error) {
      LumeLog.warn('弹幕设置解析失败，用默认值: $error');
      return null;
    }
  }
}

/// 单集弹幕的本地缓存（内存 + 可选落库）。
///
/// 键 = `itemId/chapterId`：同一部作品的不同集各自一份，互不串。
/// 内存缓存避免拖动进度条时反复重读库；条目上限防止长会话堆积。
class DanmakuCache {
  DanmakuCache({this.maxEntries = 20});

  final int maxEntries;

  final Map<String, DanmakuTrack> _memory = <String, DanmakuTrack>{};

  static String keyFor(String itemId, String chapterId) =>
      '$itemId/$chapterId';

  DanmakuTrack? get(String itemId, String chapterId) =>
      _memory[keyFor(itemId, chapterId)];

  void put(String itemId, String chapterId, DanmakuTrack track) {
    final key = keyFor(itemId, chapterId);
    // 超上限时丢最早插入的一条（简单 FIFO 足够：弹幕是纯缓存）。
    if (!_memory.containsKey(key) && _memory.length >= maxEntries) {
      _memory.remove(_memory.keys.first);
    }
    _memory[key] = track;
  }

  void clear() => _memory.clear();

  int get length => _memory.length;
}

/// 弹幕样式 → 画笔：把设置翻译成渲染参数（颜色 / 描边 / 字号）。
class DanmakuStyle {
  const DanmakuStyle({
    required this.fontSize,
    required this.strokeWidth,
    required this.color,
  });

  /// 实际字号（像素）。
  final double fontSize;

  final double strokeWidth;
  final Color color;

  /// 基准字号：设置里的 fontScale 是它的倍数。
  static const double baseFontSize = 16;

  /// 一条弹幕在该设置下的样式。
  static DanmakuStyle of(DanmakuItem item, DanmakuSettings settings) {
    final scale = (item.fontSize * settings.fontScale).clamp(0.5, 3.0);
    return DanmakuStyle(
      fontSize: baseFontSize * scale,
      strokeWidth: settings.strokeWidth,
      color: Color(0xFF000000 | item.color)
          .withValues(alpha: settings.opacity.clamp(0.1, 1.0)),
    );
  }
}

/// 弹幕板块的说明常量（避免散落魔法字符串）。
class DanmakuConfig {
  DanmakuConfig._();

  /// 图源契约方法名：`danmaku({id, chapterId})` → 弹幕数组或信封。
  static const String contractMethod = 'danmaku';

  /// 本地导入的弹幕文件扩展名。
  static const List<String> fileExtensions = <String>['.json', '.xml'];

  /// 弹幕板块归属（弹幕只属于视频板块）。
  static const Section section = Section.video;
}
