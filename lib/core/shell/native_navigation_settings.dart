/// Preferences for the system tab bar, independent of the custom Dock material.
class NativeNavigationSettings {
  const NativeNavigationSettings({
    this.enabled = true,
    this.showLabels = true,
    this.solidIcons = false,
    this.followThemeColor = true,
    this.tintColor = 0xFF7C5CFF,
    this.iconSize = 22,
    this.horizontalMargin = 3,
    this.safeGap = -36,
    this.barHeight = 85,
    this.materialOpacity = .62,
    this.opaqueBackground = false,
  });

  final bool enabled;
  final bool showLabels;

  /// Optional monochrome solid icons; old configurations keep the original style.
  final bool solidIcons;
  final bool followThemeColor;
  final int tintColor;
  final double iconSize;
  final double horizontalMargin;
  final double safeGap;

  /// Zero follows UIKit. Otherwise the entire native control is scaled.
  final double barHeight;
  final double materialOpacity;
  final bool opaqueBackground;

  double heightFor(double systemHeight) =>
      barHeight > 0 ? barHeight.clamp(40.0, 120.0) : systemHeight;

  double bottomFor(double safeBottom) =>
      (safeBottom + safeGap).clamp(0.0, 200.0);

  NativeNavigationSettings copyWith({
    bool? enabled,
    bool? showLabels,
    bool? solidIcons,
    bool? followThemeColor,
    int? tintColor,
    double? iconSize,
    double? horizontalMargin,
    double? safeGap,
    double? barHeight,
    double? materialOpacity,
    bool? opaqueBackground,
  }) => NativeNavigationSettings.fromJson({
    ...toJson(),
    'enabled': ?enabled,
    'showLabels': ?showLabels,
    'solidIcons': ?solidIcons,
    'followThemeColor': ?followThemeColor,
    'tintColor': ?tintColor,
    'iconSize': ?iconSize,
    'horizontalMargin': ?horizontalMargin,
    'safeGap': ?safeGap,
    'barHeight': ?barHeight,
    'materialOpacity': ?materialOpacity,
    'opaqueBackground': ?opaqueBackground,
  });

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'showLabels': showLabels,
    'solidIcons': solidIcons,
    'followThemeColor': followThemeColor,
    'tintColor': tintColor,
    'iconSize': iconSize,
    'horizontalMargin': horizontalMargin,
    'safeGap': safeGap,
    'barHeight': barHeight,
    'materialOpacity': materialOpacity,
    'opaqueBackground': opaqueBackground,
  };

  static NativeNavigationSettings fromJson(Object? value) {
    if (value is! Map) return const NativeNavigationSettings();
    double number(String key, double fallback, double min, double max) {
      final raw = value[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    final tint = value['tintColor'];
    return NativeNavigationSettings(
      enabled: value['enabled'] is bool ? value['enabled'] as bool : true,
      showLabels: value['showLabels'] is bool
          ? value['showLabels'] as bool
          : true,
      solidIcons: value['solidIcons'] == true,
      followThemeColor: value['followThemeColor'] is bool
          ? value['followThemeColor'] as bool
          : true,
      tintColor: tint is int && tint >= 0 && tint <= 0xFFFFFFFF
          ? tint | 0xFF000000
          : 0xFF7C5CFF,
      iconSize: number('iconSize', 22, 18, 30),
      horizontalMargin: number('horizontalMargin', 3, 0, 40),
      safeGap: number('safeGap', -36, -100, 100),
      barHeight: value['barHeight'] == 0 ? 0 : number('barHeight', 85, 40, 120),
      materialOpacity: number('materialOpacity', .62, 0, 1),
      opaqueBackground: value['opaqueBackground'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NativeNavigationSettings &&
      enabled == other.enabled &&
      showLabels == other.showLabels &&
      solidIcons == other.solidIcons &&
      followThemeColor == other.followThemeColor &&
      tintColor == other.tintColor &&
      iconSize == other.iconSize &&
      horizontalMargin == other.horizontalMargin &&
      safeGap == other.safeGap &&
      barHeight == other.barHeight &&
      materialOpacity == other.materialOpacity &&
      opaqueBackground == other.opaqueBackground;

  @override
  int get hashCode => Object.hash(
    enabled,
    showLabels,
    solidIcons,
    followThemeColor,
    tintColor,
    iconSize,
    horizontalMargin,
    safeGap,
    barHeight,
    materialOpacity,
    opaqueBackground,
  );
}
