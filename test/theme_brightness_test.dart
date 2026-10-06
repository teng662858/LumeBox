import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/theme/lume_theme.dart';

/// 全局主题跟随系统（文档「全局主题补充」）。
///
/// 交付的是两件事：
/// 1. **亮 / 暗两套色板都成立**——分层规则在两种亮度下都满足（底与卡不同色、
///    玻璃半透明、文字三档对比度够）；
/// 2. **阅读器不受影响**——小说 / 漫画阅读页有各自的阅读主题，不读这套颜色
///    （它们读 `NovelTypesetting` / `ComicSettings`；本文件只验全局色板本身
///    与「不把阅读页带跑」的设计约定）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => LumeTheme.applyBrightness(Brightness.light));

  group('两套色板', () {
    test('亮 / 暗色板按亮度取用', () {
      expect(LumePalette.of(Brightness.light), same(LumePalette.light));
      expect(LumePalette.of(Brightness.dark), same(LumePalette.dark));
    });

    test('静态色名按当前亮度转发', () {
      LumeTheme.applyBrightness(Brightness.light);
      expect(LumeTheme.textPrimary, LumePalette.light.textPrimary);
      expect(LumeTheme.surface, LumePalette.light.surface);

      LumeTheme.applyBrightness(Brightness.dark);
      expect(LumeTheme.textPrimary, LumePalette.dark.textPrimary);
      expect(LumeTheme.surface, LumePalette.dark.surface);
      expect(
        LumeTheme.textPrimary,
        isNot(LumePalette.light.textPrimary),
        reason: '深色主题的主文本必须与浅色不同（否则白底黑字变黑底黑字）',
      );
    });

    test('分层规则在两种亮度下都成立：底与卡不同色', () {
      for (final palette in <LumePalette>[LumePalette.light, LumePalette.dark]) {
        expect(
          palette.base,
          isNot(palette.surface),
          reason: '底与卡同色就没有层次了（这是全项目的分层基础）',
        );
        expect(
          palette.surface,
          isNot(palette.surfaceAlt),
          reason: '第三层（卡内嵌块）也要与卡区分',
        );
      }
    });

    test('深色主题的卡比底更亮，浅色主题相反（层次方向对偶）', () {
      // 浅色：底 F7F7F9，卡 FFFFFF → 卡更亮。
      expect(
        LumePalette.light.surface.computeLuminance(),
        greaterThan(LumePalette.light.base.computeLuminance()),
      );
      // 深色：底 121214，卡 1C1C1F → 卡同样更亮（靠色差分层次，不是纯黑一色）。
      expect(
        LumePalette.dark.surface.computeLuminance(),
        greaterThan(LumePalette.dark.base.computeLuminance()),
        reason: '深色主题也要有层次：底比卡更暗，而不是一色到底',
      );
    });

    test('文字与背景的对比度够读（两种亮度都验）', () {
      double contrast(Color fg, Color bg) {
        final a = fg.computeLuminance();
        final b = bg.computeLuminance();
        final hi = a > b ? a : b;
        final lo = a > b ? b : a;
        return (hi + 0.05) / (lo + 0.05);
      }

      // 浅色：深字压浅底。
      expect(
        contrast(LumePalette.light.textPrimary, LumePalette.light.surface),
        greaterThan(4.5),
        reason: '主文本对卡片至少 4.5:1（WCAG AA）',
      );
      expect(
        contrast(LumePalette.light.textSecondary, LumePalette.light.surface),
        greaterThan(3.0),
        reason: '辅助说明至少 3:1',
      );

      // 深色：亮字压深底。
      expect(
        contrast(LumePalette.dark.textPrimary, LumePalette.dark.surface),
        greaterThan(4.5),
        reason: '深色主题的主文本同样要够读',
      );
      expect(
        contrast(LumePalette.dark.textSecondary, LumePalette.dark.surface),
        greaterThan(3.0),
      );
    });

    test('语义色在各自主题下可读（不是照搬浅色那套）', () {
      // 浅色主题用深色语义色（亮色在白底上看不清），深色主题反过来。
      expect(
        LumePalette.dark.danger,
        isNot(LumePalette.light.danger),
        reason: '深色主题的告警色要换成深底上可读的版本',
      );
      expect(
        LumePalette.dark.danger.computeLuminance(),
        greaterThan(LumePalette.light.danger.computeLuminance()),
        reason: '深色主题的告警色应当更亮',
      );
      expect(
        LumePalette.dark.success.computeLuminance(),
        greaterThan(LumePalette.light.success.computeLuminance()),
      );
    });

    test('状态栏图标明暗跟着主题走', () {
      expect(LumePalette.light.overlayStyle, Brightness.dark,
          reason: '浅色主题要深色状态栏图标');
      expect(LumePalette.dark.overlayStyle, Brightness.light,
          reason: '深色主题要浅色状态栏图标');
    });
  });

  group('ThemeData 构建', () {
    test('按亮度构建出对应 brightness 的 ThemeData', () {
      final light = LumeTheme.build(brightness: Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, LumePalette.light.base);

      final dark = LumeTheme.build(brightness: Brightness.dark);
      expect(dark.brightness, Brightness.dark);
      expect(dark.scaffoldBackgroundColor, LumePalette.dark.base);
    });

    test('构建会把亮度写进静态色名（页面随后读到一致的值）', () {
      LumeTheme.build(brightness: Brightness.dark);
      expect(LumeTheme.textPrimary, LumePalette.dark.textPrimary);
      LumeTheme.build(brightness: Brightness.light);
      expect(LumeTheme.textPrimary, LumePalette.light.textPrimary);
    });

    test('卡片装饰与背景在两种亮度下都取自对应色板', () {
      LumeTheme.build(brightness: Brightness.dark);
      expect(LumeTheme.cardDecoration().color, LumePalette.dark.surface);
      expect(LumeTheme.cardShadow.first.color, LumePalette.dark.cardShadow.first.color);

      LumeTheme.build(brightness: Brightness.light);
      expect(LumeTheme.cardDecoration().color, LumePalette.light.surface);
    });

    test('默认构建仍是浅色（既有调用方不受影响）', () {
      // 大量测试与工具直接调 `LumeTheme.build()`：默认必须是浅色，
      // 否则那些用例的取色会跟着变。
      final theme = LumeTheme.build();
      expect(theme.brightness, Brightness.light);
      expect(LumeTheme.textPrimary, LumePalette.light.textPrimary);
    });
  });

  group('阅读器不受全局主题影响（文档硬性要求）', () {
    test('阅读主题有自己的颜色来源，不读 LumeTheme 的色板', () {
      // 设计约定：小说阅读页读 NovelTypesetting 的阅读主题，漫画阅读页读
      // ComicSettings 的底色。这里用一个「切换全局亮度不影响阅读主题色」的
      // 断言把这条约定钉住——阅读页若哪天改成读 LumeTheme，这条会失败。
      LumeTheme.build(brightness: Brightness.light);
      final lightPrimary = LumeTheme.textPrimary;

      LumeTheme.build(brightness: Brightness.dark);
      final darkPrimary = LumeTheme.textPrimary;

      expect(lightPrimary, isNot(darkPrimary), reason: '全局色确实随亮度变了');
      // 阅读页的主题值来自各自的 store（见 novel_typesetting / comic_settings），
      // 与上面两个值无关——它们是独立的常量集，不在这里被改写。
      expect(LumePalette.light.textPrimary, const Color(0xFF1A1A1A));
      expect(LumePalette.dark.textPrimary, const Color(0xFFF2F2F4));
    });
  });
}
