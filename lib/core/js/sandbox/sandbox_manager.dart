import 'lume_sandbox.dart';
import 'sandbox_host.dart';
import 'sandbox_policy.dart';
import 'sandbox_polyfill.dart';

/// 沙箱注册表：按 id 管理多个互相隔离的沙箱。
///
/// 隔离体现在三层：每个沙箱独占 JSRuntime/JSContext、独占定时器与技能预算、
/// 且在宿主代理里能以 [LumeSandbox.id] 区分来源。注册表本身不共享任何
/// 运行时状态，注销即同步销毁。
class SandboxManager {
  SandboxManager({this.defaultPolicy = SandboxPolicy.standard});

  /// 进程级默认注册表。业务也可以各自 new 一个，互不影响。
  static final SandboxManager instance = SandboxManager();

  /// 新建沙箱时使用的默认策略。
  final SandboxPolicy defaultPolicy;

  final Map<String, LumeSandbox> _sandboxes = <String, LumeSandbox>{};

  int get count => _sandboxes.length;

  Iterable<String> get ids => _sandboxes.keys;

  /// 取得（必要时创建）指定 id 的沙箱。同一 id 重复调用返回同一实例。
  LumeSandbox open(
    String id, {
    SandboxPolicy? policy,
    SandboxHost host = const DenyAllSandboxHost(),
    PolyfillRegistry? polyfills,
  }) {
    final existing = _sandboxes[id];
    if (existing != null) return existing;
    final created = LumeSandbox.create(
      id: id,
      policy: policy ?? defaultPolicy,
      host: host,
      polyfills: polyfills,
    );
    _sandboxes[id] = created;
    return created;
  }

  /// 查找已创建的沙箱（不触发创建）。
  LumeSandbox? find(String id) => _sandboxes[id];

  /// 注销并同步销毁指定沙箱。
  void release(String id) => _sandboxes.remove(id)?.dispose();

  /// 销毁全部沙箱。
  void disposeAll() {
    for (final sandbox in _sandboxes.values.toList(growable: false)) {
      sandbox.dispose();
    }
    _sandboxes.clear();
  }
}
