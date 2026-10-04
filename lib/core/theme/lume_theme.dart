import 'package:flutter/material.dart';

/// 玻璃拟态主题。深色分层渐变底 + 半透明磨砂卡片。
class LumeTheme {
  LumeTheme._();

  /// App 内所有标题与页面文字统一使用项目名称。
  static const String appName = 'Lume Box';

  static const Color _seed = Color(0xFF7C5CFF);

  static ThemeData build() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0B0B12),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.4,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: Colors.white,
        iconColor: Colors.white70,
      ),
    );
  }

  /// 页面统一背景。
  static const BoxDecoration background = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        Color(0xFF161634),
        Color(0xFF0B0B12),
        Color(0xFF1D1038),
      ],
    ),
  );

  static const Color muted = Colors.white70;
}
