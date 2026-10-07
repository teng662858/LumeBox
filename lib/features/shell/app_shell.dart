import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../cat/cat_page.dart';
import '../comic/comic_page.dart';
import '../novel/novel_page.dart';
import '../settings/settings_page.dart';
import '../video/video_page.dart';
import 'section_preloader.dart';
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
  /// Dock 与屏幕左右 / 底边的留白。用户要求「底部导航栏整体往下移一点」，
  /// 因此底边留白收紧（12 → 6）——左右仍是 12，Dock 只是更贴近屏幕下沿。
  static const double _dockBottomMargin = 6;
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

  /// 可见页签（按用户配置的顺序）——移动端 Dock 用。
  List<_ShellTab> get _visibleTabs => <_ShellTab>[
        for (final config in _shellSettings.settings.visibleTabs)
          _pageOf(config.id),
      ];

  /// 全部页签（按用户配置的顺序）——桌面端左侧栏用。
  ///
  /// 桌面端**不跟随「隐藏」**，只跟随顺序：左侧栏是桌面端的标准布局，页签少一个
  /// 会让工具栏看起来像坏了。更要紧的是，Rail 上没有移动端那个左下角恢复入口，
  /// 若这里也按可见性过滤，「隐藏设置」就会把桌面用户彻底锁死——设置页是导航栏
  /// 管理自己的入口，藏起来之后再也进不去（见 [ShellSettings] 硬约束 2）。
  List<_ShellTab> get _orderedTabs => <_ShellTab>[
        for (final config in _shellSettings.tabs) _pageOf(config.id),
      ];

  /// 当前布局**实际渲染 / 实际可达**的页签集合。
  ///
  /// 「当前页签被隐藏后落到哪里」要以它为基准：桌面端隐藏的页签仍在 Rail 上、
  /// 仍点得到，就不该把用户从当前页面赶走；移动端则会从 Dock 上消失，必须落回
  /// 一个还看得见的页签，否则用户会停在「底部找不到自己位置」的页面上。
  ///
  /// 移动端的**设置页恒为可达**：它在 Dock 上时点得到，被隐藏时左下角还有恢复
  /// 入口（见 [_buildSettingsEntry]）。这一点必须体现在这里，否则会踩一个很难
  /// 发现的坑——用户隐藏设置 → 点左下角入口进设置 → 在管理页里改任意一个页签，
  /// 就会被当成「停在一个不可达的页签上」而被弹回小说板块，于是**永远改不完配置**。
  List<_ShellTab> get _reachableTabs {
    final rail = widget.desktopRail ?? _isDesktopPlatform;
    if (rail) return _orderedTabs;
    final tabs = _visibleTabs;
    if (tabs.any((tab) => tab.id == ShellTab.settingsId)) return tabs;
    return <_ShellTab>[...tabs, _pageOf(ShellTab.settingsId)];
  }

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
      // 当前页签被隐藏了（用户刚把它关掉）：落到第一个仍可达的页签上。
      // 不这么做的话页面会停在一个已经不在导航栏里的页签上——用户看得见内容，
      // 却在底部找不到自己在哪里。桌面端 Rail 不过滤可见性（见 [_reachableTabs]），
      // 因此桌面端不会因为「隐藏」把用户从当前页面赶走。
      final reachable = _reachableTabs;
      if (reachable.isNotEmpty && !reachable.any((tab) => tab.id == _activeId)) {
        _activeId = reachable.first.id;
      }
    });
  }

  void _select(String id) {
    if (id == _activeId) return;
    // **先预热再切**（真机反馈：切板块要等、进页面才开始发请求）。这里趁手指刚
    // 点下去、页面还没构建的那一小段，把板块运行时（阅读库 + 源引擎）与首页
    // 第一页提前拉起来；页面构建后能直接吃这口热饭。
    // 预热失败不影响任何事（页面照旧自己取），见 [SectionPreloader]。
    _warmUp(id);
    setState(() => _activeId = id);
  }

  /// 预热目标板块（只预热有源运行时的板块；失败静默）。
  void _warmUp(String id) {
    final section = sectionFromId(id);
    if (section == null) return;
    if (!LumeSources.runtimeAvailableFor(section)) return;
    // 不 await：预热是「提前做」，绝不能拖慢页签切换本身。
    unawaited(
      SectionPreloader.warm(
        section,
        manager: LumeSources.manager(section),
        openLibrary: () => ReadingLibrary.open(section).then((_) {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.desktopRail ?? _isDesktopPlatform;
    // 依赖主题：切亮暗 / 换主题色时壳层整体重建（Dock 的磨砂底色、页签图标颜色
    // 都是静态色名，不重建就会留在旧主题里）。
    Theme.of(context);
    return ShellDockScope(
      controller: _controller,
      child: rail ? _buildRail() : _buildDock(),
    );
  }

  // ------------------------------------------------------------------ 移动端

  /// 恢复入口收起时下滑的距离（逻辑像素）。
  ///
  /// 必须把它**悬浮在 Dock 之上的那段**（底栏高 + 上下留白，约 96）与**自身高度**
  /// 一起算进去：只滑「自身高度」会让按钮停在屏幕里，等于没藏。
  /// 用绝对像素而不是 `AnimatedSlide` 的「自身尺寸倍数」：那个倍数会随图标内边距
  /// 变化而漂移，是条看不见的耦合。这里多给一点余量，滑出屏幕即可。
  static const double _entryHideTravel =
      _dockHeight + _dockMargin + _dockBottomMargin + _dockSpacing + 64;

  /// 「设置页被隐藏」时的恢复入口。
  ///
  /// 这是硬约束不是装饰：设置页是「底部导航栏管理」自己的入口。把它藏起来之后，
  /// 用户再也进不去管理页把别的页签打开——「至少保留 1 个页签」拦不住这种锁死
  /// （另外 4 个板块都还在，但没有任何一个能进设置）。
  ///
  /// 放在**左下角**：右下角是页面 FAB 的地盘（源总管理 / 漫画仓库页的「+」），
  /// 放右下会重叠（实测两个矩形相交）。
  ///
  /// **跟随 Dock 显隐**（[visible]）：这个入口是导航壳的一部分，底栏藏起来时
  /// 它也得藏。最典型的是视频播放中——壳层为「沉浸观看」把 Dock 收起，此时
  /// 左下角恰好是**亮度手势区**，一个浮在那里的齿轮按钮既挡画面又抢手势。
  Widget _buildSettingsEntry({required bool visible}) {
    return Positioned(
      left: _dockMargin,
      bottom: _dockBottomMargin,
      child: SafeArea(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: visible ? 0 : _entryHideTravel),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          builder: (context, dy, child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
          child: IgnorePointer(
            ignoring: !visible,
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
            if (settingsHidden)
              // 与底栏同一个显隐来源：Dock 收起（播放中 / 全屏页压栈）时，
              // 恢复入口一并收起。
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) =>
                    _buildSettingsEntry(visible: _controller.visible),
              ),
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
    // 桌面端：左侧栏**始终显示全部页签**（桌面端标准布局），顺序跟随用户配置——
    // 顺序是用户的肌肉记忆，两个端保持一致更不容易点错。
    //
    // 刻意不按可见性过滤：Rail 上没有移动端那个左下角恢复入口，过滤之后
    // 「隐藏设置」会把桌面用户彻底锁死（见 [_orderedTabs]）。
    final tabs = _orderedTabs;
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
  /// Key 用页签**标识 + 主题身份**：
  /// - 页签标识——同一页签在顺序变化时不该被重建（换了 key 会让板块的阅读库、
  ///   滚动位置一起丢），而切到另一个页签必须重建（资源释放的既有口径）；
  /// - 主题身份——切亮暗 / 换主题色时**整页重建**，静态色名（`LumeTheme.*`）
  ///   才会重新取值。少了它，切主题后页面里只读静态色名的部件会留在旧配色上
  ///   （真机现象：设置页里两张**内容为 const 的分组卡**在深色下仍是白底、
  ///   文字却是深色主题的浅色，糊成一片）。代价：切主题会重建当前页签，
  ///   页内滚动位置等局部状态归零——这是静态色名架构下的取舍。
  Widget _buildPage() => KeyedSubtree(
        key: ValueKey<String>('$_activeId·${LumeTheme.themeId}'),
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
