import 'shared/widgets/theme_refresh_boundary.dart';

import 'package:flutter/material.dart';

import 'core/session/privacy_settings.dart';
import 'shared/widgets/app_privacy_guard.dart';

import 'core/theme/appearance.dart';
import 'core/theme/lume_theme.dart';
import 'core/theme/user_fonts.dart';
import 'core/theme/interface_typography.dart';
import 'core/theme/icon_customization.dart';
import 'shared/widgets/lume_icon.dart';
import 'features/settings/icon_library_page.dart';
import 'features/settings/cache_pruner.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/shell_dock.dart';

/// Lume Box 应用入口。
///
/// 启动即进入主导航壳（三个页签：漫画 / 视频 / 设置），
/// 没有中间首页。全屏页（阅读器 / 播放器）由 [ShellDockObserver] 联动隐藏
/// 底部 Dock —— 观察者与导航壳共享同一个 [ShellDockController] 实例。
class LumeBoxApp extends StatefulWidget {
  const LumeBoxApp({super.key});

  @override
  State<LumeBoxApp> createState() => _LumeBoxAppState();
}

class _LumeBoxAppState extends State<LumeBoxApp> {
  final ShellDockController _dock = ShellDockController();
  late final ShellDockObserver _dockObserver = ShellDockObserver(_dock);

  /// 缓存策略的后台执行器：启动后延迟首跑，之后定期复查（只在配了策略时才干活）。
  final CachePruner _cachePruner = CachePruner();

  @override
  void initState() {
    super.initState();
    _cachePruner.start();
    IconCustomization.instance.boot();
  }

  @override
  void dispose() {
    _cachePruner.dispose();
    _dock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 全局外观由「设置 → 显示」决定（亮暗模式 + 主题色），见 `appearance.dart`：
    // - 模式默认跟随系统（文档「全局主题补充」），用户也可以锁定浅色 / 深色；
    // - 主题色只换主色，两套亮度下的分层与对比度结构保持不变。
    // 阅读器不受这里影响——漫画阅读页有自己的阅读主题（见类文档）。
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppearanceController.instance,
        UserFonts.instance,
      ]),
      builder: (context, _) {
        final appearance = AppearanceController.instance.settings;
        return MaterialApp(
          title: LumeTheme.appName,
          debugShowCheckedModeBanner: false,
          theme: LumeTheme.build(
            brightness: Brightness.light,
            accent: appearance.accent,
            customAccent: appearance.customAccent,
            fontFamily: UserFonts.instance.familyFor(appearance.fontId),
            fontBold: appearance.fontBold,
            fontItalic: appearance.fontItalic,
            background: appearance.background,
          ),
          darkTheme: LumeTheme.build(
            brightness: Brightness.dark,
            accent: appearance.accent,
            customAccent: appearance.customAccent,
            fontFamily: UserFonts.instance.familyFor(appearance.fontId),
            fontBold: appearance.fontBold,
            fontItalic: appearance.fontItalic,
            background: appearance.background,
          ),
          themeMode: appearance.mode,
          // 页面里的静态色名（`LumeTheme.textPrimary` 等）按进程级亮度取色，
          // 同步实际主题后重新求值静态色名，保留路由和页面状态。
          builder: (context, child) {
            final brightness = Theme.of(context).brightness;
            LumeTheme.applyBrightness(brightness);
            LumeTheme.applyAccent(
              appearance.accent,
              customAccent: appearance.customAccent,
            );
            LumeTheme.applyBackground(appearance.background);
            return ThemeRefreshBoundary(
              identity: LumeTheme.themeId,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: appearance.textScale == 1
                      ? MediaQuery.textScalerOf(context)
                      : InterfaceTextScaler(
                          MediaQuery.textScalerOf(context),
                          appearance.textScale,
                        ),
                ),
                child: AppIconEditingScope(
                  onEdit: editAppIcon,
                  child: AppPrivacyGuard(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          },
          navigatorObservers: <NavigatorObserver>[_dockObserver],
          home: ListenableBuilder(
            listenable: PrivacySettings.instance,
            builder: (context, _) => AppShell(controller: _dock),
          ),
        );
      },
    );
  }
}
