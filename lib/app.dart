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
    return MaterialApp(
      title: LumeTheme.appName,
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(),
      navigatorObservers: <NavigatorObserver>[ShellDockObserver(_dock)],
      home: AppShell(controller: _dock),
    );
  }
}
