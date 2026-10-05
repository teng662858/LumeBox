import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';

/// 小说排版参数：字号、行间距、段间距、页边距。
///
/// 只描述「字怎么排」，不含任何颜色——颜色属于 [NovelReaderTheme]。分开的好处是
/// 换主题不需要重新分页（分页只依赖几何），换排版才需要。
class NovelTypesetting {
  const NovelTypesetting({
    this.fontSize = 17,
    this.lineHeight = 1.75,
    this.paragraphSpacing = 8,
    this.margin = 18,
    this.fontFamily,
  });

  // 可调范围：上下限都在这里收口，UI 只读常量，不各自写数字。
  static const double minFontSize = 12;
  static const double maxFontSize = 30;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.6;
  static const double minParagraphSpacing = 0;
  static const double maxParagraphSpacing = 28;
  static const double minMargin = 0;
  static const double maxMargin = 48;

  /// 页眉（章名）与页脚（页码）的固定高度：正文可用高度 = 视口高 - 页边距 - 这两块。
  static const double headerHeight = 22;
  static const double footerHeight = 26;

  static const String settingKey = 'novel.typesetting';

  /// 自动翻页间隔（秒）的设置键；与排版参数分开存（它不是排版）。
  static const String autoPageKey = 'novel.reader.autoPageSeconds';

  final double fontSize;

  /// 行高倍数（相对字号）。
  final double lineHeight;

  /// 段间距（逻辑像素）。页首不加，避免页顶空一截。
  final double paragraphSpacing;

  /// 页边距（四边相同）。
  final double margin;

  final String? fontFamily;

  /// 用于测量的基础样式（不含颜色）。
  TextStyle get baseStyle => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        fontFamily: fontFamily,
        leadingDistribution: TextLeadingDistribution.even,
      );

  /// 正文内容区（视口内扣除页边距与页眉页脚后的矩形尺寸）。
  ///
  /// [reserveChrome] 为 false 时不预留页眉页脚：连续滚动模式没有页眉页脚，
  /// 正文会铺满整屏，页与页才能无缝相接。
  Size contentSize(Size viewport, {bool reserveChrome = true}) => Size(
        (viewport.width - margin * 2).clamp(1, double.infinity),
        (viewport.height -
                margin * 2 -
                (reserveChrome ? headerHeight + footerHeight : 0))
            .clamp(1, double.infinity),
      );

  /// 分页签名：几何参数一变，缓存必须失效。
  String get signature => <String>[
        fontSize.toStringAsFixed(2),
        lineHeight.toStringAsFixed(3),
        paragraphSpacing.toStringAsFixed(2),
        margin.toStringAsFixed(2),
        fontFamily ?? '',
      ].join('|');

  NovelTypesetting copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? margin,
  }) {
    return NovelTypesetting(
      fontSize: (fontSize ?? this.fontSize)
          .clamp(minFontSize, maxFontSize)
          .toDouble(),
      lineHeight: (lineHeight ?? this.lineHeight)
          .clamp(minLineHeight, maxLineHeight)
          .toDouble(),
      paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing)
          .clamp(minParagraphSpacing, maxParagraphSpacing)
          .toDouble(),
      margin:
          (margin ?? this.margin).clamp(minMargin, maxMargin).toDouble(),
      fontFamily: fontFamily,
    );
  }

  String encode() => jsonEncode(<String, Object?>{
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paragraphSpacing': paragraphSpacing,
        'margin': margin,
      });

  static NovelTypesetting decode(String? raw) {
    if (raw == null || raw.isEmpty) return const NovelTypesetting();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const NovelTypesetting();
      final base = const NovelTypesetting();
      return base.copyWith(
        fontSize: _number(decoded['fontSize'], base.fontSize),
        lineHeight: _number(decoded['lineHeight'], base.lineHeight),
        paragraphSpacing:
            _number(decoded['paragraphSpacing'], base.paragraphSpacing),
        margin: _number(decoded['margin'], base.margin),
      );
    } on FormatException {
      return const NovelTypesetting();
    }
  }

  static double _number(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;
}

/// 小说阅读主题：**独立于 App 全局主题**。
///
/// 阅读器整页（背景、正文、页眉页脚、工具栏）都按这里的颜色走，因此在浅色
/// 羊皮纸主题下不会出现深色 App 的残留；反过来 App 换成任何主题，阅读体验
/// 也不受影响。自定义背景按亮度自动选文字色，保证可读性。
class NovelReaderTheme {
  const NovelReaderTheme({
    required this.id,
    required this.label,
    required this.background,
    required this.textColor,
  });

  static const NovelReaderTheme parchment = NovelReaderTheme(
    id: 'parchment',
    label: '羊皮纸',
    background: Color(0xFFF3E9D2),
    textColor: Color(0xFF3A2E1F),
  );

  static const NovelReaderTheme night = NovelReaderTheme(
    id: 'night',
    label: '夜间深灰',
    background: Color(0xFF1B1B20),
    textColor: Color(0xFFB6B6BE),
  );

  static const NovelReaderTheme eyeCare = NovelReaderTheme(
    id: 'eyeCare',
    label: '护眼绿',
    background: Color(0xFFCFE8D2),
    textColor: Color(0xFF23352A),
  );

  static const NovelReaderTheme white = NovelReaderTheme(
    id: 'white',
    label: '纯白',
    background: Color(0xFFFFFFFF),
    textColor: Color(0xFF1A1A1A),
  );

  static const List<NovelReaderTheme> presets = <NovelReaderTheme>[
    parchment,
    night,
    eyeCare,
    white,
  ];

  static const String customId = 'custom';

  static const String keyThemeId = 'novel.theme.id';
  static const String keyThemeColor = 'novel.theme.color';

  final String id;
  final String label;
  final Color background;
  final Color textColor;

  bool get isCustom => id == customId;

  /// 自定义背景主题：文字色按背景亮度自动选，避免浅底浅字。
  factory NovelReaderTheme.custom(Color background) => NovelReaderTheme(
        id: customId,
        label: '自定义',
        background: background,
        textColor: background.computeLuminance() > 0.5
            ? const Color(0xFF1A1A1A)
            : const Color(0xFFE2E2E6),
      );

  /// 次要文字（页眉页脚、进度）。
  Color get secondary => textColor.withValues(alpha: 0.55);

  /// 分隔线与细边。
  Color get divider => textColor.withValues(alpha: 0.14);

  /// 本主题下「像背景一样深/浅」的工具栏表面色。
  Color get chromeSurface => background.computeLuminance() > 0.5
      ? const Color(0xF2FFFFFF)
      : const Color(0xF21B1B20);

  /// 工具栏上的主文字色（与正文同向对比）。
  Color get chromeText => background.computeLuminance() > 0.5
      ? const Color(0xFF1A1A1A)
      : const Color(0xFFEDEDF0);

  /// 按 id 取主题；自定义主题需要提供背景色。
  static NovelReaderTheme fromId(String? id, {Color? customBackground}) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    if (id == customId && customBackground != null) {
      return NovelReaderTheme.custom(customBackground);
    }
    return parchment;
  }

  /// 从板块阅读库读主题（键落在本板块，小说与漫画各存各的）。
  static NovelReaderTheme load(ReadingLibrary library) {
    final id = library.setting(keyThemeId);
    final rawColor = library.setting(keyThemeColor);
    Color? custom;
    if (rawColor != null) {
      final value = int.tryParse(rawColor);
      if (value != null) custom = Color(value);
    }
    return fromId(id, customBackground: custom);
  }

  /// 写回板块阅读库。
  void save(ReadingLibrary library) {
    library.setSetting(keyThemeId, id);
    if (isCustom) {
      library.setSetting(keyThemeColor, background.toARGB32().toString());
    }
  }
}
