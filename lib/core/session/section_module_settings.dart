import 'dart:convert';

import '../reading/reading_library.dart';
import '../util/lume_log.dart';

/// 预制布局方案（用户口径：**不开放自由拖拽 / 自定义坐标**——页面布局与控件位置
/// 由开发给几套方案，用户只管选）。
///
/// 每套方案 = 一组配套的取值（控件尺寸、间距、面板密度），而不是让用户拼坐标；
/// 选完之后仍可在下面的滑杆上微调**数值**（尺寸 / 间距 / 阈值），但位置关系不变。
enum ModuleLayoutPreset {
  compact('紧凑', 0.9, 0.85),
  standard('标准', 1.0, 1.0),
  roomy('宽松', 1.1, 1.2);

  const ModuleLayoutPreset(this.label, this.controlScale, this.spacingScale);

  final String label;

  /// 控件（按钮 / 图标 / 面板内控件）的相对尺寸。
  final double controlScale;

  /// 各类间距的相对倍数（面板行距、列表间距……）。
  final double spacingScale;
}

/// **模块设置**：按板块独立存储的那些「通用参数」。
///
/// ## 隔离口径（用户要求：各媒介配置互不影响）
///
/// 每个板块有自己的库（`sections/<id>/reading.db`），本模型就写在自己板块的库里
/// （键 [key]）——小说改字号不会碰漫画的；漫画调手势阈值不会碰视频的。
/// 阅读器 / 播放器里的**就地设置**与这里读写的是**同一份数据**，因此两边永远一致
///（双向同步：任意一处改，另一处立刻是同一个值）。
///
/// 什么该放这里：跨阅读器 / 播放器**通用**的数值——手势触发阈值、控件尺寸、
/// 间距、动画开关、播放缓冲。什么不放：具体业务的选项（漫画的排版模式、小说的
/// 字体族、视频的内核……）各归各的现有设置，这里只做**入口聚合**（见模块设置页）。
class SectionModuleSettings {
  const SectionModuleSettings({
    this.layoutPreset = ModuleLayoutPreset.standard,
    this.controlScale = 1.0,
    this.spacingScale = 1.0,
    this.animationEnabled = true,
    this.toolbarToggleDelayMs = defaultToolbarToggleDelayMs,
    this.doubleTapWindowMs = defaultDoubleTapWindowMs,
    this.swipeTurnThresholdPx = defaultSwipeTurnThresholdPx,
    this.longPressMs = defaultLongPressMs,
    this.bufferSeconds = 0,
  });

  /// 呼出工具栏（含底部面板）的延后：**这是防误触的那个阈值**，越大越不容易误触。
  static const int defaultToolbarToggleDelayMs = 260;

  static const int defaultDoubleTapWindowMs = 260;
  static const int defaultSwipeTurnThresholdPx = 18;
  static const int defaultLongPressMs = 450;

  // 可调范围（UI 只读这些常量，不各自写数字）。
  static const int minToolbarToggleDelayMs = 0;
  static const int maxToolbarToggleDelayMs = 600;
  static const int minDoubleTapWindowMs = 200;
  static const int maxDoubleTapWindowMs = 400;
  static const int minSwipeTurnThresholdPx = 8;
  static const int maxSwipeTurnThresholdPx = 40;
  static const int minLongPressMs = 300;
  static const int maxLongPressMs = 800;

  /// 前向缓冲秒数；**0 = 交给内核自动决定**（默认，起播最快）。
  static const int maxBufferSeconds = 30;

  static const double minControlScale = 0.85;
  static const double maxControlScale = 1.15;
  static const double minSpacingScale = 0.8;
  static const double maxSpacingScale = 1.3;

  /// 库里的键（按板块各自的库分开存 → 天然隔离）。
  static const String key = 'module.settings';

  final ModuleLayoutPreset layoutPreset;
  final double controlScale;
  final double spacingScale;
  final bool animationEnabled;
  final int toolbarToggleDelayMs;
  final int doubleTapWindowMs;
  final int swipeTurnThresholdPx;
  final int longPressMs;
  final int bufferSeconds;

  Duration get toolbarToggleDelay =>
      Duration(milliseconds: toolbarToggleDelayMs);
  Duration get doubleTapWindow => Duration(milliseconds: doubleTapWindowMs);
  Duration get longPress => Duration(milliseconds: longPressMs);
  Duration get buffer => Duration(seconds: bufferSeconds);

  SectionModuleSettings copyWith({
    ModuleLayoutPreset? layoutPreset,
    double? controlScale,
    double? spacingScale,
    bool? animationEnabled,
    int? toolbarToggleDelayMs,
    int? doubleTapWindowMs,
    int? swipeTurnThresholdPx,
    int? longPressMs,
    int? bufferSeconds,
  }) =>
      SectionModuleSettings(
        layoutPreset: layoutPreset ?? this.layoutPreset,
        controlScale: controlScale ?? this.controlScale,
        spacingScale: spacingScale ?? this.spacingScale,
        animationEnabled: animationEnabled ?? this.animationEnabled,
        toolbarToggleDelayMs:
            toolbarToggleDelayMs ?? this.toolbarToggleDelayMs,
        doubleTapWindowMs: doubleTapWindowMs ?? this.doubleTapWindowMs,
        swipeTurnThresholdPx:
            swipeTurnThresholdPx ?? this.swipeTurnThresholdPx,
        longPressMs: longPressMs ?? this.longPressMs,
        bufferSeconds: bufferSeconds ?? this.bufferSeconds,
      );

  /// 套用一套预制方案：尺寸与间距跟着方案走（阈值等其它项不动）。
  SectionModuleSettings withPreset(ModuleLayoutPreset preset) => copyWith(
        layoutPreset: preset,
        controlScale: preset.controlScale,
        spacingScale: preset.spacingScale,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'preset': layoutPreset.name,
        'controlScale': controlScale,
        'spacingScale': spacingScale,
        'animation': animationEnabled,
        'toggleDelayMs': toolbarToggleDelayMs,
        'doubleTapMs': doubleTapWindowMs,
        'swipeThresholdPx': swipeTurnThresholdPx,
        'longPressMs': longPressMs,
        'bufferSeconds': bufferSeconds,
      };

  /// 从落盘 JSON 还原；缺项与非法值一律回退默认（旧配置不会让页面起不来），
  /// 越界值钳到区间内（与网络 / 沙箱设置同一套口径）。
  static SectionModuleSettings fromJson(Object? json) {
    if (json is! Map) return const SectionModuleSettings();
    final preset = ModuleLayoutPreset.values.firstWhere(
      (item) => item.name == '${json['preset']}',
      orElse: () => ModuleLayoutPreset.standard,
    );
    return SectionModuleSettings(
      layoutPreset: preset,
      controlScale: _clampDouble(
        json['controlScale'],
        minControlScale,
        maxControlScale,
        1.0,
      ),
      spacingScale: _clampDouble(
        json['spacingScale'],
        minSpacingScale,
        maxSpacingScale,
        1.0,
      ),
      animationEnabled: json['animation'] is bool
          ? json['animation']! as bool
          : true,
      toolbarToggleDelayMs: _clampInt(
        json['toggleDelayMs'],
        minToolbarToggleDelayMs,
        maxToolbarToggleDelayMs,
        defaultToolbarToggleDelayMs,
      ),
      doubleTapWindowMs: _clampInt(
        json['doubleTapMs'],
        minDoubleTapWindowMs,
        maxDoubleTapWindowMs,
        defaultDoubleTapWindowMs,
      ),
      swipeTurnThresholdPx: _clampInt(
        json['swipeThresholdPx'],
        minSwipeTurnThresholdPx,
        maxSwipeTurnThresholdPx,
        defaultSwipeTurnThresholdPx,
      ),
      longPressMs: _clampInt(
        json['longPressMs'],
        minLongPressMs,
        maxLongPressMs,
        defaultLongPressMs,
      ),
      bufferSeconds: _clampInt(json['bufferSeconds'], 0, maxBufferSeconds, 0),
    );
  }

  /// 读本板块的模块设置（读不到就是默认值，绝不抛）。
  static SectionModuleSettings load(ReadingLibrary library) {
    final raw = library.setting(key);
    if (raw == null || raw.trim().isEmpty) return const SectionModuleSettings();
    try {
      return fromJson(jsonDecode(raw));
    } catch (error) {
      LumeLog.warn('[${library.section.id}] 模块设置解析失败，用默认值：$error');
      return const SectionModuleSettings();
    }
  }

  /// 写回本板块的库。
  void save(ReadingLibrary library) =>
      library.setSetting(key, jsonEncode(toJson()));

  static double _clampDouble(Object? value, double min, double max, double fallback) {
    final number = value is num ? value.toDouble() : null;
    if (number == null || number.isNaN) return fallback;
    if (number < min) return min;
    if (number > max) return max;
    return number;
  }

  static int _clampInt(Object? value, int min, int max, int fallback) {
    final number = value is num ? value.round() : null;
    if (number == null) return fallback;
    if (number < min) return min;
    if (number > max) return max;
    return number;
  }
}
