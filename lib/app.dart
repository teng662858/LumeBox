import 'package:flutter/material.dart';

import 'core/theme/lume_theme.dart';
import 'features/settings/cache_pruner.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/shell_dock.dart';

/// Lume Box 应用入口。
///
/// 启动即进入主导航壳（五个页签：小说 / 漫画 / 视频 / 猫源 / 设置），
/// 没有中间首页。全屏页（阅读器 / 播放器）由 [ShellDockObserver] 联动隐藏
/// 底部 Dock —— 观察者与导航壳共享同一个 [ShellDockController] 实例。
class LumeBoxApp extends StatefulWidget {
  const LumeBoxApp({super.key});

  @override
  State<LumeBoxApp> createState() => _LumeBoxAppState();
}

class _LumeBoxAppState extends State<LumeBoxApp> {
  final ShellDockController _dock = ShellDockController();

  /// 缓存策略的后台执行器：启动后延迟首跑，之后定期复查（只在配了策略时才干活）。
  final CachePruner _cachePruner = CachePruner();

  @override
  void initState() {
    super.initState();
    _cachePruner.start();
  }

  @override
  void dispose() {
    _cachePruner.dispose();
    _dock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 全局主题跟随系统（文档「全局主题补充」）：亮色与暗色各一套色板，
    // ThemeMode.system 让 Flutter 按系统外观选。阅读器不受这里影响——
    // 小说 / 漫画阅读页有自己的阅读主题（见 LumeTheme 的类文档）。
    return MaterialApp(
      title: LumeTheme.appName,
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      darkTheme: LumeTheme.build(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      // 页面里的静态色名（`LumeTheme.textPrimary` 等）按进程级亮度取色，
      // 而 Flutter 选亮色还是暗色由 ThemeMode.system 决定。这里把**实际生效
      // 的亮度**回写给静态色名，并按亮度给整棵子树换 key：
      // 系统外观一变，子树整体重建，所有静态色名重新取值——
      // 否则只换 ThemeData、不重建的页面会留着旧主题的颜色。
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        LumeTheme.applyBrightness(brightness);
        return KeyedSubtree(
          key: ValueKey<Brightness>(brightness),
          child: child ?? const SizedBox.shrink(),
        );
      },
      navigatorObservers: <NavigatorObserver>[ShellDockObserver(_dock)],
      home: AppShell(controller: _dock),
    );
  }
}
