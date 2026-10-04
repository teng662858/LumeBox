import 'dart:ffi';

import '../../util/lume_log.dart';
import '../qjs_bindings.dart';
import 'sandbox_policy.dart';

/// 中断原因：由原生中断处理器在 JS 执行过程中判定。
enum SandboxInterrupt {
  /// 墙钟预算耗尽。
  timeout('执行超时'),

  /// 指令计数耗尽。
  instructions('超出指令计数上限');

  const SandboxInterrupt(this.label);

  final String label;
}

/// 一次求值的中断装备状态。Dart 与原生回调共享，回调触发时读取。
class SandboxArming {
  SandboxArming({required this.deadlineMillis, required this.ticksLeft});

  final int deadlineMillis;
  int ticksLeft;
  SandboxInterrupt? fired;
}

/// 执行保护：把「超时 + 指令计数」落到原生中断处理器，并给出降级路径。
///
/// QuickJS 在执行字节码时周期性回调中断处理器，返回非 0 即抛出**不可捕获**的
/// 中断错误并终止本次求值——这是唯一能在纯 CPU 死循环里夺回控制权的手段。
///
/// 但当前插件构建把 quickjs 本体符号设为 hidden，`JS_SetInterruptHandler` 在
/// PE / Mach-O 动态符号表里都不存在（已实测：DLL 导出表中查无此名）。
/// 因此 [interruptAvailable] 恒为 false，实际生效的是 [SandboxBudget] 预算机制，
/// 原生通路保留待插件暴露该符号后自动升级。
class SandboxGuard {
  SandboxGuard._();

  /// quickjs-ng 的中断检查间隔：中断处理器每执行约这么多条指令被回调一次。
  /// 指令预算按此换算成 tick 预算。
  static const int instructionsPerTick = 10000;

  static final Map<int, SandboxArming> _armings = <int, SandboxArming>{};

  static NativeCallable<JsInterruptCallback>? _callable;

  static bool _degradedLogged = false;

  /// 原生中断通路是否可用。
  static bool get interruptAvailable => Qjs.interruptHookAvailable;

  /// 配置 runtime 级硬限制，并尽力安装中断处理器。
  static void attach(Pointer<JsRuntimeHandle> runtime, SandboxPolicy policy) {
    Qjs.setMemoryLimit(runtime, policy.memoryLimitBytes);
    Qjs.setMaxStackSize(runtime, policy.stackLimitBytes);
    final installed = _install(runtime);
    if (!installed && !_degradedLogged) {
      _degradedLogged = true;
      LumeLog.warn(
        'JS_SetInterruptHandler 不可用：超时保护降级为预算机制，'
        '内存/栈上限仍然生效（已实测内存上限可中止分配型失控）',
      );
    }
  }

  static bool _install(Pointer<JsRuntimeHandle> runtime) {
    // 插件的中断回调通道不接受 opaque，这里固定传 nullptr。
    if (!Qjs.isAvailable) return false;
    try {
      _callable ??= NativeCallable<JsInterruptCallback>.isolateLocal(
        _onInterrupt,
        exceptionalReturn: 0,
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
    return Qjs.installInterruptHandler(runtime, _callable!.nativeFunction);
  }

  /// 为一次求值装备预算：到点或超指令数即中断。
  static void arm(
    Pointer<JsRuntimeHandle> runtime,
    Duration timeout,
    int maxInstructions,
  ) {
    _armings[runtime.address] = SandboxArming(
      deadlineMillis: DateTime.now().millisecondsSinceEpoch +
          timeout.inMilliseconds,
      ticksLeft: maxInstructions ~/ instructionsPerTick,
    );
  }

  static void disarm(Pointer<JsRuntimeHandle> runtime) =>
      _armings.remove(runtime.address);

  /// 本次求值因何被中断；未被中断则为 null。
  static SandboxInterrupt? takenReason(Pointer<JsRuntimeHandle> runtime) =>
      _armings[runtime.address]?.fired;

  /// 中断判定，独立成纯函数便于单测覆盖指令计数分支。
  static bool shouldInterrupt(
    SandboxArming arming,
    int nowMillis, {
    bool countTick = true,
  }) {
    if (arming.fired != null) return true;
    if (nowMillis >= arming.deadlineMillis) {
      arming.fired = SandboxInterrupt.timeout;
      return true;
    }
    if (countTick) {
      arming.ticksLeft--;
      if (arming.ticksLeft <= 0) {
        arming.fired = SandboxInterrupt.instructions;
        return true;
      }
    }
    return false;
  }

  static int _onInterrupt(Pointer<JsRuntimeHandle> runtime, Pointer<Void> opaque) {
    final arming = _armings[runtime.address];
    if (arming == null) return 0;
    return shouldInterrupt(arming, DateTime.now().millisecondsSinceEpoch) ? 1 : 0;
  }
}
