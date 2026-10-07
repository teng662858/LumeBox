import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../cat/cat_page.dart';
import '../comic/comic_page.dart';
import '../novel/novel_page.dart';
import '../settings/settings_page.dart';
import '../video/video_page.dart';
import 'shell_dock.dart';

/// 主导航：五个页签（小说 / 漫画 / 视频 / 猫源 / 设置）。
///
/// 移动端是底部悬浮 Dock（毛玻璃胶囊）；桌面端（Windows / macOS / Linux）
/// 自动换成左侧 NavigationRail —— 同一套页签，两种排布，页签内容不变。
///
/// 资源纪律：**只把当前页签的页面挂在树上**，切走即销毁、切回重建。因此
/// 板块的阅读库、图源运行时、sqlite 句柄都沿用「进板块打开、退出板块释放」
/// 的既有口径，四个板块的资源不会同时驻留（这不是 IndexedStack 那种全挂载）。
///
/// 全屏页（阅读器 / 播放器）压栈时 Dock 由 [ShellDockObserver] 自动隐藏，
/// 出栈后恢复；视频页在播放中隐藏 Dock 走 [ShellDockScope] 的令牌。
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.controller, this.desktopRail});

  /// 底部 Dock 的定位键（测试按它确认 Dock 存在与隐藏）。
  static const Key dockKey = Key('shell.dock');

  /// 左侧栏的定位键。
  static const Key railKey = Key('shell.rail');

  /// 底部导航栏被关掉时，恢复入口的定位键。
  static const Key dockRestoreKey = Key('shell.dockRestore');

  /// Dock 显隐控制器；为空时自建（独立测试用；正式入口由 [MaterialApp] 传入
  /// 同一个实例，与导航观察者共享）。
  final ShellDockController? controller;

  /// 是否用左侧栏；为空时按平台判断（桌面端 → NavigationRail）。
  final bool? desktopRail;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ShellDockController _controller =
      widget.controller ?? ShellDockController();

  /// 底部导航栏开关（全局设置页可改）。壳层监听它：改完立刻生效，
  /// 不必等用户切页签或重启。
  final ShellSettingsController _shellSettings = ShellSettingsController.instance;

  /// 自建的控制器要自己释放；外部传进来的由外部负责。
  late final bool _ownsController = widget.controller == null;

  int _index = 0;

  static const double _dockHeight = 64;
  static const double _dockMargin = 12;
  static const double _dockSpacing = 8;

  /// 五个页签。文字用 [Section.label]（展示口径：视频 = Section.video），
  /// 板块的库、缓存、图源归属仍走 Section.id，与展示文案无关。
  static final List<_ShellTab> _tabs = <_ShellTab>[
    _ShellTab(
      label: Section.novel.label,
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book_rounded,
      builder: () => const NovelPage(),
    ),
    _ShellTab(
      label: Section.comic.label,
      icon: Icons.auto_stories_outlined,
      selectedIcon: Icons.auto_stories_rounded,
      builder: () => const ComicPage(),
    ),
    _ShellTab(
      label: Section.video.label,
      icon: Icons.play_circle_outline_rounded,
      selectedIcon: Icons.play_circle_fill_rounded,
      builder: () => const VideoPage(),
    ),
    _ShellTab(
      label: Section.cat.label,
      icon: Icons.pets_outlined,
      selectedIcon: Icons.pets_rounded,
      builder: () => const CatPage(),
    ),
    _ShellTab(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      builder: () => const SettingsPage(),
    ),
  ];

  /// 桌面端：Windows / macOS / Linux 自动用侧边栏（移动端保持底部 Dock）。
  static bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  @override
  void initState() {
    super.initState();
    _shellSettings.addListener(_onShellSettingsChanged);
  }

  @override
  void dispose() {
    _shellSettings.removeListener(_onShellSettingsChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onShellSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.desktopRail ?? _isDesktopPlatform;
    return ShellDockScope(
      controller: _controller,
      child: rail ? _buildRail() : _buildDock(),
    );
  }

  // ------------------------------------------------------------------ 移动端

  /// 底部导航栏被关掉时，右下角留的**恢复入口**。
  ///
  /// 这是硬约束不是装饰：5 个 Tab 是顶层导航，整块藏掉而不给回来的路，
  /// 用户会被困在当前板块里（在小说页就再也点不到设置）。因此关掉导航栏时
  /// 一定有一个小的悬浮按钮，点它把导航栏召唤回来。
  ///
  /// 放在**左下角**：右下角是页面 FAB 的地盘（源总管理 / 漫画仓库页的
  /// 「+」都在那儿），放右下会重叠（实测 FAB rect 与恢复按钮 rect 相交）。
  /// 左下角没有别的悬浮控件，也不挡列表的右侧操作区。
  Widget _buildDockRestoreButton() {
    return Positioned(
      left: _dockMargin,
      bottom: _dockMargin,
      child: SafeArea(
        child: Tooltip(
          message: '显示底部导航栏',
          child: Material(
            key: AppShell.dockRestoreKey,
            color: LumeTheme.surface,
            shape: const CircleBorder(),
            elevation: 3,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _shellSettings.setDockEnabled(true),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 22,
                  color: LumeTheme.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDock() {
    // 导航栏关掉时：内容不再需要为 Dock 让位，右下角换成恢复入口。
    final dockEnabled = _shellSettings.dockEnabled;
    final bottomInset = dockEnabled
        ? MediaQuery.of(context).padding.bottom +
            _dockHeight +
            _dockMargin * 2 +
            _dockSpacing
        : MediaQuery.of(context).padding.bottom;
    return Scaffold(
      extendBody: true,
      body: MediaQuery(
        // 悬浮 Dock 盖在内容之上：把它的高度加进底部安全区，页面里的 SafeArea
        // 会自动让列表等内容滚出 Dock 的遮挡范围。
        data: MediaQuery.of(context).copyWith(
          padding: MediaQuery.of(context).padding.copyWith(bottom: bottomInset),
        ),
        child: Stack(
          children: <Widget>[
            _buildPage(),
            if (!dockEnabled) _buildDockRestoreButton(),
          ],
        ),
      ),
      bottomNavigationBar: dockEnabled
          ? AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => _DockBar(
                key: AppShell.dockKey,
                tabs: _tabs,
                index: _index,
                onSelect: _select,
                visible: _controller.visible,
                height: _dockHeight,
                margin: _dockMargin,
              ),
            )
          : null,
    );
  }

  // ------------------------------------------------------------------ 桌面端

  Widget _buildRail() {
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            key: AppShell.railKey,
            selectedIndex: _index,
            onDestinationSelected: _select,
            labelType: NavigationRailLabelType.all,
            backgroundColor: LumeTheme.surface,
            indicatorColor: const Color(0x1A7C5CFF),
            destinations: <NavigationRailDestination>[
              for (final tab in _tabs)
                NavigationRailDestination(
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.selectedIcon),
                  label: Text(tab.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildPage()),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 页面

  /// 当前页签的页面：只建当前这一个，切页签即热替换（旧页签资源随之释放）。
  Widget _buildPage() => KeyedSubtree(
        key: ValueKey<int>(_index),
        child: _tabs[_index].builder(),
      );
}

/// 一个页签：展示文案 + 两个图标（未选中 / 选中）+ 页面构造。
class _ShellTab {
  const _ShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// 底部悬浮 Dock：浅色毛玻璃胶囊，五项等宽，选中项品牌紫 + 高亮底座。
///
/// 它悬在页面内容之上（`extendBody`），因此底下的列表与封面会从胶囊里透出来——
/// 全 App 玻璃感最明显的一处。
class _DockBar extends StatelessWidget {
  const _DockBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onSelect,
    required this.visible,
    required this.height,
    required this.margin,
  });

  final List<_ShellTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;
  final bool visible;
  final double height;
  final double margin;

  @override
  Widget build(BuildContext context) {
    // 隐藏时整块（含内边距）平移到屏幕下沿之外，不占视觉、不响应点击。
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 1.2),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: LumeTheme.floatShadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: LumeTheme.glass,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: LumeTheme.hairline),
                  ),
                  child: SizedBox(
                    height: height,
                    child: Row(
                      children: <Widget>[
                        for (var i = 0; i < tabs.length; i++)
                          Expanded(
                            child: _DockItem(
                              tab: tabs[i],
                              selected: i == index,
                              onTap: () => onSelect(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? LumeTheme.accent : LumeTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: LumeTheme.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Icon(tab.selectedIcon, size: 20, color: color),
              ),
            )
          else
            Icon(tab.icon, size: 20, color: color),
          const SizedBox(height: 3),
          Text(
            tab.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
