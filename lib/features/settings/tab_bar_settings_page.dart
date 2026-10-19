import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/theme/lume_theme.dart';
import '../shell/shell_dock_bar.dart';
import '../../shared/widgets/dock_handle_button.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

/// 底部导航栏管理：**每个页签独立开关 + 拖拽排序 + 外观材质**。
///
/// ## 外观与材质
///
/// 尺寸（左右留白 / 高度 / 离底距离）、玻璃边缘高光、投影浓度、选中动效与时长
/// 都在本页调节，实时写回 [ShellSettingsController]；玻璃白度与磨砂强度与
/// 「设置 → 悬浮模块」共用同一份 [FloatingModules] 数据，不存第二份真相。
///
/// ## 两条硬约束（界面上都要说清）
///
/// 1. **至少保留 1 个页签**：全部关掉导航栏就空了，用户再也点不到任何入口。
///    因此最后一个可见页签的开关是**置灰**的，并说明原因（不是「点了没反应」）。
/// 2. **隐藏「设置」会留一个恢复入口**：设置页是进入本页的唯一入口。把它藏起来
///    之后没法再回来开别的页签——所以壳层会在左下角留一个小的设置按钮。
///    这一点必须写在界面上，否则用户会以为「隐藏设置 = 以后再也改不了导航栏」。
///
/// ## 实时生效
///
/// 每次改动直接写进 [ShellSettingsController]（它通知壳层重建），**不需要点保存、
/// 不需要重启**。这也是不做「保存/取消」按钮的原因：拖一下就立刻能看到底部变化，
/// 比「改完再确认」更符合拖拽这种直接操作的手感。
class TabBarSettingsPage extends StatelessWidget {
  const TabBarSettingsPage({super.key, this.controller});

  /// 设置控制器（测试可注入）；为空时用应用级单例。
  final ShellSettingsController? controller;

  ShellSettingsController get _controller =>
      controller ?? ShellSettingsController.instance;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      effectModule: GlassModule.settings,
      behindBar: true,
      title: '底部导航栏管理',
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final tabs = _controller.tabs;
    final visibleCount = tabs.where((tab) => tab.visible).length;
    final settingsHidden = !_controller.settingsVisible;

    return ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: <Widget>[
        _buildIntro(visibleCount),
        const SizedBox(height: 12),
        // 拖拽排序：ReorderableListView 需要有限高度，这里用 shrinkWrap
        // 嵌在 ListView 里（本页条目固定 5 条，不存在长列表性能问题）。
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: tabs.length,
          // onReorderItem（不是已废弃的 onReorder）：它给的 newIndex 已经是
          // 「移动后的最终下标」，与 ShellSettings.withMove 的语义一致，
          // 调用方不必自己处理 off-by-one。
          onReorderItem: (from, to) => _controller.move(from, to),
          itemBuilder: (context, index) {
            final tab = tabs[index];
            return _TabTile(
              key: ValueKey<String>('tab.${tab.id}'),
              index: index,
              config: tab,
              // 「至少保留 1 个」：最后一个可见项不许关。
              canHide: _controller.canHide(tab.id),
              onToggle: (value) => _toggle(context, tab.id, value),
            );
          },
        ),
        if (settingsHidden) ...<Widget>[
          const SizedBox(height: 12),
          const _SettingsHiddenNotice(),
        ],
        const SizedBox(height: 12),
        _buildAppearance(context),
        const SizedBox(height: 12),
        _buildHandleStyles(context),
        const SizedBox(height: 12),
        _buildFooter(context),
      ],
    );
  }

  Future<void> _toggle(BuildContext context, String id, bool value) async {
    final accepted = await _controller.setVisible(id, value);
    if (accepted || !context.mounted) return;
    // 被「至少保留 1 个」拒绝：明确告诉用户为什么，而不是让开关弹回去。
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text(ShellSettings.lastTabMessage)));
  }

  Widget _buildIntro(int visibleCount) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '当前显示 $visibleCount 个页签',
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const SettingsFooterNote(
            '拖动手柄调整顺序，开关控制显示与隐藏。改动立即生效，不用重启 App。'
            '至少要保留 1 个页签，否则底部导航就空了。',
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  /// 外观与材质：尺寸 / 玻璃边缘 / 投影 / 点击动效。
  ///
  /// 白度与磨砂读写的仍是 [FloatingModules] 里「底部导航」那一份值（与
  /// 「设置 → 悬浮模块」同源），其余参数在 [ShellSettingsController]。
  Widget _buildAppearance(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) {
        final appearance = _controller.appearance;
        final modules = FloatingModules.instance;
        final style = modules.style(FloatingModule.dock);
        // 预览也用**当前可见的页签与顺序**：用户在下面关掉/拖动页签后，
        // 预览里立刻少一项 / 换位置，而不是永远画着五格。
        final visibleEntries = <ShellDockEntry>[];
        for (final config in _controller.settings.visibleTabs) {
          final tab = ShellTab.byId(config.id);
          if (tab != null) visibleEntries.add(_previewEntry(tab));
        }
        return GlassCard(
          radius: 14,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '外观与材质',
                style: TextStyle(
                  fontSize: LumeTypography.titleSize,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const SettingsFooterNote(
                '调整底部 Dock 的尺寸与玻璃质感，改动立即生效。'
                '深色主题下白边会按比例柔化，避免在暗底上变成硬描边。',
                padding: EdgeInsets.zero,
              ),
              const SizedBox(height: 14),
              _DockAppearancePreview(
                appearance: appearance,
                entries: visibleEntries,
              ),
              ListTile(
                key: const ValueKey('dock-liquid-open'),
                contentPadding: EdgeInsets.zero,
                title: const Text('液态玻璃细调'),
                subtitle: const Text('水滴、胶囊、清透度、折射与回弹，分别调节'),
                trailing: const LumeIcon(
                  Icons.chevron_right,
                  slot: 'tab_bar_settings_page.1',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _LiquidDockSettingsPage(
                      controller: _controller,
                      entries: visibleEntries,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-opacity'),
                label: '玻璃白度',
                description: '玻璃里白色底的不透明度：0% 全透、100% 接近实心白。',
                value: style.opacity,
                min: 0,
                max: 1,
                divisions: 100,
                display: '${(style.opacity * 100).round()}%',
                onChanged: (value) => modules.set(
                  FloatingModule.dock,
                  style.copyWith(opacity: value),
                ),
                onChangeEnd: (_) => modules.save(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-blur'),
                label: '磨砂强度',
                description: '背后内容的模糊半径：0 = 完全清晰，30 = 最强雾面。',
                value: style.blur,
                min: 0,
                max: 30,
                divisions: 30,
                display: style.blur.toStringAsFixed(0),
                onChanged: (value) => modules.set(
                  FloatingModule.dock,
                  style.copyWith(blur: value),
                ),
                onChangeEnd: (_) => modules.save(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-border'),
                label: '边缘高光',
                description: '1px 白色描边的亮度：0% 无描边，100% 最亮。',
                value: appearance.borderOpacity,
                min: 0,
                max: 1,
                divisions: 100,
                display: '${(appearance.borderOpacity * 100).round()}%',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(borderOpacity: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-shadow'),
                label: '阴影浓度',
                description: 'Dock 投到页面上的黑色阴影浓度：0% 完全无影。',
                value: appearance.shadowOpacity,
                min: 0,
                max: 1,
                divisions: 100,
                display: '${(appearance.shadowOpacity * 100).round()}%',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(shadowOpacity: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-margin'),
                label: '左右留白',
                description: 'Dock 距屏幕左右边缘的距离：0 pt 贴边，100 pt 最窄。',
                value: appearance.horizontalMargin,
                min: 0,
                max: 100,
                divisions: 100,
                display: '${appearance.horizontalMargin.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(horizontalMargin: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-height'),
                label: '导航栏高度',
                description: '胶囊总高度；40 pt 以下的内容会自动缩放，图标与文字始终居中。',
                value: appearance.height,
                min: 40,
                max: 150,
                divisions: 110,
                display: '${appearance.height.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(height: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-gap'),
                label: '离底部距离',
                description: '正数抬高；负数压进 / 越过系统手势条（-50 会沉到屏幕底边以下）。',
                value: appearance.safeGap,
                min: -50,
                max: 100,
                divisions: 150,
                display: '${appearance.safeGap.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(safeGap: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              // 用普通 Row 而不是 SwitchListTile：ListTile 会注入自己的
              // titleTextStyle（不跟随页面字体），截图/自定义字体下会掉字。
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '点击弹跳动效',
                          style: TextStyle(
                            fontSize: LumeTypography.bodySize,
                            fontWeight: FontWeight.w500,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '切换页签时选中底座像水滴一样轻微回弹',
                          style: TextStyle(
                            fontSize: LumeTypography.descriptionSize,
                            color: LumeTheme.descriptionColor,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: appearance.animateSelection,
                    onChanged: (value) => _controller.setAppearance(
                      _controller.appearance.copyWith(animateSelection: value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (appearance.animateSelection)
                _appearanceSlider(
                  key: const ValueKey('dock-appearance-duration'),
                  label: '动效时长',
                  description: '换算成弹簧刚度与阻尼：100 ms 快速吸附，2000 ms 软而慢地回弹。',
                  value: appearance.animationMs.toDouble(),
                  min: 100,
                  max: 2000,
                  divisions: 190,
                  display: '${appearance.animationMs} ms',
                  onChanged: (value) => _controller.setAppearance(
                    _controller.appearance.copyWith(animationMs: value.round()),
                    persist: false,
                  ),
                  onChangeEnd: (_) => _controller.saveAppearance(),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _resetAppearance,
                  icon: const LumeIcon(
                    Icons.restart_alt,
                    slot: 'tab_bar_settings_page.2',
                    size: 18,
                  ),
                  label: const Text('恢复材质默认'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _resetAppearance() async {
    await _controller.setAppearance(DockAppearance.defaults);
    final modules = FloatingModules.instance;
    modules.set(
      FloatingModule.dock,
      modules
          .style(FloatingModule.dock)
          .copyWith(
            opacity: FloatingStyle.dockDefault.opacity,
            blur: FloatingStyle.dockDefault.blur,
          ),
    );
    modules.save();
  }

  Widget _appearanceSlider({
    Key? key,
    required String label,
    required String description,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: LumeTypography.bodySize,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            // 固定宽度 + 右对齐：每一行的数值落在同一条竖线上。
            SizedBox(
              width: 64,
              child: Text(
                display,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: LumeTypography.descriptionSize,
                  color: LumeTheme.textSecondary,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
        Slider(
          key: key,
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
        // 每个滑块下面直接写清「调了会怎样」：这是设置页的主要疑问来源。
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              description,
              style: TextStyle(
                fontSize: LumeTypography.descriptionSize,
                height: 1.4,
                color: LumeTheme.descriptionColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHandleStyles(BuildContext context) {
    final selected = _controller.handleStyle;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '收起悬浮球',
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const SettingsFooterNote(
            '导航栏滚动收起时，左下角悬浮球的样式。点一下立即生效；'
            '不用时会半透明，向右滑动或点击都能展开导航。',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          for (final style in DockHandleStyle.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _HandleStyleOption(
                style: style,
                selected: style == selected,
                onTap: () => _controller.setHandleStyle(style),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '说明',
            style: TextStyle(
              fontSize: LumeTypography.bodySize,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const SettingsFooterNote(
            '· 隐藏某个板块只是把它从底部导航里收起来，数据、缓存与图源都不受影响，'
            '随时可以再打开；\n'
            '· 桌面端（Windows / macOS）用的是左侧栏，顺序跟随这里的设置；\n'
            '· 隐藏「设置」后，左下角会出现一个小的设置按钮，点它回来改回这里。',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _controller.restoreDefaults(),
            icon: const LumeIcon(
              Icons.restart_alt,
              slot: 'tab_bar_settings_page.3',
              size: 18,
            ),
            label: const Text('恢复默认（全部显示）'),
          ),
        ],
      ),
    );
  }
}

/// 一行页签：拖拽手柄 + 名称 + 开关。
class _TabTile extends StatelessWidget {
  const _TabTile({
    super.key,
    required this.index,
    required this.config,
    required this.canHide,
    required this.onToggle,
  });

  final int index;
  final ShellTabConfig config;

  /// 是否允许被关掉（最后一个可见项不允许）。
  final bool canHide;

  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final tab = ShellTab.byId(config.id);
    final label = tab?.label ?? config.id;
    final isLastVisible = config.visible && !canHide;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            // 拖拽手柄：显式的拖动区，避免与开关的点击手势打架。
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: LumeIcon(
                  Icons.drag_handle,
                  slot: 'tab_bar_settings_page.4',
                  size: 20,
                  color: LumeTheme.textHint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  if (isLastVisible) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '最后一个显示的页签，不能关掉',
                      style: TextStyle(
                        fontWeight: FontWeight.w400,
                        fontSize: LumeTypography.descriptionSize,
                        height: 1.5,
                        color: LumeTheme.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: config.visible,
              // 最后一颗开关置灰：点不动比「点了弹提示再弹回来」更清楚，
              // 且旁边的文字已经说明了原因。
              onChanged: canHide ? onToggle : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「设置页已隐藏」的提示卡：告诉用户怎么回来。
class _SettingsHiddenNotice extends StatelessWidget {
  const _SettingsHiddenNotice();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LumeIcon(
            Icons.info_outline,
            slot: 'tab_bar_settings_page.5',
            size: 20,
            color: LumeTheme.info,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '「设置」页签已隐藏：底部导航里看不到它了。'
              '为了避免再也进不来本页，屏幕左下角会出现一个小的设置按钮，'
              '点它就能回到设置（以及本页）。',
              style: TextStyle(
                fontWeight: FontWeight.w400,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「收起悬浮球」样式选项：左边一个真实可点的预览球，右边文案 + 选中勾。
class _HandleStyleOption extends StatelessWidget {
  const _HandleStyleOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final DockHandleStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = LumeTheme.accent;
    return Material(
      color: selected ? accent.withValues(alpha: .08) : LumeTheme.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('dock-handle-style-${style.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent.withValues(alpha: .22), LumeTheme.base],
                  ),
                ),
                child: Center(
                  child: DockHandleButton(
                    style: style,
                    size: 46,
                    onPressed: onTap,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      style.label,
                      style: TextStyle(
                        fontSize: LumeTypography.bodySize,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      style.description,
                      style: TextStyle(
                        fontSize: LumeTypography.descriptionSize,
                        color: LumeTheme.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              LumeIcon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                slot: 'tab_bar_settings_page.6',
                variant: true,
                size: 20,
                color: selected ? accent : LumeTheme.hairline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 管理页里的「真实 Dock 预览」。
///
/// 它不是照着 Dock 画的示意图，而是把生产代码里的 [ShellDockBar] 原样压在一块
/// 彩色海报墙上：玻璃白度 / 磨砂强度 / 选中胶囊 / 动效时长全部走同一份设置，
/// 拖动滑块时背后的海报会被真实模糊。预览条本身也可以直接点，切换页签会播放
/// 与壳层完全相同的滑动动画。
/// The production dock stays visible while the long list of controls scrolls.
class _LiquidDockSettingsPage extends StatelessWidget {
  const _LiquidDockSettingsPage({
    required this.controller,
    required this.entries,
  });
  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final appearance = controller.appearance;
      final liquid = appearance.liquid;
      Widget slider(DockLiquidParameter p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(p.label)),
                Text(p.display(liquid.value(p))),
              ],
            ),
            Slider(
              key: ValueKey('dock-liquid-${p.name}'),
              value: liquid.value(p),
              min: p.min,
              max: p.max,
              divisions: p.milliseconds ? 350 : 100,
              onChanged: (value) => controller.setAppearance(
                controller.appearance.copyWith(
                  liquid: controller.appearance.liquid.withValue(p, value),
                ),
                persist: false,
              ),
              onChangeEnd: (_) =>
                  controller.setAppearance(controller.appearance),
            ),
            Text(
              p.description,
              style: TextStyle(
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
          ],
        ),
      );
      return Scaffold(
        appBar: AppBar(title: const Text('液态玻璃细调')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _DockAppearancePreview(
                  appearance: appearance,
                  entries: entries,
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('在上方按住或拖动体验。调节立即生效，并自动保存。'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('液态动效总开关'),
                      subtitle: const Text('与上一页的“点击弹跳动效”使用同一个开关'),
                      value: appearance.animateSelection,
                      onChanged: (value) => controller.setAppearance(
                        controller.appearance.copyWith(animateSelection: value),
                      ),
                    ),
                    for (final p in DockLiquidParameter.values.where(
                      (p) => p.effect == null,
                    ))
                      slider(p),
                    for (final effect in DockLiquidEffect.values) ...[
                      const Divider(),
                      SwitchListTile.adaptive(
                        key: ValueKey('dock-liquid-effect-${effect.name}'),
                        title: Text(effect.label),
                        subtitle: Text(effect.description),
                        value: liquid.enabled(effect),
                        onChanged: (value) => controller.setAppearance(
                          controller.appearance.copyWith(
                            liquid: controller.appearance.liquid.withEnabled(
                              effect,
                              value,
                            ),
                          ),
                        ),
                      ),
                      if (liquid.enabled(effect))
                        for (final p in DockLiquidParameter.values.where(
                          (p) => p.effect == effect,
                        ))
                          slider(p),
                    ],
                    TextButton.icon(
                      key: const ValueKey('dock-liquid-reset'),
                      onPressed: () => controller.setAppearance(
                        controller.appearance.copyWith(
                          liquid: const DockLiquidSettings(),
                        ),
                      ),
                      icon: const LumeIcon(
                        Icons.restore,
                        slot: 'tab_bar_settings_page.7',
                      ),
                      label: const Text('恢复液态参数默认值'),
                    ),
                    const SettingsFooterNote(
                      '只恢复本页的液态参数；白度、磨砂、尺寸、动效时长及页签顺序保留。'
                      '系统开启减少动态效果时，按压和拖动形变自动停止。',
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DockAppearancePreview extends StatefulWidget {
  const _DockAppearancePreview({
    required this.appearance,
    required this.entries,
  });

  final DockAppearance appearance;

  /// 当前可见的页签（顺序与真实 Dock 一致，至少 1 项）。
  final List<ShellDockEntry> entries;

  @override
  State<_DockAppearancePreview> createState() => _DockAppearancePreviewState();
}

class _DockAppearancePreviewState extends State<_DockAppearancePreview> {
  String _activeId = ShellTab.all.first.id;

  /// 选中项被用户隐藏后，回落到第一个仍可见的页签。
  String get _resolvedActiveId {
    if (widget.entries.isEmpty) return _activeId;
    if (widget.entries.any((entry) => entry.id == _activeId)) return _activeId;
    return widget.entries.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final appearance = widget.appearance;
    // 预览高度跟随「高度 + 正离底距离」增长：150pt 高、100pt 抬高时也能完整
    // 看到胶囊，而不是被裁掉一半。负离底距离让胶囊向下沉，模拟压进安全区。
    final previewHeight =
        200.0 +
        (appearance.height - 54).clamp(0, 96) +
        appearance.safeGap.clamp(0, 100);
    return ClipRRect(
      key: const ValueKey('dock-appearance-preview'),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: double.infinity,
        height: previewHeight,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const _PreviewPosterWall(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10 + appearance.safeGap,
              child: ShellDockBar(
                entries: widget.entries,
                activeId: _resolvedActiveId,
                onSelect: (id) => setState(() => _activeId = id),
                appearance: appearance,
                applyViewPadding: false,
              ),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .34),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '真实 Dock · 可点击',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

ShellDockEntry _previewEntry(ShellTab tab) {
  final (IconData icon, IconData selectedIcon) = switch (tab.id) {
    'novel' => (Icons.menu_book_outlined, Icons.menu_book_rounded),
    'comic' => (Icons.auto_stories_outlined, Icons.auto_stories_rounded),
    'video' => (
      Icons.play_circle_outline_rounded,
      Icons.play_circle_fill_rounded,
    ),
    'cat' => (Icons.pets_outlined, Icons.pets_rounded),
    _ => (Icons.settings_outlined, Icons.settings_rounded),
  };
  return ShellDockEntry(
    id: tab.id,
    label: tab.label,
    icon: icon,
    selectedIcon: selectedIcon,
  );
}

/// 预览背景：一张由海报拼成的彩色墙，底层再铺细斜纹。
///
/// 斜纹是给毛玻璃「对焦」用的：不模糊时是一根根细线，模糊后融成柔和的
/// 光带，滑块拖到 0 与 15 的差别一眼可见。
class _PreviewPosterWall extends StatelessWidget {
  const _PreviewPosterWall();

  static const List<(List<Color>, String, String)> _posters =
      <(List<Color>, String, String)>[
        (<Color>[Color(0xFF6C5CE7), Color(0xFFA29BFE)], '漫剧', '新番'),
        (<Color>[Color(0xFFFF7675), Color(0xFFFDA085)], '电影', '热映'),
        (<Color>[Color(0xFF00B894), Color(0xFF55EFC4)], '阅读', '连载'),
        (<Color>[Color(0xFF0984E3), Color(0xFF74B9FF)], '短剧', '推荐'),
      ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final poster in _posters)
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: poster.$1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            poster.$2,
                            style: TextStyle(
                              fontSize: 22,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: .92),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            poster.$3,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: .64),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 104,
          child: CustomPaint(painter: _PreviewStripePainter()),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.transparent,
                    Colors.black.withValues(alpha: .18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewStripePainter extends CustomPainter {
  const _PreviewStripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .16)
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width; x += 14) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewStripePainter oldDelegate) => false;
}
