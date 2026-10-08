import 'package:flutter/widgets.dart';

/// 底部 Dock 的显隐控制器。
///
/// 多个来源可以同时要求隐藏（全屏路由、播放中的视频页）：任一来源要求隐藏时
/// Dock 就隐藏，全部来源释放后自动恢复。用「来源令牌」而不是布尔开关，是为了
/// 避免一个来源恢复时把另一个来源的隐藏一并取消。
class ShellDockController extends ChangeNotifier {
  final Set<Object> _hiddenBy = <Object>{};

  /// Dock 当前是否应当显示。
  bool get visible => _hiddenBy.isEmpty;

  /// 某个来源要求隐藏 Dock。
  void hide(Object source) {
    if (_hiddenBy.add(source)) notifyListeners();
  }

  /// 某个来源释放隐藏要求。
  void show(Object source) {
    if (_hiddenBy.remove(source)) notifyListeners();
  }
}

/// 把 [ShellDockController] 交给 Dock 所在的整棵子树。
///
/// 板块页 / 播放器要隐藏 Dock 时从这里取控制器；拿不到（例如页面被 push 到了
/// 导航壳之外）就说明它不在壳里，此时不需要隐藏——它本来就盖住了 Dock。
class ShellDockScope extends InheritedNotifier<ShellDockController> {
  const ShellDockScope({
    super.key,
    required ShellDockController controller,
    this.dockInset = 0,
    required super.child,
  }) : super(notifier: controller);

  /// Dock（含悬浮留白）占掉的底部高度。
  ///
  /// **给滚动视图当尾部内边距用**，不要再把它当整页的安全区用——那是「列表底部
  /// 永远空一大块」的来源（用户口径：没滚到底时不该预留，内容要尽量往下铺）。
  /// 滚动视图把它加进 padding.bottom，只有**滚到最末**时才会真正让出这一段。
  final double dockInset;

  static ShellDockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellDockScope>()?.notifier;

  /// Dock 占用的底部高度；不在壳里（或没有 Dock）时为 0。
  static double bottomInset(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ShellDockScope>();
    return scope?.dockInset ?? 0;
  }
}

/// 全屏页监听：任何全屏页面（小说 / 漫画阅读器、详情、二级设置页）压栈时
/// 自动隐藏 Dock，出栈后恢复。
///
/// 只认 [PageRoute]：对话框、底部面板这类弹出层属于 PopupRoute，不改变底部
/// 导航的显隐，否则每次弹窗 Dock 都会闪一下。
class ShellDockObserver extends NavigatorObserver {
  ShellDockObserver(this.controller);

  final ShellDockController controller;

  /// 路由 → 该路由在控制器上占用的隐藏令牌。
  final Map<Route<dynamic>, Object> _tokens = <Route<dynamic>, Object>{};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.isFirst || route is! PageRoute) return;
    final token = Object();
    _tokens[route] = token;
    controller.hide(token);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _release(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _release(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _release(oldRoute);
    if (newRoute != null) didPush(newRoute, null);
  }

  void _release(Route<dynamic> route) {
    final token = _tokens.remove(route);
    if (token != null) controller.show(token);
  }
}
