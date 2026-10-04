import 'lume_sandbox.dart';
import 'sandbox_host.dart';
import 'sandbox_policy.dart';
import 'sandbox_polyfill.dart';

/// 持有者级沙箱作用域：把一组沙箱绑定到某个生命周期主体上
/// （页面、板块、功能模块），主体结束时一次性销毁。
///
/// 销毁顺序与创建顺序相反，保证上层依赖先于底层释放；销毁是同步的，
/// 页面退出即释放全部 JSContext。作用域销毁后仍可调用 [open]，
/// 但拿到的沙箱会立即被回收，避免出现「页面已退出但仍在跑脚本」的悬挂上下文。
class SandboxScope {
  SandboxScope({required this.owner, this.defaultPolicy = SandboxPolicy.standard});

  /// 持有者标识，会拼进沙箱 id，便于日志与宿主侧隔离判定。
  final String owner;

  /// 新建沙箱时使用的默认策略。
  final SandboxPolicy defaultPolicy;

  final Map<String, LumeSandbox> _sandboxes = <String, LumeSandbox>{};
  final List<String> _order = <String>[];
  bool _disposed = false;

  bool get isDisposed => _disposed;

  int get count => _sandboxes.length;

  Iterable<String> get keys => _sandboxes.keys;

  /// 取得（必要时创建）本作用域下的沙箱。同一 key 重复调用返回同一实例。
  LumeSandbox open(
    String key, {
    SandboxPolicy? policy,
    SandboxHost host = const DenyAllSandboxHost(),
    PolyfillRegistry? polyfills,
  }) {
    final existing = _sandboxes[key];
    if (existing != null) return existing;
    final sandbox = LumeSandbox.create(
      id: '$owner:$key',
      policy: policy ?? defaultPolicy,
      host: host,
      polyfills: polyfills,
    );
    if (_disposed) {
      sandbox.dispose();
      return sandbox;
    }
    _sandboxes[key] = sandbox;
    _order.add(key);
    return sandbox;
  }

  LumeSandbox? find(String key) => _sandboxes[key];

  /// 释放单个沙箱。
  void close(String key) {
    _order.remove(key);
    _sandboxes.remove(key)?.dispose();
  }

  /// 逆序销毁作用域内全部沙箱。可重复调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final key in _order.reversed.toList(growable: false)) {
      _sandboxes.remove(key)?.dispose();
    }
    _order.clear();
    _sandboxes.clear();
  }
}
