/// QuickJS-NG 沙箱抽象层。
///
/// 分层：
/// - [SandboxPolicy] / [SandboxBudget]：运行策略与预算账本；
/// - [SandboxHost]：JS 侧 IO / 网络能力的唯一代理入口；
/// - [PolyfillRegistry]：垫片注入入口（只定义契约，不含实现）；
/// - [SandboxGuard]：超时与指令计数的原生中断通路（不可用时降级为预算机制）；
/// - [SandboxContext]：单个隔离 JSContext 的封装；
/// - [LumeSandbox] / [SandboxManager] / [SandboxScope]：面向业务的创建、隔离与销毁；
/// - [SandboxScopeOwner]：页面退出自动销毁的接线。
library;

export 'lume_sandbox.dart';
export 'sandbox_context.dart' show SandboxContext;
export 'sandbox_guard.dart' show SandboxArming, SandboxGuard, SandboxInterrupt;
export 'sandbox_host.dart';
export 'sandbox_lifecycle.dart';
export 'sandbox_manager.dart';
export 'sandbox_policy.dart';
export 'sandbox_polyfill.dart';
export 'sandbox_result.dart';
export 'sandbox_scope.dart';
