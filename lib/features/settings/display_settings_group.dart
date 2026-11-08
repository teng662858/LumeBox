import 'appearance_color_controls.dart';
import '../../shared/widgets/native_glass_controls.dart';

import 'package:flutter/material.dart';

import '../../shared/widgets/lume_icon.dart';

import '../../core/theme/appearance.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'custom_accent_picker.dart';
import 'settings_ui.dart';

class DisplaySettingsGroup extends StatelessWidget {
  const DisplaySettingsGroup({
    super.key,
    this.showTitle = true,
    this.includeFloating = false,
  });
  final bool showTitle, includeFloating;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppearanceController.instance,
    builder: (context, _) {
      final c = AppearanceController.instance;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle) const SettingsGroupTitle('外观与配色'),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('外观', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, box) => Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in ThemeMode.values)
                        ChoiceChip(
                          showCheckmark: false,
                          avatar: Icon(switch (mode) {
                            ThemeMode.system => Icons.brightness_auto_outlined,
                            ThemeMode.light => Icons.light_mode_outlined,
                            ThemeMode.dark => Icons.dark_mode_outlined,
                          }, size: 18),
                          label: Text(switch (mode) {
                            ThemeMode.system => '跟随系统',
                            ThemeMode.light => '浅色',
                            ThemeMode.dark => '深色',
                          }),
                          selected: c.mode == mode,
                          onSelected: (_) =>
                              c.apply(c.settings.copyWith(mode: mode)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _AppearancePreview(
                  background: LumeTheme.base,
                  accent: c.settings.accentColorFor(
                    Theme.of(context).brightness,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SettingsEntryCard(
            icon: Icons.palette_outlined,
            title: '主题色',
            subtitle: '色彩预览 · 预设色板 · 自定义颜色',
            trailingValue: c.settings.accentLabel,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AppearancePalettePage(),
              ),
            ),
          ),
          SettingsEntryCard(
            icon: Icons.format_color_fill_outlined,
            title: '页面底色',
            subtitle: '浅色与深色底色 · 自定义颜色',
            trailingValue: c.settings.lightBackgroundArgb != null
                ? '自定义'
                : c.settings.background == ThemeBackground.grouped
                ? '雾白'
                : '柔灰',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const AppearancePalettePage(backgroundOnly: true),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class AdaptiveColorSetting extends StatelessWidget {
  const AdaptiveColorSetting({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppearanceController.instance,
    builder: (context, _) => GlassCard(
      padding: EdgeInsets.zero,
      child: NativeSwitchListTile.adaptive(
        key: const Key('appearance.adaptiveColor'),
        title: const Text('自适应颜色'),
        subtitle: const Text('首页配色跟随推荐封面；无封面时使用主题色'),
        value: AppearanceController.instance.settings.adaptiveColor,
        onChanged: (v) => AppearanceController.instance.apply(
          AppearanceController.instance.settings.copyWith(adaptiveColor: v),
        ),
      ),
    ),
  );
}

class AppearancePalettePage extends StatelessWidget {
  const AppearancePalettePage({super.key, this.backgroundOnly = false});
  final bool backgroundOnly;
  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    behindBar: true,
    title: backgroundOnly ? '页面底色' : '主题色',
    child: ListenableBuilder(
      listenable: AppearanceController.instance,
      builder: (context, _) {
        final c = AppearanceController.instance;
        final accent = c.settings.accentColorFor(Theme.of(context).brightness);
        return ListView(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.fromLTRB(16, 20, 16, 32)),
          children: [
            SettingsPageIntro(
              title: backgroundOnly ? '让内容更舒适' : '选择你的色彩',
              description: backgroundOnly
                  ? '浅色和深色分别选底色，点选立即生效，也可保存整套配色。'
                  : '主题色用于选中状态与操作强调，预览会随选择更新。',
            ),
            _AppearancePreview(
              background: c.settings.backgroundColorFor(
                Theme.of(context).brightness,
              ),
              accent: accent,
            ),
            const SizedBox(height: 20),
            if (backgroundOnly) ...[
              const BackgroundColorControls(),
              const SizedBox(height: 12),
              for (final bg in ThemeBackground.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GlassCard(
                    onTap: () => c.apply(
                      c.settings.copyWith(
                        background: bg,
                        resetLightBackground: true,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: bg.color,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.black12),
                          ),
                          child: const Icon(
                            Icons.layers_outlined,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bg == ThemeBackground.grouped ? '雾白' : '柔灰',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                bg.label,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          c.settings.background == bg &&
                                  c.settings.lightBackgroundArgb == null
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color:
                              c.settings.background == bg &&
                                  c.settings.lightBackgroundArgb == null
                              ? LumeTheme.readableForeground(
                                  accent,
                                  LumeTheme.surface,
                                )
                              : LumeTheme.muted,
                        ),
                      ],
                    ),
                  ),
                ),
            ] else ...[
              LayoutBuilder(
                builder: (context, box) => GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: box.maxWidth < 360 ? 2 : 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.35,
                  children: [
                    for (final color in ThemeAccent.values)
                      GlassCard(
                        padding: const EdgeInsets.all(12),
                        onTap: () => c.apply(
                          c.settings.copyWith(
                            accent: color,
                            useCustomAccent: false,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              !c.settings.useCustomAccent && c.accent == color
                                  ? Icons.check_circle
                                  : Icons.circle,
                              color: color.colorFor(
                                Theme.of(context).brightness,
                              ),
                              size: 30,
                            ),
                            const SizedBox(height: 8),
                            Text(color.label),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SettingsEntryCard(
                icon: Icons.colorize_outlined,
                title: '自定义颜色',
                trailingValue: c.settings.useCustomAccent ? '使用中' : null,
                onTap: () async {
                  final value = await showCustomAccentPicker(
                    context,
                    Color(c.settings.customAccentArgb),
                  );
                  if (value != null) {
                    c.apply(
                      c.settings.copyWith(
                        customAccentArgb: value.toARGB32(),
                        useCustomAccent: true,
                      ),
                    );
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            const SavedAppearancePalettesCard(),
            const SettingsFooterNote('选择自动保存，无需再次确认。'),
          ],
        );
      },
    ),
  );
}

class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({required this.background, required this.accent});
  final Color background, accent;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: accent.withValues(alpha: .15)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '界面预览',
          style: TextStyle(
            color:
                ThemeData.estimateBrightnessForColor(background) ==
                    Brightness.dark
                ? Colors.white
                : Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .82),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome,
                color: LumeTheme.readableForeground(accent, Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('内容与灵感', style: TextStyle(color: Colors.black87)),
              ),
              Icon(
                Icons.check_circle,
                color: LumeTheme.readableForeground(accent, Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in ['推荐', '收藏', '发现'])
              Chip(
                label: Text(
                  label,
                  style: TextStyle(
                    color: LumeTheme.readableForeground(accent, Colors.white),
                  ),
                ),
                backgroundColor: accent.withValues(alpha: .09),
              ),
          ],
        ),
      ],
    ),
  );
}

class AccentDot extends StatelessWidget {
  const AccentDot({super.key, required this.color, this.size = 14});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: LumeTheme.cardShadow,
      ),
    );
  }
}

/// 通用选择弹窗：底部 Sheet + 一行一项 + 当前项打勾（主题色项多一个色块）。
///
/// 外观与主题色共用它；再往后的单选设置也可以直接复用，不必各写一个弹窗。
class OptionSheet<T> extends StatelessWidget {
  const OptionSheet({
    super.key,
    required this.title,
    required this.current,
    required this.options,
    required this.labelOf,
    this.swatchOf,
  });

  final String title;
  final T current;
  final List<T> options;
  final String Function(T option) labelOf;

  /// 可选的色块（主题色列表用它）。
  final Color Function(T option)? swatchOf;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Material(
        color: LumeTheme.base,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: interfaceFontWeight(context, FontWeight.w600),
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final option in options)
                      ListTile(
                        dense: true,
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            LumeIcon(
                              option == current
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              slot: 'display_settings_group.4',
                              variant: true,
                              size: 20,
                              color: option == current
                                  ? LumeTheme.accent
                                  : LumeTheme.muted,
                            ),
                            if (swatchOf != null) ...<Widget>[
                              const SizedBox(width: 12),
                              AccentDot(color: swatchOf!(option)),
                            ],
                          ],
                        ),
                        title: Text(
                          labelOf(option),
                          style: TextStyle(
                            fontWeight: interfaceFontWeight(
                              context,
                              FontWeight.w600,
                            ),
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(option),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
