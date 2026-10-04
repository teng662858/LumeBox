import 'dart:async';

import '../../util/lume_log.dart';
import 'sandbox_context.dart';
import 'sandbox_host.dart';
import 'sandbox_policy.dart';
import 'sandbox_polyfill.dart';
import 'sandbox_result.dart';

/// 沙箱外观：面向业务的唯一入口。
///
/// 职责边界：
/// - 上下文生命周期（创建 / 销毁 / 污染后重建）由本类掌握，调用方拿不到原生句柄；
/// - 同一实例的操作串行执行，避免多个业务路径交叉驱动同一个 JSContext；
/// - 一旦上下文被判定污染（超时、引擎级异常、预算耗尽），立即销毁，
///   下一次操作重建**全新 generation** 的上下文，旧上下文绝不复用。
class LumeSandbox {
  LumeSandbox._({
    required this.id,
    required this.policy,
    required this.host,
    required this.polyfills,
  });

  /// 创建沙箱。原生库不可用时抛 [StateError]；调用方通常先用
  /// [LumeSandbox.isSupported] 判断。
  ///
  /// 创建本身不做任何原生工作：真正的 JSContext 在第一次操作时才建立，
  /// 因此本方法是同步的，销毁路径也能保持同步（页面退出即释放）。
  static LumeSandbox create({
    required String id,
    SandboxPolicy policy = SandboxPolicy.standard,
    SandboxHost host = const DenyAllSandboxHost(),
    PolyfillRegistry? polyfills,
  }) {
    if (!SandboxContext.isSupported) {
      throw StateError('沙箱不可用（${SandboxContext.availabilityDetail}）');
    }
    return LumeSandbox._(
      id: id,
      policy: policy.clamped(),
      host: host,
      polyfills: polyfills ?? PolyfillRegistry.empty,
    );
  }

  /// 沙箱标识。
  final String id;

  /// 生效策略（超时已收敛到 3–5 秒）。
  final SandboxPolicy policy;

  /// 外部能力代理。
  final SandboxHost host;

  /// 垫片登记表。
  final PolyfillRegistry polyfills;

  SandboxContext? _context;
  String? _source;
  int _generation = 0;
  bool _disposed = false;
  SandboxError? _lastFailure;
  Future<void> _queue = Future<void>.value();

  /// 沙箱能力是否可用。
  static bool get isSupported => SandboxContext.isSupported;

  /// 可用性描述，写日志用。
  static String get availabilityDetail => SandboxContext.availabilityDetail;

  /// 原生中断通路是否可用（不可用时超时保护退化为预算机制）。
  static bool get interruptAvailable => SandboxContext.interruptAvailable;

  bool get isDisposed => _disposed;

  /// 当前上下文是否已判定污染。
  bool get isPoisoned => _context?.isPoisoned ?? false;

  /// 最近一次操作的失败原因，便于上层诊断（成功时保留上一次的失败记录）。
  SandboxError? get lastFailure => _lastFailure;

  /// 已创建的上下文代数。1 表示首个上下文，污染重建后递增。
  int get generation => _generation;

  /// 当前是否已有一个可用上下文（未创建 / 已销毁 / 已污染时为 false）。
  bool get hasLiveContext {
    final context = _context;
    return context != null && !context.isDestroyed && !context.isPoisoned;
  }

  /// 已载入的脚本源码；上下文重建后会自动重放。
  String? get loadedSource => _source;

  /// 载入脚本。成功后源码被记住，后续上下文重建会自动重放。
  Future<SandboxResult> load(String source) => _operate(
        'load',
        (context, budget) {
          final result = context.loadSource(source);
          _source = result.isOk ? source : null;
          if (!result.isOk) {
            LumeLog.warn('[$id] 脚本载入失败: ${result.error}');
          }
          return Future<SandboxResult>.value(result);
        },
      );

  /// 求值一段 JS 并返回其 JSON 结果。
  Future<SandboxResult> eval(String code, {String? fileName}) => _operate(
        'eval',
        (context, budget) =>
            Future<SandboxResult>.value(context.evalJson(code, fileName: fileName)),
      );

  /// Dart → JS 调用：`path` 支持点号路径（如 `LumeSource.latest`），
  /// 参数与返回值均为 JSON 可序列化值。
  Future<SandboxResult> call(String path, [Object? argument]) => _operate(
        'call:$path',
        (context, budget) => context.call(path, argument),
      );

  /// 销毁当前上下文并释放资源。可重复调用。
  ///
  /// 同步完成：JS 执行始终在本 isolate 的线程上，调用本方法时不可能有
  /// 原生求值正在栈上，因此无需等待在飞操作。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recycle();
  }

  // ------------------------------------------------------------------ 内部

  Future<SandboxResult> _operate(
    String label,
    Future<SandboxResult> Function(SandboxContext context, SandboxBudget budget)
        action,
  ) {
    if (_disposed) {
      return Future<SandboxResult>.value(
        const SandboxFailure(SandboxErrorKind.disposed, '沙箱已释放'),
      );
    }
    if (!SandboxContext.isSupported) {
      return Future<SandboxResult>.value(
        SandboxFailure(SandboxErrorKind.unsupported, SandboxContext.availabilityDetail),
      );
    }
    final completer = Completer<SandboxResult>();
    _queue = _queue.then((_) async {
      if (completer.isCompleted) return;
      try {
        completer.complete(await _execute(label, action));
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
        completer.complete(
          SandboxFailure(SandboxErrorKind.engine, '$error'),
        );
      }
    });
    return completer.future;
  }

  Future<SandboxResult> _execute(
    String label,
    Future<SandboxResult> Function(SandboxContext context, SandboxBudget budget)
        action,
  ) async {
    if (_disposed) {
      return const SandboxFailure(SandboxErrorKind.disposed, '沙箱已释放');
    }
    SandboxContext context;
    try {
      context = _ensureContext();
    } catch (error) {
      return SandboxFailure(SandboxErrorKind.engine, '上下文创建失败: $error');
    }
    final budget = SandboxBudget(policy, DateTime.now());
    context.beginOperation(budget);
    try {
      final result = await action(context, budget);
      if (!result.isOk) {
        _lastFailure = result.error;
        LumeLog.warn('[$id] $label 失败: ${result.error}');
      }
      return result;
    } finally {
      context.endOperation();
      // 安全点：原生栈已退出，此时销毁被污染的上下文是安全的。
      _recycleIfPoisoned();
    }
  }

  /// 取得可用的上下文；不存在或已被污染/销毁时重建。
  SandboxContext _ensureContext() {
    final existing = _context;
    if (existing != null && !existing.isDestroyed && !existing.isPoisoned) {
      return existing;
    }
    if (existing != null) {
      LumeLog.warn('[$id] 丢弃污染上下文（${existing.poisonReason ?? '已销毁'}），重建全新上下文');
    }
    existing?.destroy();
    _context = null;
    final created = SandboxContext.create(
      id: id,
      policy: policy,
      host: host,
      polyfills: polyfills,
    );
    _generation++;
    _context = created;
    final source = _source;
    if (source != null) {
      final replayed = created.loadSource(source);
      if (!replayed.isOk) {
        created.destroy();
        _context = null;
        _source = null;
        throw StateError('重建后脚本重放失败: ${replayed.error}');
      }
    }
    return created;
  }

  void _recycleIfPoisoned() {
    final context = _context;
    if (context == null) return;
    if (!context.isPoisoned && !context.isDestroyed) return;
    context.destroy();
    _context = null;
  }

  void _recycle() {
    _context?.destroy();
    _context = null;
    _source = null;
  }
}
