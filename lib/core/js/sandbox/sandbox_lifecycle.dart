import 'package:flutter/widgets.dart';

import 'sandbox_scope.dart';

/// 页面退出自动销毁沙箱的接线。
///
/// 用法：页面 State 混入本 mixin，用 `sandboxes.open(...)` 创建沙箱。
/// `State.dispose()` 触发时作用域被销毁，页面持有的全部 JSContext 同步释放，
/// 不需要页面自己写清理代码。本 mixin 只做生命周期接线，不产生任何可见 UI。
///
/// 注意：需要更细粒度控制时，也可以在非页面对象上直接使用 [SandboxScope]。
mixin SandboxScopeOwner<T extends StatefulWidget> on State<T> {
  SandboxScope? _sandboxScope;

  /// 本页面的沙箱作用域，首次访问时创建。
  SandboxScope get sandboxes =>
      _sandboxScope ??= SandboxScope(owner: '$runtimeType');

  /// 当前作用域，尚未创建时返回 null（不会触发创建）。
  SandboxScope? get sandboxScope => _sandboxScope;

  @override
  void dispose() {
    _sandboxScope?.dispose();
    _sandboxScope = null;
    super.dispose();
  }
}
