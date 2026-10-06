import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局浅色主题：分层底 + 玻璃磨砂 + 极淡阴影。
///
/// 三条分层规则（其它颜色都是它们的派生）：
/// 1. **底与卡不同色**——页面最底层是极浅米灰 [base]，卡片是纯白 [surface]，
///    靠微弱色差分出第一层；页面背景另带一层几乎看不见的渐变，避免大色块死板；
/// 2. **玻璃只给「浮在内容之上」的条**——顶部栏 / 底部导航 / 覆盖面板走
///    [glass] + 模糊（见 `GlassPanel`），滚动内容从下面透出来；
/// 3. **卡片靠阴影而不是描边浮起**——[cardShadow] 透明度极低，只做「轻微浮起」。
///
/// 文字三档：[textPrimary] / [textSecondary] / [textHint]；装饰与交互元素一律用
/// 低饱和品牌紫 [accent]——纯白不再充当文字色（浅底上会看不见）。
///
/// **阅读器不属于这里**：小说阅读页有自己的一套阅读主题（浅色 / 暗色 / 护眼等），
/// 漫画阅读页的底色与工具栏也由阅读设置决定，两者都不读本文件的颜色。
class LumeTheme {
  LumeTheme._();

  /// App 内所有标题与页面文字统一使用项目名称。
  static const String appName = 'Lume Box';

  // ------------------------------------------------------------------ 色板

  /// 品牌紫（低饱和）：按钮、高亮、交互元素专用。
  static const Color accent = Color(0xFF7C5CFF);

  /// 页面最底层：极浅米灰。
  static const Color base = Color(0xFFF7F7F9);

  /// 卡片：比底色更白，第一层层次由此分出。
  static const Color surface = Color(0xFFFFFFFF);

  /// 卡内嵌块 / 次级面板：比卡片略灰、比底色略白，第三层。
  static const Color surfaceAlt = Color(0xFFFBFBFC);

  /// 玻璃层底色：半透明白（顶栏 / 底栏 / 覆盖面板），叠加模糊成磨砂。
  static const Color glass = Color(0xB8FFFFFF);

  /// 玻璃层上更实一点的白（在图片 / 视频之上需要更强可读性的面板）。
  static const Color glassStrong = Color(0xE0FFFFFF);

  /// 主文本。
  static const Color textPrimary = Color(0xFF1A1A1A);

  /// 辅助说明。
  static const Color textSecondary = Color(0xFF707076);

  /// 占位提示。
  static const Color textHint = Color(0xFF99999F);

  /// 旧名兼容：全仓库大量使用 `LumeTheme.muted` 作辅助说明色。
  static const Color muted = textSecondary;

  /// 极浅分隔线：替代硬横线，能不用就不用（优先靠间距分层）。
  static const Color divider = Color(0x12000000);

  /// 极浅描边：白卡在浅底上的边界。
  static const Color hairline = Color(0x14000000);

  /// 极浅填充：芯片 / 内嵌块 / 未选中段。
  static const Color fill = Color(0x0A000000);

  /// 稍重一点的填充（选中态底座、进度条槽）。
  static const Color fillStrong = Color(0x14000000);

  /// 语义色：浅底上可读的深色版本（原来的亮色系在白底上看不清）。
  static const Color success = Color(0xFF2E7D4F);
  static const Color danger = Color(0xFFC0392B);
  static const Color warning = Color(0xFFB26A00);
  static const Color info = Color(0xFF2F6FB5);

  // ------------------------------------------------------------------ 阴影

  /// 卡片阴影：极柔和，只做出「轻微浮起」。
  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x0D1A1A1A),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// 浮得更高一档的阴影（底部导航这种悬在内容之上的元素）。
  static const List<BoxShadow> floatShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x141A1A1A),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
    BoxShadow(
      color: Color(0x0A1A1A1A),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
  ];

  /// 卡片的标准装饰：纯白 + 极浅描边 + 柔和阴影。
  static BoxDecoration cardDecoration({double radius = 16}) {
    return BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: hairline),
      boxShadow: cardShadow,
    );
  }

  // ------------------------------------------------------------------ 背景

  /// 页面统一背景：极浅米灰，带一层几乎看不见的渐变（避免大色块死板）。
  static const BoxDecoration background = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[
        Color(0xFFF9F9FB),
        Color(0xFFF5F5F8),
      ],
    ),
  );

  // ------------------------------------------------------------------ 主题

  static ThemeData build() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      primary: accent,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: hairline,
      outlineVariant: divider,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: base,
      canvasColor: surface,
      dividerColor: divider,
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),
      splashColor: accent.withValues(alpha: 0.06),
      highlightColor: accent.withValues(alpha: 0.04),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: textPrimary),
        actionsIconTheme: IconThemeData(color: textPrimary),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: textSecondary),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface,
        modalBarrierColor: Color(0x33101018),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textSecondary,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: textPrimary),
        titleMedium: TextStyle(color: textPrimary),
        titleSmall: TextStyle(color: textPrimary),
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textPrimary),
        bodySmall: TextStyle(color: textSecondary),
        labelLarge: TextStyle(color: textPrimary),
      ),
      iconTheme: const IconThemeData(color: textPrimary),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : surface),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? accent : fillStrong),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? accent : hairline),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: const BorderSide(color: hairline),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: surfaceAlt,
        selectedColor: accent,
        side: BorderSide(color: hairline),
        labelStyle: TextStyle(color: textPrimary, fontSize: 12),
        secondaryLabelStyle: TextStyle(color: Colors.white, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        hintStyle: const TextStyle(color: textHint, fontSize: 14),
        labelStyle: const TextStyle(color: textSecondary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xF21A1A22),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: textPrimary, fontSize: 14),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? accent : textSecondary),
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? fill : surface),
          side: const WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: hairline),
          ),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: textSecondary,
        dividerColor: Colors.transparent,
        indicatorColor: accent,
      ),
    );
  }
}
