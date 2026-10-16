import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';

/// 全局主题色板：**浅色与深色两套值**，由 [LumeTheme.of] 按当前亮度取用。
///
/// ## 为什么是「色板对象 + 静态转发」而不是直接换成 ThemeExtension
///
/// 全仓库有 300 多处 `LumeTheme.textPrimary` 这类引用，其中 78 处写在 `const`
/// 构造里。若把它们逐个改成 `Theme.of(context).extension<...>()`，改动面覆盖
/// 每个页面，且每处都要处理 const 展开——风险远大于收益。这里的做法是：
///
/// - 颜色值收进 [LumePalette]（浅色 / 深色两套）；
/// - [LumeTheme] 保留原来的静态名，**按当前生效亮度转发**到对应色板；
/// - 亮度由 [LumeTheme.applyBrightness] 在 MaterialApp 构建时写入（见 `app.dart`）。
///
/// 代价是「颜色读取依赖一个进程级当前亮度」，因此有一条硬约束：
/// **必须在使用前设置亮度**（`LumeTheme.build()` 内部会按传入的 brightness
/// 设定）。阅读器不读这套颜色（见下），所以不存在「阅读页被全局主题带跑」的问题。
///
/// ## 阅读器为什么不在这里
///
/// 小说阅读页有自己的一套阅读主题（羊皮纸 / 夜间深灰 / 护眼绿 / 纯白 / 自定义），
/// 漫画阅读页的底色由阅读设置决定——两者都**不受全局主题控制**（文档要求）。
/// 它们读的是 `NovelTypesetting` / `ComicSettings` 里的颜色，与本文件无关。
class LumePalette {
  const LumePalette({
    required this.brightness,
    required this.accent,
    required this.base,
    required this.surface,
    required this.surfaceAlt,
    required this.glass,
    required this.glassStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHint,
    required this.divider,
    required this.hairline,
    required this.fill,
    required this.fillStrong,
    required this.success,
    required this.danger,
    required this.warning,
    required this.info,
    required this.cardShadow,
    required this.floatShadow,
    required this.backgroundGradient,
    required this.overlayStyle,
    required this.snackBar,
    required this.onAccent,
  });

  /// 这套色板属于哪种亮度（主题色提亮要用它）。
  final Brightness brightness;

  final Color accent;
  final Color base;
  final Color surface;
  final Color surfaceAlt;
  final Color glass;
  final Color glassStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textHint;
  final Color divider;
  final Color hairline;
  final Color fill;
  final Color fillStrong;
  final Color success;
  final Color danger;
  final Color warning;
  final Color info;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatShadow;
  final List<Color> backgroundGradient;

  /// 状态栏图标明暗（浅色主题要深色图标，反之亦然）。
  final Brightness overlayStyle;

  /// 深色条：SnackBar 在两种主题下都用它（两种底上都能读）。
  final Color snackBar;

  /// 品牌紫上的前景色（按钮文字 / 选中芯片文字）。
  final Color onAccent;

  /// 浅色主题：极浅分层底 + 白卡。
  static const LumePalette light = LumePalette(
    brightness: Brightness.light,
    accent: Color(0xFF7C5CFF),
    base: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF5F5F7),
    glass: Color(0xB8FFFFFF),
    glassStrong: Color(0xD9FFFFFF),
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF263449),
    textHint: Color(0xFF334158),
    divider: Color(0x00000000),
    hairline: Color(0x00000000),
    fill: Color(0x0A000000),
    fillStrong: Color(0x14000000),
    success: Color(0xFF2E7D4F),
    danger: Color(0xFFC0392B),
    warning: Color(0xFFB26A00),
    info: Color(0xFF2F6FB5),
    cardShadow: <BoxShadow>[
      BoxShadow(color: Color(0x10000000), blurRadius: 24, offset: Offset(0, 6)),
    ],
    floatShadow: <BoxShadow>[
      BoxShadow(color: Color(0x18000000), blurRadius: 24, offset: Offset(0, 8)),
      BoxShadow(color: Color(0x0A1A1A1A), blurRadius: 6, offset: Offset(0, 2)),
    ],
    backgroundGradient: <Color>[Colors.white, Colors.white],
    overlayStyle: Brightness.dark,
    snackBar: Color(0xF21A1A22),
    onAccent: Colors.white,
  );

  /// 深色主题：分层同样成立——**底比卡更暗**，靠色差分层次（不是纯黑一色到底）。
  ///
  /// 取值与浅色主题对偶：浅色是「极浅底 + 纯白卡」，深色是「近黑底 + 稍亮卡」；
  /// 玻璃改成半透明深色，文字三档整体反转；语义色换成深底上可读的**亮色版本**
  /// （浅色那套深色语义色在深底上看不清，正是浅色主题当初反过来的理由）。
  static const LumePalette dark = LumePalette(
    brightness: Brightness.dark,
    accent: Color(0xFF9B84FF),
    base: Color(0xFF121214),
    surface: Color(0xFF242427),
    surfaceAlt: Color(0xFF303034),
    glass: Color(0xB8242427),
    glassStrong: Color(0xD9242427),
    textPrimary: Color(0xFFF2F2F4),
    textSecondary: Color(0xFFE4EBF5),
    textHint: Color(0xFFD6E0EE),
    divider: Color(0x00000000),
    hairline: Color(0x00000000),
    fill: Color(0x0FFFFFFF),
    fillStrong: Color(0x1FFFFFFF),
    success: Color(0xFF5FBF85),
    danger: Color(0xFFEF6F62),
    warning: Color(0xFFE0A24C),
    info: Color(0xFF6FA8E8),
    cardShadow: <BoxShadow>[
      BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 6)),
    ],
    floatShadow: <BoxShadow>[
      BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8)),
      BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
    ],
    backgroundGradient: <Color>[Color(0xFF121214), Color(0xFF121214)],
    overlayStyle: Brightness.light,
    snackBar: Color(0xF22E2E36),
    onAccent: Color(0xFF1A1030),
  );

  /// 按亮度取色板。
  static LumePalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 换一套主题色的副本：**结构与两套固定色板完全一致，只替换 [accent]**
  /// （连同它衍生出的选中态、进度条、芯片等——那些都读 `LumeTheme.accent`）。
  ///
  /// 为什么不做「按主色重新推导整套色板」：对比度与分层规则是逐值调过的，
  /// 由主色算法推导出来的底色/文字色在 11 种颜色下未必都够读。锁住结构、
  /// 只换主色，是「换主题色不牺牲可读性」的稳妥做法。
  LumePalette withAccent(
    ThemeAccent accent, {
    ThemeBackground background = ThemeBackground.white,
  }) => LumePalette(
    brightness: brightness,
    accent: LumeTheme.readableForeground(
      accent.colorFor(brightness),
      surfaceAlt,
    ),
    base: brightness == Brightness.light ? background.color : base,
    surface: surface,
    surfaceAlt: surfaceAlt,
    glass: glass,
    glassStrong: glassStrong,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    textHint: textHint,
    divider: divider,
    hairline: hairline,
    fill: fill,
    fillStrong: fillStrong,
    success: success,
    danger: danger,
    warning: warning,
    info: info,
    cardShadow: cardShadow,
    floatShadow: floatShadow,
    backgroundGradient: backgroundGradient,
    overlayStyle: overlayStyle,
    snackBar: snackBar,
    onAccent: onAccent,
  );
}

/// 全局主题：分层底 + 清透玻璃 + 极淡阴影，**浅色与深色两套**。
///
/// 三条分层规则（其它颜色都是它们的派生，两套主题都成立）：
/// 1. **底与卡不同色**——页面最底层是 [base]，卡片是 [surface]，靠微弱色差分出
///    第一层；页面背景另带一层几乎看不见的渐变，避免大色块死板；
/// 2. **玻璃只给「浮在内容之上」的条**——顶部栏 / 底部导航 / 覆盖面板走
///    [glass] 的透明底色（见 `GlassPanel`），滚动内容从下面透出来；
/// 3. **卡片靠阴影而不是描边浮起**——[cardShadow] 透明度极低，只做「轻微浮起」。
///
/// 文字三档：[textPrimary] / [textSecondary] / [textHint]；装饰与交互元素一律用
/// 低饱和品牌紫 [accent]。
///
/// **阅读器不属于这里**：小说阅读页有自己的一套阅读主题（浅色 / 暗色 / 护眼等），
/// 漫画阅读页的底色与工具栏也由阅读设置决定，两者都不读本文件的颜色。
///
/// ## 当前亮度从哪来
///
/// 静态色名（[textPrimary] 等）按 [_brightness] 转发，而它由 [build] 设定——
/// `MaterialApp` 构建时先调 `LumeTheme.build(brightness: ...)`，页面随后构建，
/// 因此读取时拿到的总是与当前主题一致的色板。这是「保住 300 处静态引用、
/// 不逐个改 ThemeExtension」的代价，约束写在 [LumePalette] 的文档里。
class LumeTheme {
  LumeTheme._();

  static const chipIdleBackground = Color(0xFFF2F2F7);
  static const chipIdleForeground = Color(0xFF333333);
  static const chipSelectedBackground = Color(0xFF6C5CE7);

  /// RawChip resolves stateful Color after merging TextStyle, not TextStyle itself.
  static TextStyle get chipLabelStyle => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? Colors.white
          : chipIdleForeground,
    ),
  );

  /// App 内所有标题与页面文字统一使用项目名称。
  static const String appName = 'Lume Box';

  /// 当前生效亮度。由 [build] 写入；默认浅色（未设定时的历史行为）。
  static Brightness _brightness = Brightness.light;

  /// 当前生效主题色（设置页「显示 → 主题色」写入，见 `appearance.dart`）。
  static ThemeAccent _accent = ThemeAccent.fallback;
  static ThemeBackground _background = ThemeBackground.white;
  static void applyBackground(ThemeBackground value) => _background = value;

  /// 当前生效色板：亮度定结构、主题色定主色。
  static LumePalette get palette =>
      LumePalette.of(_brightness).withAccent(_accent, background: _background);

  /// 按亮度取色板（供需要显式区分的场合，如阅读页的工具栏）。
  static LumePalette paletteOf(Brightness brightness) =>
      LumePalette.of(brightness);

  /// 显式设定当前亮度（[build] 会调；测试也可直接调来验深色）。
  static void applyBrightness(Brightness brightness) {
    _brightness = brightness;
  }

  /// 显式设定主题色（[build] 会调）。
  static void applyAccent(ThemeAccent accent) {
    _accent = accent;
  }

  /// 当前主题身份（亮度 + 主题色）。
  ///
  /// **用途只有一个：给「换主题就整体重建」的子树当 key**（见
  /// `AppShell._buildPage`）。为什么需要它：本文件的色名是**进程级静态值**
  /// （保住了全仓库大量 `LumeTheme.textPrimary` 这类引用），它们不会随
  /// `ThemeData` 变化自动生效——依赖 `Theme.of(context)` 的部件会重建，只读
  /// 静态色名的部件不会。而给 `MaterialApp.builder` 里那层 `KeyedSubtree`
  /// 换 key **重建不了子树**：`child` 是带 GlobalKey 的 Navigator，换 key 只会
  /// 把它换个位置、子树原样复用（实测，见 settings_page_test 的深色用例）。
  static String get themeId =>
      '${_brightness.name}-${_accent.id}-${_background.id}';

  // ------------------------------------------------------------------ 色板

  /// 品牌紫（低饱和）：按钮、高亮、交互元素专用。
  static Color get accent => palette.accent;

  /// 页面最底层。
  static Color get base => palette.base;

  /// 卡片：与底色区分出的第一层。
  static Color get surface => palette.surface;

  /// 卡内嵌块 / 次级面板：第三层。
  static Color get surfaceAlt => palette.surfaceAlt;

  /// 玻璃层底色：低透明度（顶栏 / 底栏 / 覆盖面板），保留背景清晰。
  static Color get glass => palette.glass;

  /// 玻璃层上更实一点（在图片 / 视频之上需要更强可读性的面板）。
  static Color get glassStrong => palette.glassStrong;

  /// 主文本。
  static Color get textPrimary => palette.textPrimary;

  /// 辅助说明。
  static Color get textSecondary => palette.textSecondary;

  /// 占位提示。
  static Color get textHint => palette.textHint;

  /// 旧名兼容：全仓库大量使用 `LumeTheme.muted` 作辅助说明色。
  static Color get muted => textSecondary;

  /// 极浅分隔线：替代硬横线，能不用就不用（优先靠间距分层）。
  static Color get divider => palette.divider;

  /// 极浅描边：卡片在底上的边界。
  static Color get hairline => palette.hairline;

  /// 极浅填充：芯片 / 内嵌块 / 未选中段。
  static Color get fill => palette.fill;

  /// 稍重一点的填充（选中态底座、进度条槽）。
  static Color get fillStrong => palette.fillStrong;

  /// 品牌紫上的前景色。
  static Color get onAccent => palette.onAccent;

  /// 语义色：各自主题下可读的版本（浅色用深色版，深色用亮色版）。
  static Color get success =>
      readableForeground(palette.success, palette.surfaceAlt);
  static Color get danger =>
      readableForeground(palette.danger, palette.surfaceAlt);
  static Color get warning =>
      readableForeground(palette.warning, palette.surfaceAlt);
  static Color get info => readableForeground(palette.info, palette.surfaceAlt);

  // ------------------------------------------------------------------ 阴影

  /// 卡片阴影：极柔和，只做出「轻微浮起」。
  static List<BoxShadow> get cardShadow => palette.cardShadow;

  /// 浮得更高一档的阴影（底部导航这种悬在内容之上的元素）。
  static List<BoxShadow> get floatShadow => palette.floatShadow;

  /// 卡片的标准装饰。
  static BoxDecoration cardDecoration({double radius = 16}) {
    return BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: cardShadow,
    );
  }

  // ------------------------------------------------------------------ 背景

  /// 页面统一纯色背景：亮色纯白，暗色深灰。
  static BoxDecoration get background => BoxDecoration(color: base);

  // ------------------------------------------------------------------ 主题

  static double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
  }

  /// Preserve the chosen hue while making small colored labels readable too.
  static Color readableForeground(Color color, Color background) {
    final target = background.computeLuminance() > .4
        ? Colors.black
        : Colors.white;
    for (var step = 0; step <= 32; step++) {
      final candidate = Color.lerp(color, target, step / 32)!;
      if (contrast(candidate, background) >= 4.5) return candidate;
    }
    return target;
  }

  static Color readableGlass(Color color) =>
      color.withValues(alpha: color.a.clamp(.60, .88));

  /// Shared UI typography. Keep OS accessibility scaling unchanged.
  static TextTheme readableTextTheme(Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
    ).textTheme;
    final palette = LumePalette.of(brightness);
    final expanded = base.apply(
      bodyColor: palette.textPrimary,
      displayColor: palette.textPrimary,
    );
    TextStyle? strong(TextStyle? style) => style?.copyWith(
      fontSize: (style.fontSize ?? 14) + 1,
      fontWeight: FontWeight.w600,
    );
    return expanded.copyWith(
      displayLarge: strong(expanded.displayLarge),
      displayMedium: strong(expanded.displayMedium),
      displaySmall: strong(expanded.displaySmall),
      headlineLarge: strong(expanded.headlineLarge),
      headlineMedium: strong(expanded.headlineMedium),
      headlineSmall: strong(expanded.headlineSmall),
      titleLarge: strong(expanded.titleLarge),
      titleMedium: strong(expanded.titleMedium),
      titleSmall: strong(expanded.titleSmall),
      bodyLarge: strong(expanded.bodyLarge),
      bodyMedium: strong(expanded.bodyMedium),
      bodySmall: strong(expanded.bodySmall),
      labelLarge: strong(expanded.labelLarge),
      labelMedium: strong(expanded.labelMedium),
      labelSmall: strong(expanded.labelSmall),
    );
  }

  /// 构建主题。[brightness] 决定用哪套色板，[accent] 决定主色。
  static ThemeData build({
    Brightness brightness = Brightness.light,
    ThemeAccent accent = ThemeAccent.fallback,
    ThemeBackground background = ThemeBackground.white,
  }) {
    applyBrightness(brightness);
    applyAccent(accent);
    applyBackground(background);
    // 局部别名：下面所有裸 `accent` 要的都是**颜色**，而参数是档位。
    final accentColor = palette.accent;
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: brightness,
        ).copyWith(
          primary: accentColor,
          onPrimary: onAccent,
          surface: surface,
          onSurface: textPrimary,
          onSurfaceVariant: textSecondary,
          outline: hairline,
          outlineVariant: divider,
          error: danger,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: base,
      canvasColor: surface,
      dividerColor: divider,
      disabledColor: textSecondary,
      dividerTheme: DividerThemeData(color: divider, thickness: 1, space: 1),
      splashColor: accentColor.withValues(alpha: 0.06),
      highlightColor: accentColor.withValues(alpha: 0.04),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        // 状态栏图标明暗跟着主题走（深色主题要浅色图标，否则看不见）。
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: textPrimary),
        actionsIconTheme: IconThemeData(color: textPrimary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 12,
        shadowColor: palette.floatShadow.first.color,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        contentTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: textSecondary,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface,
        elevation: 12,
        shadowColor: palette.floatShadow.first.color,
        modalBarrierColor: isDark
            ? const Color(0x99000000)
            : const Color(0x33101018),
      ),
      listTileTheme: ListTileThemeData(
        textColor: textPrimary,
        iconColor: textPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
      ),
      textTheme: readableTextTheme(brightness),
      primaryTextTheme: readableTextTheme(brightness)
          .apply(bodyColor: onAccent, displayColor: onAccent),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: palette.cardShadow.first.color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
      ),
      iconTheme: IconThemeData(color: textPrimary),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accentColor),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentColor,
        thumbColor: accentColor,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? onAccent : surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accentColor : fillStrong,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accentColor : hairline,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentColor,
          disabledForegroundColor: textPrimary,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: onAccent,
          disabledForegroundColor: textPrimary,
          disabledBackgroundColor: surfaceAlt,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accentColor,
          disabledForegroundColor: textPrimary,
          side: BorderSide.none,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: chipIdleBackground,
        selectedColor: chipSelectedBackground,
        color: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? chipSelectedBackground
              : chipIdleBackground,
        ),
        side: BorderSide.none,
        labelStyle: chipLabelStyle,
        secondaryLabelStyle: chipLabelStyle,
        checkmarkColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        hintStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: textHint,
          fontSize: 15,
        ),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: textSecondary,
          fontSize: 15,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accentColor, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.snackBar,
        contentTextStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          color: Colors.white,
          fontSize: 14,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: textPrimary,
          fontSize: 15,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accentColor
                : textSecondary,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? fill : surface,
          ),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: hairline)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: accentColor,
        unselectedLabelColor: textSecondary,
        dividerColor: Colors.transparent,
        indicatorColor: accentColor,
      ),
    );
  }
}
