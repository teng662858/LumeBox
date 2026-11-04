import '../../shared/widgets/native_glass_controls.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock_bar.dart';
import '../shell/system_dock_bar.dart';
import 'settings_ui.dart';
import 'tab_bar_settings_page.dart';

class NativeNavigationSettingsPage extends StatelessWidget {
  const NativeNavigationSettingsPage({
    super.key,
    required this.controller,
    required this.entries,
  });

  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '原生系统导航',
    effectModule: GlassModule.settings,
    behindBar: true,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: [
          NativeNavigationSettingsCard(
            controller: controller,
            entries: entries,
          ),
        ],
      ),
    ),
  );
}

class NativeNavigationSettingsCard extends StatefulWidget {
  const NativeNavigationSettingsCard({
    super.key,
    required this.controller,
    required this.entries,
  });

  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  State<NativeNavigationSettingsCard> createState() =>
      _NativeNavigationSettingsCardState();
}

class _NativeNavigationSettingsCardState
    extends State<NativeNavigationSettingsCard> {
  late final _capabilities = SystemTabBarCapabilities.load();
  double? _previewHeight;
  String? _previewId;
  bool _previewAvailable = true;
  bool _advanced = false;

  NativeNavigationSettings get settings =>
      widget.controller.settings.nativeNavigation;

  void _change(NativeNavigationSettings value, {bool save = true}) {
    widget.controller.updateNativeNavigation(value);
    if (save) unawaited(widget.controller.saveNativeNavigation());
  }

  @override
  Widget build(BuildContext context) => GlassCard(
    radius: 14,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '原生系统导航',
          style: TextStyle(
            fontSize: LumeTypography.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        NativeSwitchListTile.adaptive(
          key: const ValueKey('native-navigation-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('使用系统导航栏'),
          subtitle: const Text('使用 iOS 26 原生液态玻璃，下方可调整胶囊高度和位置。'),
          value: settings.enabled,
          onChanged: (value) => _change(settings.copyWith(enabled: value)),
        ),
        NativeSwitchListTile.adaptive(
          key: const ValueKey('navigation-solid-icons'),
          contentPadding: EdgeInsets.zero,
          title: const Text('黑色实心图标'),
          subtitle: const Text('未选中为黑色实心（深色模式为白色），选中时跟随主题色。'),
          value: settings.solidIcons,
          onChanged: (value) => _change(settings.copyWith(solidIcons: value)),
        ),
        if (!settings.enabled) ...[
          const SettingsFooterNote('当前使用兼容布局；开启后可调原生导航栏的高度和位置。'),
          DockAppearancePreview(
            appearance: widget.controller.appearance,
            solidIcons: settings.solidIcons,
            entries: widget.entries,
            maxHeight: 200,
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ActionChip(
              label: const Text('标准玻璃'),
              onPressed: () => _change(
                settings.copyWith(
                  barHeight: 85,
                  horizontalMargin: 3,
                  safeGap: -36,
                  iconSize: 22,
                  materialOpacity: .62,
                  opaqueBackground: false,
                ),
              ),
            ),
            ActionChip(
              label: const Text('紧凑玻璃'),
              onPressed: () => _change(
                settings.copyWith(
                  barHeight: 64,
                  horizontalMargin: 12,
                  safeGap: -12,
                  iconSize: 20,
                  materialOpacity: .62,
                  opaqueBackground: false,
                ),
              ),
            ),
            ActionChip(
              label: const Text('清晰实色'),
              onPressed: () => _change(
                settings.copyWith(materialOpacity: 1, opaqueBackground: true),
              ),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: () => setState(() => _advanced = !_advanced),
          icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more),
          label: const Text('高级外观'),
        ),
        if (_advanced) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('顶部透明度'),
            subtitle: const Text('顶部导航、首页分类及收缩状态同步调整'),
            trailing: Text(
              '${((1 - FloatingModules.instance.style(FloatingModule.home).opacity) * 100).round()}%',
            ),
          ),
          NativeGlassSlider(
            key: const ValueKey('top-navigation-transparency'),
            value:
                1 - FloatingModules.instance.style(FloatingModule.home).opacity,
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: (value) => setState(() {
              for (final module in [
                FloatingModule.navigation,
                FloatingModule.home,
              ]) {
                FloatingModules.instance.set(
                  module,
                  FloatingModules.instance
                      .style(module)
                      .copyWith(opacity: 1 - value),
                );
              }
            }),
            onChangeEnd: (_) => FloatingModules.instance.save(),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('底部透明度'),
            subtitle: const Text('0% 遮挡底下内容，100% 保留系统玻璃。收起后只显示图标，无圆形底色。'),
            trailing: Text(
              '${((1 - settings.materialOpacity) * 100).round()}%',
            ),
          ),
          NativeGlassSlider(
            key: const ValueKey('bottom-navigation-transparency'),
            value: 1 - settings.materialOpacity,
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: settings.enabled && settings.opaqueBackground
                ? null
                : (value) => _change(
                    settings.copyWith(materialOpacity: 1 - value),
                    save: false,
                  ),
            onChangeEnd: (_) =>
                unawaited(widget.controller.saveNativeNavigation()),
          ),
          if (settings.enabled)
            NativeSwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('底部使用纯色背景'),
              subtitle: const Text('开启后完全遮挡内容，无需调透明度；关闭后恢复系统液态玻璃。'),
              value: settings.opaqueBackground,
              onChanged: (value) =>
                  _change(settings.copyWith(opaqueBackground: value)),
            ),
          if (settings.enabled) ...[
            FutureBuilder<SystemTabBarCapabilities>(
              future: _capabilities,
              builder: (context, snapshot) {
                final capabilities = snapshot.data;
                if (capabilities?.supported != true || !_previewAvailable) {
                  return const SizedBox.shrink();
                }
                final height = _previewHeight ?? capabilities!.height;
                final id = widget.entries.any((e) => e.id == _previewId)
                    ? _previewId!
                    : widget.entries.any((e) => e.id == 'settings')
                    ? 'settings'
                    : widget.entries.first.id;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: MediaQuery.removeViewPadding(
                    context: context,
                    removeLeft: true,
                    removeRight: true,
                    removeBottom: true,
                    child: SystemDockBar(
                      entries: widget.entries,
                      activeId: id,
                      onSelect: (id) {
                        if (id != ShellDockEntry.search.id) {
                          setState(() => _previewId = id);
                        }
                      },
                      settings: settings,
                      height: height,
                      bottomMargin: settings.bottomFor(
                        MediaQuery.viewPaddingOf(context).bottom,
                      ),
                      onHeightChanged: (value) {
                        if (mounted && value != _previewHeight) {
                          setState(() => _previewHeight = value);
                        }
                      },
                      onUnavailable: () {
                        if (mounted) setState(() => _previewAvailable = false);
                      },
                    ),
                  ),
                );
              },
            ),
            NativeSwitchListTile.adaptive(
              key: const ValueKey('native-navigation-labels'),
              contentPadding: EdgeInsets.zero,
              title: const Text('显示标签文字'),
              value: settings.showLabels,
              onChanged: (value) =>
                  _change(settings.copyWith(showLabels: value)),
            ),
            if (!settings.solidIcons)
              NativeSwitchListTile.adaptive(
                key: const ValueKey('native-navigation-theme-tint'),
                contentPadding: EdgeInsets.zero,
                title: const Text('强调色跟随主题'),
                value: settings.followThemeColor,
                onChanged: (value) =>
                    _change(settings.copyWith(followThemeColor: value)),
              ),
            if (!settings.solidIcons && !settings.followThemeColor)
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    0xFF7C5CFF: '紫色',
                    0xFF007AFF: '蓝色',
                    0xFF008A6A: '绿色',
                    0xFFE56A00: '橙色',
                    0xFFE83E72: '粉色',
                  }.entries)
                    ChoiceChip(
                      key: ValueKey('native-navigation-color-${entry.key}'),
                      label: Text(entry.value),
                      avatar: Icon(
                        Icons.circle,
                        color: Color(entry.key),
                        size: 16,
                      ),
                      selected: settings.tintColor == entry.key,
                      onSelected: (_) =>
                          _change(settings.copyWith(tintColor: entry.key)),
                    ),
                ],
              ),
            NativeSwitchListTile.adaptive(
              key: const ValueKey('native-navigation-auto-height'),
              contentPadding: EdgeInsets.zero,
              title: const Text('使用系统默认高度'),
              value: settings.barHeight == 0,
              onChanged: (value) => _change(
                settings.copyWith(
                  barHeight: value ? 0 : (_previewHeight ?? 64),
                ),
              ),
            ),
            _slider(
              'height',
              '导航栏高度',
              settings.heightFor(_previewHeight ?? 64),
              40,
              120,
              (value) => settings.copyWith(barHeight: value),
            ),
            _slider(
              'icon-size',
              '图标大小',
              settings.iconSize,
              18,
              30,
              (value) => settings.copyWith(iconSize: value),
            ),
            _slider(
              'margin',
              '左右留白',
              settings.horizontalMargin,
              0,
              40,
              (value) => settings.copyWith(horizontalMargin: value),
            ),
            _slider(
              'safe-gap',
              '安全区上方距离',
              settings.safeGap,
              -100,
              100,
              (value) => settings.copyWith(safeGap: value),
            ),
            const SettingsFooterNote(
              '高度直接控制原生玻璃胶囊及收缩圆圈的直径。图标大小独立调整。负距离向下移动，最低贴近屏幕底部。',
              padding: EdgeInsets.zero,
            ),
            TextButton(
              key: const ValueKey('native-navigation-reset'),
              onPressed: () {
                _change(const NativeNavigationSettings());
                for (final module in [
                  FloatingModule.navigation,
                  FloatingModule.home,
                ]) {
                  FloatingModules.instance.set(
                    module,
                    FloatingModules.instance
                        .style(module)
                        .copyWith(
                          opacity: FloatingStyle.defaultFor(module).opacity,
                        ),
                  );
                }
                FloatingModules.instance.save();
              },
              child: const Text('恢复原生导航默认参数'),
            ),
          ],
        ],
      ],
    ),
  );

  Widget _slider(
    String id,
    String label,
    double value,
    double min,
    double max,
    NativeNavigationSettings Function(double) update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('$label  ${value.round()}'),
      ),
      NativeGlassSlider(
        key: ValueKey('native-navigation-$id'),
        value: value,
        min: min,
        max: max,
        divisions: (max - min).round(),
        label: '${value.round()}',
        onChanged: (value) => _change(update(value), save: false),
        onChangeEnd: (_) => unawaited(widget.controller.saveNativeNavigation()),
      ),
    ],
  );
}
