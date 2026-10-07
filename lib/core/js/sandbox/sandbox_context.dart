import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../util/lume_log.dart';
import '../qjs_bindings.dart';
import 'sandbox_guard.dart';
import 'sandbox_host.dart';
import 'sandbox_policy.dart';
import 'sandbox_polyfill.dart';
import 'sandbox_result.dart';

/// 单个互相隔离的 JSContext。
///
/// 一个实例独占一个 JSRuntime + JSContext：独立的内存上限、栈上限、中断装备
/// 与定时器表；JS 侧看不到任何其他上下文的状态。所有对外能力都必须经
/// [SandboxHost] 代理，JS 里没有文件、socket 或进程入口。
class SandboxContext {
  SandboxContext._(
    this.id,
    this.policy,
    this.host,
    this.polyfills,
    this._runtime,
    this._context,
  );

  /// 沙箱标识，用于日志与宿主侧的隔离判定。
  final String id;

  /// 运行策略。
  final SandboxPolicy policy;

  /// 外部能力代理。默认 [DenyAllSandboxHost]。
  final SandboxHost host;

  /// 垫片登记表，每个新上下文都会重新注入。
  final PolyfillRegistry polyfills;

  final Pointer<JsRuntimeHandle> _runtime;
  final Pointer<JsContextHandle> _context;

  /// 原生库存在即可创建沙箱。
  static bool get isSupported => Qjs.isAvailable;

  /// 可用性描述，用于日志与降级提示。
  static String get availabilityDetail => Qjs.availabilityDetail;

  /// 原生中断通路是否可用。不可用时超时保护退化为预算机制。
  static bool get interruptAvailable => SandboxGuard.interruptAvailable;

  /// context 地址 → 实例。插件 C 桥的 channel 表是全局的且不校验来源
  /// context，因此统一注册同一个回调，在此按 context 精确分发，
  /// 避免多沙箱串线（已实测：两个上下文各自拿到自己的 ctx 指针）。
  static final Map<int, SandboxContext> _instances = <int, SandboxContext>{};

  static NativeCallable<JsChannelCallback>? _bridge;

  /// 在册的上下文数量，用于诊断。
  static int get liveCount => _instances.length;

  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, Completer<SandboxResult>> _pendingCalls =
      <String, Completer<SandboxResult>>{};

  SandboxBudget? _budget;
  SandboxError? _lastError;
  int _sequence = 0;
  int _evalDepth = 0;
  bool _destroyed = false;
  bool _poisoned = false;
  SandboxError? _poisonReason;

  static SandboxContext create({
    required String id,
    required SandboxPolicy policy,
    required SandboxHost host,
    PolyfillRegistry? polyfills,
  }) {
    if (!isSupported) {
      throw StateError('沙箱不可用（${Qjs.availabilityDetail}）');
    }
    final effective = policy.clamped();
    final runtime = Qjs.newRuntime();
    SandboxGuard.attach(runtime, effective);
    _bridge ??= NativeCallable<JsChannelCallback>.isolateLocal(_onBridgeMessage);
    final context = Qjs.newContext(
      runtime,
      _bridge!.nativeFunction,
      _bridge!.nativeFunction,
      _bridge!.nativeFunction,
    );
    final instance = SandboxContext._(
      id,
      effective,
      host,
      polyfills ?? PolyfillRegistry.empty,
      runtime,
      context,
    );
    _instances[context.address] = instance;
    instance._bootstrap();
    return instance;
  }

  bool get isDestroyed => _destroyed;

  /// 上下文是否已被判定污染。污染后不得再执行任何脚本。
  bool get isPoisoned => _poisoned;

  SandboxError? get poisonReason => _poisonReason;

  /// 最近一次求值失败的原因。
  SandboxError? get lastError => _lastError;

  int get pendingCallCount => _pendingCalls.length;

  int get timerCount => _timers.length;

  // ------------------------------------------------------------------ 操作期

  /// 标记一次操作的开始，之后所有求值从该预算记账。
  void beginOperation(SandboxBudget budget) => _budget = budget;

  void endOperation() => _budget = null;

  SandboxBudget get _activeBudget =>
      _budget ??= SandboxBudget(policy, DateTime.now());

  // ------------------------------------------------------------------ 求值

  /// 载入脚本源码。脚本语法错误不会污染上下文（异常已被消费），
  /// 由调用方决定是否重建。
  SandboxResult loadSource(String source) => evalJson(source, fileName: '$id.js');

  /// 同步求值并把脚本返回值按 JSON 解码。
  SandboxResult evalJson(String code, {String? fileName}) {
    final text = _evaluate(code, fileName: fileName);
    if (text == null) {
      final failure = _lastError ?? const SandboxError(SandboxErrorKind.engine, '未知错误');
      return SandboxFailure(failure.kind, failure.message);
    }
    if (text.length > policy.maxResultChars) {
      final message = '结果超出上限（${text.length} > ${policy.maxResultChars}）';
      _fail(SandboxErrorKind.protocol, message);
      return SandboxFailure(SandboxErrorKind.protocol, message);
    }
    return SandboxSuccess(_decode(text));
  }

  /// Dart → JS：按路径调用全局函数（如 `LumeSource.latest`），结果以 JSON 回传。
  ///
  /// 参数与返回值都必须是 JSON 可序列化的值。调用过程会持续驱动宿主代理
  /// 往返与微任务排空，直到脚本给出结果、或预算耗尽。
  Future<SandboxResult> call(String path, [Object? argument]) async {
    if (_destroyed) {
      return const SandboxFailure(SandboxErrorKind.disposed, '沙箱已释放');
    }
    if (_poisoned) {
      final reason = _poisonReason;
      return SandboxFailure(
        reason?.kind ?? SandboxErrorKind.engine,
        reason?.message ?? '上下文已污染',
      );
    }
    final argumentJson = argument == null ? 'null' : jsonEncode(argument);
    final callId = 'c${_sequence++}';
    final completer = Completer<SandboxResult>();
    _pendingCalls[callId] = completer;
    try {
      final posted = _evaluate(
        '__lumeInvoke(${_jsString(callId)}, ${_jsString(path)}, '
        '${_jsString(argumentJson)});',
        fileName: '$id.call.js',
      );
      if (posted == null) {
        final failure =
            _lastError ?? const SandboxError(SandboxErrorKind.engine, '未知错误');
        return SandboxFailure(failure.kind, failure.message);
      }
      return await completer.future.timeout(_activeBudget.remaining);
    } on TimeoutException {
      final message = '调用超时: $path';
      _fail(SandboxErrorKind.timeout, message);
      return SandboxFailure(SandboxErrorKind.timeout, message);
    } catch (error) {
      final message = '调用失败: $error';
      _fail(SandboxErrorKind.engine, message);
      return SandboxFailure(SandboxErrorKind.engine, message);
    } finally {
      _pendingCalls.remove(callId);
    }
  }

  // ------------------------------------------------------------------ 销毁

  /// 释放上下文。可重复调用。
  ///
  /// 恒释放 JSContext（这会回收整个全局对象图）；是否释放 JSRuntime
  /// 取决于 [Qjs.reclaimRuntime]——断言型构建下释放会触发 quickjs 的
  /// 泄漏断言并 abort 进程（已实测），此时改为记账放弃。
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final completer in _pendingCalls.values) {
      if (!completer.isCompleted) {
        completer.complete(
          const SandboxFailure(SandboxErrorKind.disposed, '上下文已释放'),
        );
      }
    }
    _pendingCalls.clear();
    _instances.remove(_context.address);
    SandboxGuard.disarm(_runtime);
    try {
      Qjs.freeContext(_context);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    Qjs.releaseRuntime(_runtime);
  }

  // -------------------------------------------------------------- 内部：求值

  /// 同步求值，成功返回结果文本（未解码），失败返回 null 并写入 [_lastError]。
  String? _evaluate(String code, {String? fileName}) {
    if (_destroyed) {
      _lastError = const SandboxError(SandboxErrorKind.disposed, '上下文已释放');
      return null;
    }
    if (_poisoned) {
      _lastError = _poisonReason;
      return null;
    }
    _evalDepth++;
    // 求值本身也是一步「与外界交互」：纯 CPU 空转在求值内部发生（Dart 看不见，
    // 只能靠原生中断），但「脚本反复求值 / 反复排空微任务」这类慢速失控必须记账。
    if (!_activeBudget.spendStep()) {
      _evalDepth--;
      _fail(SandboxErrorKind.instructions, '操作步数超出预算（求值）');
      return null;
    }
    final bytes = utf8.encode(code);
    final input = calloc<Uint8>(bytes.length + 1);
    final file = (fileName ?? '$id.js').toNativeUtf8();
    Pointer<JsValueHandle>? value;
    try {
      input.asTypedList(bytes.length + 1).setAll(0, bytes);
      SandboxGuard.arm(_runtime, _activeBudget.remaining, policy.maxInstructions);
      value = Qjs.evaluate(
        _context,
        input.cast<Utf8>(),
        bytes.length,
        file,
        jsEvalTypeGlobal,
      );
      if (value == nullptr) {
        _lastError = const SandboxError(SandboxErrorKind.engine, '原生求值返回空指针');
        _fail(SandboxErrorKind.engine, _lastError!.message);
        return null;
      }
      if (Qjs.valueTag(value) == jsTagException) {
        // 关键：立刻消费掉上下文里的待处理异常。quickjs 会把未消费的异常
        // 留给下一次求值，形成「上下文被污染」的假象（已实测）。
        final error = _errorFrom(_takeException());
        _lastError = error;
        if (error.kind != SandboxErrorKind.script || policy.poisonOnScriptError) {
          _fail(error.kind, error.message);
        }
        return null;
      }
      final text = _readString(value);
      if (text == null) {
        _lastError = const SandboxError(SandboxErrorKind.engine, '结果无法转换为字符串');
        _fail(SandboxErrorKind.engine, _lastError!.message);
        return null;
      }
      // 预算补判：求值是同步原生调用，期间 Dart 事件循环无法运行；原生中断通路
      // 不可用时（JS_SetInterruptHandler 未导出）超时只能在这一刻核对。脚本虽然
      // 跑完并返回了值，但耗时已越过墙钟预算，同样按超时处理——否则一段 CPU
      // 空转 8 秒的脚本会被当成正常结果收下，3–5 秒预算形同虚设。
      final budget = _budget;
      if (budget != null && budget.isExpired) {
        final message = '执行超时（${budget.elapsed.inMilliseconds}ms > '
            '${budget.policy.timeout.inMilliseconds}ms）';
        _lastError = SandboxError(SandboxErrorKind.timeout, message);
        _fail(SandboxErrorKind.timeout, message);
        return null;
      }
      _lastError = null;
      // 求值文本先记下，等排空阶段结束后再决定要不要交出去（见 finally）。
      // 不在 try 里直接 return，是因为「排空期间被判定失控」必须能收回这个结果。
      return _settleAfterDrain(text, value);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _lastError = SandboxError(SandboxErrorKind.engine, '$error');
      _fail(SandboxErrorKind.engine, '$error');
      return _releaseAndDrain(value, input, file, null);
    }
  }

  /// 求值成功后的收尾：先释放原生资源、排空微任务，再决定交不交出结果。
  ///
  /// 中断装备必须一直保持到微任务排空结束：`async` 方法体在 `await` 之后的部分
  /// 是在**排空阶段**执行的（`_drainJobs` → `executePendingJob`），纯 CPU 死循环
  /// 正是在这一步占住线程。此前这里是「先 disarm 再 drain」，中断处理器在排空
  /// 期间读不到装备记录、直接放行，死循环因此永远收不回来（实测：预算 3s，
  /// 等 12s 仍在栈上，栈顶就是 `_drainJobs` → `executePendingJob`）。
  ///
  /// 解除与装备一样按求值深度收口：嵌套求值（宿主回填会再进 `_evaluate`）
  /// 退出时不得提前解除外层仍在使用的装备。
  ///
  /// 排空阶段也可能把上下文判废（例如脚本把微任务排成无限链，撞上
  /// `maxJobRounds` / `maxSteps`）。此时求值本身是成功返回的，但那不是真实结论
  /// ——脚本并没有正常跑完。所以要在排空之后再看一次污染标记，否则失控脚本会被
  /// 当成正常结果收下（实测：无限微任务链返回 isOk=true，同时上下文已被销毁重建）。
  /// 与「跑得完但跑太久」同一口径：以预算账本为准。
  String? _settleAfterDrain(String text, Pointer<JsValueHandle>? value) {
    _releaseNative(value);
    if (--_evalDepth == 0) {
      try {
        _drainJobs();
      } finally {
        SandboxGuard.disarm(_runtime);
      }
      if (_poisoned) {
        _lastError = _poisonReason;
        return null;
      }
    }
    return text;
  }

  /// 失败路径的收尾：释放原生资源并排空（结果本就为 null）。
  String? _releaseAndDrain(
    Pointer<JsValueHandle>? value,
    Pointer<Uint8> input,
    Pointer<Utf8> file,
    String? result,
  ) {
    _releaseNative(value);
    malloc.free(input);
    malloc.free(file);
    if (--_evalDepth == 0) {
      try {
        _drainJobs();
      } finally {
        SandboxGuard.disarm(_runtime);
      }
    }
    return result;
  }

  /// 释放本次求值的原生资源（返回值与输入缓冲）。
  void _releaseNative(Pointer<JsValueHandle>? value) {
    if (value != null && value != nullptr) {
      try {
        Qjs.freeValue(_context, value, 1);
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
  }

  /// 取出并清除待处理异常，返回可读文本。
  String _takeException() {
    Pointer<JsValueHandle>? exception;
    try {
      exception = Qjs.getException(_context);
      if (exception == nullptr) return '未知脚本错误';
      final text = _readString(exception);
      return text ?? '未知脚本错误';
    } catch (error) {
      return '$error';
    } finally {
      if (exception != null && exception != nullptr) {
        try {
          Qjs.freeValue(_context, exception, 1);
        } catch (error, stackTrace) {
          LumeLog.error(error, stackTrace);
        }
      }
    }
  }

  String? _readString(Pointer<JsValueHandle> value) {
    final text = Qjs.toCString(_context, value);
    if (text == nullptr) return null;
    try {
      return text.toDartString();
    } finally {
      Qjs.freeCString(_context, text);
    }
  }

  /// 把异常文本归类，并给出**可读的原因**。引擎级错误会销毁上下文，
  /// 脚本错误默认不销毁。
  ///
  /// 为什么不能只回分类、把引擎原文当消息：原生中断抛出的原文固定是
  /// `InternalError: interrupted`——它只说明「被打断了」，说不出**被哪条预算
  /// 打断**。这台机器上先撞哪条预算取决于负载（空闲时先撞 4 秒墙钟，有负载时
  /// 先撞指令计数），所以同一段脚本的报错文案会飘——用户看到的是引擎内部串，
  /// 拿不到任何能行动的信息。这里统一换成中断原因的中文名，与墙钟补判路径
  /// （「执行超时（…ms > …ms）」）的口径对齐。
  SandboxError _errorFrom(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('interrupted')) {
      final reason = SandboxGuard.takenReason(_runtime);
      final kind = reason == SandboxInterrupt.instructions
          ? SandboxErrorKind.instructions
          : SandboxErrorKind.timeout;
      // reason 为空说明中断发生在装备窗口之外（理论上不出现）；此时按 [kind]
      // 已有的默认走超时，文案随之取「执行超时」，不谎报一个没观测到的原因。
      final label = (reason ?? SandboxInterrupt.timeout).label;
      return SandboxError(kind, '$label（脚本被原生中断回收）');
    }
    if (lower.contains('out of memory') || lower.contains('stack overflow')) {
      return SandboxError(SandboxErrorKind.memory, message);
    }
    return SandboxError(SandboxErrorKind.script, message);
  }

  /// 有界排空微任务队列，推进 Promise 链。返回 false 表示超预算。
  bool _drainJobs() {
    while (!_destroyed && !_poisoned) {
      int outcome;
      try {
        outcome = Qjs.executePendingJob(_runtime);
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
        _fail(SandboxErrorKind.engine, '$error');
        return false;
      }
      // 墙钟补判：单个任务体是同步原生调用，事件循环在它执行期间无法运行，
      // Dart 侧的 `.timeout()` 也就没机会触发。原生中断通路不可用时，一个
      // CPU 空转数秒的任务体会被原样收下——必须在这里核对预算，否则 3–5 秒
      // 的墙钟上限对「跑得完但跑太久」的脚本形同虚设。
      if (_activeBudget.isExpired) {
        _fail(
          SandboxErrorKind.timeout,
          '执行超时（${_activeBudget.elapsed.inMilliseconds}ms > '
          '${policy.timeout.inMilliseconds}ms）',
        );
        return false;
      }
      if (outcome == 0) return true;
      if (outcome < 0) {
        // 任务体内抛出的异常同样会留在上下文里，必须消费。
        final error = _errorFrom(_takeException());
        _lastError = error;
        if (error.kind != SandboxErrorKind.script || policy.poisonOnScriptError) {
          _fail(error.kind, error.message);
          return false;
        }
        continue;
      }
      if (!_activeBudget.spendJobRound() || !_activeBudget.spendStep()) {
        _fail(SandboxErrorKind.instructions, '微任务排空超出预算');
        return false;
      }
    }
    return !_poisoned;
  }

  /// 标记上下文已被污染。真正的销毁交给持有者在下一次安全点执行，
  /// 避免在原生回调栈上重入释放。
  ///
  /// 同时在飞的全部调用请求会立即以该原因结束，保证「超时 → 销毁重建」
  /// 这条链路的观察结果稳定（不受宿主超时与操作超时谁先到的影响）。
  void _fail(SandboxErrorKind kind, String message) {
    if (_poisoned) return;
    _poisoned = true;
    _poisonReason = SandboxError(kind, message);
    for (final completer in _pendingCalls.values) {
      if (!completer.isCompleted) {
        completer.complete(SandboxFailure(kind, message));
      }
    }
    LumeLog.warn('[$id] 沙箱上下文判定污染（${kind.id}）: $message');
  }

  // ------------------------------------------------------------ 内部：桥接

  void _bootstrap() {
    final prelude = _evaluate(_prelude, fileName: 'prelude.js');
    if (prelude == null) {
      final failure = _lastError;
      destroy();
      throw StateError('沙箱 prelude 注入失败: $failure');
    }
    final bootstrap = polyfills.bootstrap();
    if (bootstrap.isEmpty) return;
    final injected = _evaluate(bootstrap, fileName: 'polyfill.js');
    if (injected == null) {
      final failure = _lastError;
      destroy();
      throw StateError('垫片注入失败: $failure');
    }
  }

  void _handleMessage(String message) {
    Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (error) {
      LumeLog.warn('[$id] 桥消息不是合法 JSON: $message');
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['action']) {
      case 'console':
        _handleConsole(decoded);
      case 'host':
        unawaited(_handleHostCall(decoded));
      case 'timeout':
        _handleTimeout(decoded);
      case 'result':
        _handleResult(decoded);
    }
  }

  void _handleConsole(Map<dynamic, dynamic> payload) {
    final args = (payload['args'] as List?)?.map((item) => '$item').join(' ');
    final line = '[$id] ${args ?? ''}';
    switch (payload['level']) {
      case 'error':
        LumeLog.error(line);
      case 'warn':
        LumeLog.warn(line);
      default:
        LumeLog.info(line);
    }
  }

  Future<void> _handleHostCall(Map<dynamic, dynamic> payload) async {
    final callId = '${payload['id']}';
    final method = '${payload['method']}';
    if (_destroyed || _poisoned) return;
    if (!policy.allowHostAccess) {
      _settleHost(callId, false, '沙箱未开放外部能力: $method');
      return;
    }
    if (!_activeBudget.spendHostCall() || !_activeBudget.spendStep()) {
      _fail(SandboxErrorKind.instructions, '宿主调用超出预算: $method');
      _settleHost(callId, false, '宿主调用超出预算');
      return;
    }
    try {
      final value = await host
          .invoke(
            SandboxHostRequest(
              sandboxId: id,
              method: method,
              payload: payload['payload'],
            ),
          )
          .timeout(_activeBudget.remaining);
      if (_destroyed || _poisoned) return;
      try {
        _settleHost(callId, true, jsonEncode(value));
      } catch (error) {
        _settleHost(callId, false, '宿主返回无法序列化: $error');
      }
    } on TimeoutException {
      _fail(SandboxErrorKind.timeout, '宿主调用超时: $method');
      _settleHost(callId, false, '宿主调用超时: $method');
    } catch (error) {
      _settleHost(callId, false, '$error');
    }
  }

  void _settleHost(String callId, bool ok, String text) {
    if (_destroyed || _poisoned) return;
    _evaluate(
      '__lumeHostSettle(${_jsString(callId)}, ${ok ? 'true' : 'false'}, '
      '${_jsString(text)});',
      fileName: '$id.host.js',
    );
  }

  void _handleTimeout(Map<dynamic, dynamic> payload) {
    final timerId = '${payload['id']}';
    final delay = (payload['delay'] as num?)?.toInt() ?? 0;
    _timers.remove(timerId)?.cancel();
    if (_destroyed || _poisoned || !_activeBudget.spendStep()) return;
    if (_timers.length >= policy.maxTimers) {
      LumeLog.warn('[$id] 定时器数量超出上限（${policy.maxTimers}），已忽略 $timerId');
      return;
    }
    _timers[timerId] = Timer(Duration(milliseconds: delay), () {
      _timers.remove(timerId);
      if (_destroyed || _poisoned) return;
      _evaluate('__lumeTimer(${_jsString(timerId)});', fileName: '$id.timer.js');
    });
  }

  void _handleResult(Map<dynamic, dynamic> payload) {
    final callId = '${payload['id']}';
    final completer = _pendingCalls[callId];
    if (completer == null || completer.isCompleted) return;
    final raw = payload['text'];
    final text = raw == null ? 'null' : '$raw';
    if (payload['ok'] != true) {
      // 走桥的调用（`__lumeInvoke` 的 catch 分支）只会带回异常文本，分类要靠
      // 文本还原——否则「脚本方法体内堆爆了」会被当成可捕获的普通脚本错误，
      // 于是一个内存已失控的上下文被原样留着继续用。引擎级错误（内存/栈/
      // 中断）无论策略如何都必须销毁上下文，这条口径与直接求值路径一致。
      final error = _errorFrom(text);
      _lastError = error;
      if (error.kind != SandboxErrorKind.script || policy.poisonOnScriptError) {
        _fail(error.kind, error.message);
      }
      _settle(completer, SandboxFailure(error.kind, error.message));
      return;
    }
    if (text.length > policy.maxResultChars) {
      final message = '结果超出上限（${text.length} > ${policy.maxResultChars}）';
      _fail(SandboxErrorKind.protocol, message);
      _settle(completer, SandboxFailure(SandboxErrorKind.protocol, message));
      return;
    }
    // 墙钟补判：单个任务体是同步原生调用，事件循环在它执行期间无法运行，
    // 因此 `.timeout()` 拦不住「跑得完但跑太久」的脚本——结果会在排空微任务时
    // 直接被投递回来。原生中断通路不可用时，这里是唯一能核对预算的关口：
    // 已越过 3–5 秒上限的结果一律按超时处理，否则预算形同虚设。
    if (_activeBudget.isExpired) {
      final message = '执行超时（${_activeBudget.elapsed.inMilliseconds}ms > '
          '${policy.timeout.inMilliseconds}ms）';
      _fail(SandboxErrorKind.timeout, message);
      _settle(completer, SandboxFailure(SandboxErrorKind.timeout, message));
      return;
    }
    _settle(completer, SandboxSuccess(_decode(text)));
  }

  /// 投递调用结果，且只投一次。
  ///
  /// [_fail] 会立刻把在飞的调用以污染原因结束（保证「超时 → 销毁重建」这条
  /// 链路的观察结果稳定），因此这里必须允许「已经被完成」——否则判定污染之后
  /// 再补一次 `complete` 会抛 `Bad state: Future already completed`，
  /// 把一次正常的超时处理变成引擎级异常。
  void _settle(Completer<SandboxResult> completer, SandboxResult result) {
    if (completer.isCompleted) return;
    completer.complete(result);
  }

  /// 结果文本解码：合法 JSON 就解码，否则按字符串返回。
  Object? _decode(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}

/// 把 Dart 字符串转成安全的 JS 字符串字面量。
String _jsString(String value) {
  final buffer = StringBuffer("'");
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x27: // '
        buffer.write(r"\'");
      case 0x5C: // \
        buffer.write(r'\\');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x2028:
        buffer.write(r'\u2028');
      case 0x2029:
        buffer.write(r'\u2029');
      default:
        if (unit < 0x20) {
          buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          buffer.writeCharCode(unit);
        }
    }
  }
  buffer.write("'");
  return buffer.toString();
}

/// C 桥入口：按来源 context 分发，并回填 JS_NULL。
Pointer<JsValueHandle> _onBridgeMessage(
  Pointer<JsContextHandle> context,
  Pointer<Utf8> channel,
  Pointer<Utf8> message,
) {
  final instance = SandboxContext._instances[context.address];
  if (instance != null && !instance._destroyed) {
    try {
      instance._handleMessage(message.toDartString());
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }
  return Qjs.nullValue;
}

/// JS 侧运行时垫片：console / 定时器 / 宿主代理 / 调用信封。
///
/// 这是沙箱与脚本之间的唯一契约面。除 [LumeBridge] 之外不存在任何
/// 访问系统资源的入口；`fetch`、文件、进程等能力一律由宿主代理提供，
/// 需要时以 Polyfill 或 [SandboxHostMethods] 实现，不在沙箱层内置。
const String _prelude = r'''
(function () {
  var pendingHost = {};
  var seq = 0;

  function post(payload) {
    FLUTTER_JS_NATIVE_BRIDGE_sendMessage('SendNative', JSON.stringify(payload));
  }

  function nextId(prefix) { return prefix + (seq++); }

  function stringifyArgs(args) {
    return Array.prototype.map.call(args, function (item) {
      if (typeof item === 'string') return item;
      try { return JSON.stringify(item); } catch (e) { return String(item); }
    });
  }

  globalThis.console = {
    log: function () { post({ action: 'console', level: 'log', args: stringifyArgs(arguments) }); },
    warn: function () { post({ action: 'console', level: 'warn', args: stringifyArgs(arguments) }); },
    error: function () { post({ action: 'console', level: 'error', args: stringifyArgs(arguments) }); }
  };

  globalThis.LumeBridge = {
    invoke: function (method, payload) {
      return new Promise(function (resolve, reject) {
        var id = nextId('h');
        pendingHost[id] = { resolve: resolve, reject: reject };
        post({
          action: 'host',
          id: id,
          method: String(method),
          payload: payload === undefined ? null : payload
        });
      });
    }
  };

  globalThis.__lumeHostSettle = function (id, ok, text) {
    var entry = pendingHost[id];
    if (!entry) return;
    delete pendingHost[id];
    if (ok) {
      var value = null;
      try { value = JSON.parse(text); } catch (e) { value = null; }
      entry.resolve(value);
    } else {
      entry.reject(new Error(text));
    }
  };

  globalThis.__lumeInvoke = function (requestId, path, payloadJson) {
    Promise.resolve()
      .then(function () {
        var parts = String(path).split('.');
        var target = globalThis;
        for (var i = 0; i < parts.length - 1; i++) {
          target = target[parts[i]];
          if (target === undefined || target === null) {
            throw new Error('全局对象不存在: ' + parts.slice(0, i + 1).join('.'));
          }
        }
        var name = parts[parts.length - 1];
        var fn = target[name];
        if (typeof fn !== 'function') {
          throw new Error('方法不存在: ' + path);
        }
        var argument = payloadJson === null ? undefined : JSON.parse(payloadJson);
        return fn.call(target, argument);
      })
      .then(function (value) {
        post({
          action: 'result',
          id: requestId,
          ok: true,
          text: JSON.stringify(value === undefined ? null : value)
        });
      })
      .catch(function (error) {
        post({
          action: 'result',
          id: requestId,
          ok: false,
          text: String(error && error.message ? error.message : error)
        });
      });
  };

  globalThis.__lumeTimers = {};

  globalThis.setTimeout = function (fn, delay) {
    var id = nextId('t');
    globalThis.__lumeTimers[id] = fn;
    post({ action: 'timeout', id: id, delay: Number(delay) || 0 });
    return id;
  };

  globalThis.clearTimeout = function (id) { delete globalThis.__lumeTimers[id]; };

  globalThis.__lumeTimer = function (id) {
    var fn = globalThis.__lumeTimers[id];
    if (!fn) return;
    delete globalThis.__lumeTimers[id];
    try { fn(); } catch (e) { console.error(e && e.message ? e.message : e); }
  };
})();
''';
