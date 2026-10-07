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
/// **页签的身份是标识（[ShellTab.id]）而不是下标**：用户可以在设置里隐藏页签、
/// 拖拽排序（见 [ShellSettings]），下标会随着这两件事漂移。当前选中、可见性、
/// 顺序全部按标识走，因此「把当前页签拖到别处」不会导致跳到别的板块。
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

  /// 「设置页被隐藏」时的恢复入口定位键。
  ///
  /// 见 [ShellSettings] 的硬约束 2：设置页是导航栏管理的入口，把它藏起来之后
  /// 用户再也进不去管理页——因此隐藏时壳层一定留一个小的设置入口。
  static const Key settingsEntryKey = Key('shell.settingsEntry');

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

  /// 底部导航栏配置（逐项开关 + 顺序）。壳层监听它：改完立刻生效，
  /// 不必等用户切页签或重启。
  final ShellSettingsController _shellSettings = ShellSettingsController.instance;

  /// 自建的控制器要自己释放；外部传进来的由外部负责。
  late final bool _ownsController = widget.controller == null;

  /// 当前页签的**标识**（不是下标：顺序会变、页签会隐藏）。
  String _activeId = _pageCatalog.first.id;

  static const double _dockHeight = 64;
  static const double _dockMargin = 12;
  static const double _dockSpacing = 8;

  /// 页签目录：标识 + 展示文案 + 两个图标 + 页面构造。
  ///
  /// 文案用 [Section.label]（展示口径：视频 = Section.video），板块的库、缓存、
  /// 图源归属仍走 Section.id，与展示文案无关。
  static final List<_ShellTab> _pageCatalog = <_ShellTab>[
    _ShellTab(
      id: ShellTab.all[0].id,
      label: Section.novel.label,
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book_rounded,
      builder: () => const NovelPage(),
    ),
    _ShellTab(
      id: ShellTab.all[1].id,
      label: Section.comic.label,
      icon: Icons.auto_stories_outlined,
      selectedIcon: Icons.auto_stories_rounded,
      builder: () => const ComicPage(),
    ),
    _ShellTab(
      id: ShellTab.all[2].id,
      label: Section.video.label,
      icon: Icons.play_circle_outline_rounded,
      selectedIcon: Icons.play_circle_fill_rounded,
      builder: () => const VideoPage(),
    ),
    _ShellTab(
      id: ShellTab.all[3].id,
      label: Section.cat.label,
      icon: Icons.pets_outlined,
      selectedIcon: Icons.pets_rounded,
      builder: () => const CatPage(),
    ),
    _ShellTab(
      id: ShellTab.all[4].id,
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      builder: () => const SettingsPage(),
    ),
  ];

  static _ShellTab _pageOf(String id) => _pageCatalog.firstWhere(
        (tab) => tab.id == id,
        // 配置里出现目录之外的标识理论上不会发生（fromJson 会过滤），
        // 兜底回第一个页签，绝不让壳层因为一份坏配置打不开。
        orElse: () => _pageCatalog.first,
      );

  /// 可见页签（按用户配置的顺序）。
  List<_ShellTab> get _visibleTabs => <_ShellTab>[
        for (final config in _shellSettings.settings.visibleTabs)
          _pageOf(config.id),
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
    if (!mounted) return;
    setState(() {
      // 当前页签被隐藏了（用户刚把它关掉）：落到第一个可见页签上。
      // 不这么做的话页面会停在一个已经不在导航栏里的页签上——用户看得见内容，
      // 却在底部找不到自己在哪里。
      final visible = _visibleTabs;
      if (visible.isNotEmpty && !visible.any((tab) => tab.id == _activeId)) {
        _activeId = visible.first.id;
      }
    });
  }

  void _select(String id) {
    if (id == _activeId) return;
    setState(() => _activeId = id);
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

  /// 「设置页被隐藏」时的恢复入口。
  ///
  /// 这是硬约束不是装饰：设置页是「底部导航栏管理」自己的入口。把它藏起来之后，
  /// 用户再也进不去管理页把别的页签打开——「至少保留 1 个页签」拦不住这种锁死
  /// （另外 4 个板块都还在，但没有任何一个能进设置）。
  ///
  /// 放在**左下角**：右下角是页面 FAB 的地盘（源总管理 / 漫画仓库页的「+」），
  /// 放右下会重叠（实测两个矩形相交）。
  Widget _buildSettingsEntry() {
    return Positioned(
      left: _dockMargin,
      bottom: _dockMargin,
      child: SafeArea(
        child: Tooltip(
          message: '设置（底部导航栏里已隐藏）',
          child: Material(
            key: AppShell.settingsEntryKey,
            color: LumeTheme.surface,
            shape: const CircleBorder(),
            elevation: 3,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _select(ShellTab.settingsId),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.settings_outlined,
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
    final tabs = _visibleTabs;
    final settingsHidden = !_shellSettings.settingsVisible;
    final bottomInset = MediaQuery.of(context).padding.bottom +
        _dockHeight +
        _dockMargin * 2 +
        _dockSpacing;
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
            if (settingsHidden) _buildSettingsEntry(),
          ],
        ),
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => _DockBar(
          key: AppShell.dockKey,
          tabs: tabs,
          activeId: _activeId,
          onSelect: _select,
          visible: _controller.visible,
          height: _dockHeight,
          margin: _dockMargin,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 桌面端

  Widget _buildRail() {
    // 桌面端：左侧栏始终显示全部页签（文档口径），但顺序跟随用户配置——
    // 顺序是用户的肌肉记忆，两个端保持一致更不容易点错。
    final tabs = _visibleTabs;
    final activeIndex = tabs.indexWhere((tab) => tab.id == _activeId);
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            key: AppShell.railKey,
            selectedIndex: activeIndex < 0 ? 0 : activeIndex,
            onDestinationSelected: (index) => _select(tabs[index].id),
            labelType: NavigationRailLabelType.all,
            backgroundColor: LumeTheme.surface,
            indicatorColor: const Color(0x1A7C5CFF),
            destinations: <NavigationRailDestination>[
              for (final tab in tabs)
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
  ///
  /// Key 用页签**标识**：同一页签在顺序变化时不该被重建（换了 key 会让板块的
  /// 阅读库、滚动位置一起丢），而切到另一个页签必须重建（资源释放的既有口径）。
  Widget _buildPage() => KeyedSubtree(
        key: ValueKey<String>(_activeId),
        child: _pageOf(_activeId).builder(),
      );
}

/// 一个页签：标识 + 展示文案 + 两个图标（未选中 / 选中）+ 页面构造。
class _ShellTab {
  const _ShellTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  /// 稳定标识（与 [ShellTab.id] 同源）：配置、选中、key 都按它走。
  final String id;

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// 底部悬浮 Dock：浅色毛玻璃胶囊，各项等宽，选中项品牌紫 + 高亮底座。
///
/// 它悬在页面内容之上（`extendBody`），因此底下的列表与封面会从胶囊里透出来——
/// 全 App 玻璃感最明显的一处。
///
/// 项数可变（用户可隐藏页签，最少 1 项最多 5 项），各项等宽由 `Expanded` 平分。
class _DockBar extends StatelessWidget {
  const _DockBar({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.visible,
    required this.height,
    required this.margin,
  });

  final List<_ShellTab> tabs;
  final String activeId;
  final ValueChanged<String> onSelect;
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
                        for (final tab in tabs)
                          Expanded(
                            child: _DockItem(
                              tab: tab,
                              selected: tab.id == activeId,
                              onTap: () => onSelect(tab.id),
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
