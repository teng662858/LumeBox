/// 沙箱运行策略。所有上限在这里集中声明，运行期不再散落到业务代码里。
///
/// 数值全部由 [SandboxPolicy.standard] / [SandboxPolicy.strict] 两个预设给出，
/// 业务侧若要自定义，建议基于预设做 `copyWith` 而不是从零构造。
class SandboxPolicy {
  const SandboxPolicy({
    this.timeout = defaultTimeout,
    this.memoryLimitBytes = defaultMemoryLimitBytes,
    this.stackLimitBytes = defaultStackLimitBytes,
    this.maxInstructions = defaultMaxInstructions,
    this.maxHostCalls = defaultMaxHostCalls,
    this.maxSteps = defaultMaxSteps,
    this.maxJobRounds = defaultMaxJobRounds,
    this.maxTimers = defaultMaxTimers,
    this.maxResultChars = defaultMaxResultChars,
    this.allowHostAccess = false,
    this.poisonOnScriptError = false,
  });

  /// 单次操作（求值 / 调用）的墙钟预算。文档要求 3–5 秒，构造后由
  /// [clamped] 强制收敛到该区间，越界配置不会生效。
  static const Duration minTimeout = Duration(seconds: 3);
  static const Duration maxTimeout = Duration(seconds: 5);
  static const Duration defaultTimeout = Duration(seconds: 4);

  static const int defaultMemoryLimitBytes = 64 * 1024 * 1024;
  static const int defaultStackLimitBytes = 1024 * 1024;

  /// 指令计数上限。仅在原生中断通路可用时能真正生效（见 [SandboxGuard]）；
  /// 当前插件构建未导出 `JS_SetInterruptHandler`，因此它同时充当记录与预留。
  static const int defaultMaxInstructions = 200 * 1000 * 1000;

  /// 单次操作内允许的宿主代理调用次数。
  static const int defaultMaxHostCalls = 64;

  /// 单次操作内允许的引擎步数（求值 + 微任务排空 + 宿主回调往返）。
  static const int defaultMaxSteps = 4096;

  /// 单次求值最多排空的微任务轮数，防止 Promise 自循环卡死。
  static const int defaultMaxJobRounds = 1024;

  /// 单个上下文同时挂起的 setTimeout 数量上限。
  static const int defaultMaxTimers = 32;

  /// 单次结果的最大字符数，超出即视为协议异常。
  static const int defaultMaxResultChars = 1024 * 1024;

  /// 单次操作的墙钟上限。
  final Duration timeout;

  /// QuickJS 堆上限。JS 侧分配型失控由它硬性中止。
  final int memoryLimitBytes;

  /// QuickJS 调用栈上限。
  final int stackLimitBytes;

  /// 指令计数上限。
  final int maxInstructions;

  /// 宿主代理调用次数上限。
  final int maxHostCalls;

  /// 引擎步数上限。
  final int maxSteps;

  /// 微任务排空轮数上限。
  final int maxJobRounds;

  /// 定时器数量上限。
  final int maxTimers;

  /// 结果字符数上限。
  final int maxResultChars;

  /// 是否开放宿主代理（IO / 网络）。默认关闭：JS 拿不到任何系统能力，
  /// 只有显式注入 [SandboxHost] 并打开该开关后，才允许经代理访问外部世界。
  final bool allowHostAccess;

  /// 脚本自身抛错时是否也销毁上下文。默认 false：可捕获的脚本错误在异常
  /// 被消费后上下文仍然干净（已实测），销毁只会白白丢掉脚本运行态。
  /// 引擎级错误（内存超限、栈溢出、中断）无论该值如何都会销毁上下文。
  final bool poisonOnScriptError;

  /// 默认策略：4 秒预算，不开放宿主能力。
  static const SandboxPolicy standard = SandboxPolicy();

  /// 严格策略：3 秒预算、更小的预算池，且脚本抛错即销毁上下文。
  static const SandboxPolicy strict = SandboxPolicy(
    timeout: minTimeout,
    maxHostCalls: 16,
    maxSteps: 512,
    maxJobRounds: 256,
    maxTimers: 8,
    maxResultChars: 256 * 1024,
    poisonOnScriptError: true,
  );

  /// 把超时收敛到文档规定的 3–5 秒区间。
  SandboxPolicy clamped() {
    if (timeout >= minTimeout && timeout <= maxTimeout) return this;
    final fixed = timeout < minTimeout ? minTimeout : maxTimeout;
    return copyWith(timeout: fixed);
  }

  SandboxPolicy copyWith({
    Duration? timeout,
    int? memoryLimitBytes,
    int? stackLimitBytes,
    int? maxInstructions,
    int? maxHostCalls,
    int? maxSteps,
    int? maxJobRounds,
    int? maxTimers,
    int? maxResultChars,
    bool? allowHostAccess,
    bool? poisonOnScriptError,
  }) {
    return SandboxPolicy(
      timeout: timeout ?? this.timeout,
      memoryLimitBytes: memoryLimitBytes ?? this.memoryLimitBytes,
      stackLimitBytes: stackLimitBytes ?? this.stackLimitBytes,
      maxInstructions: maxInstructions ?? this.maxInstructions,
      maxHostCalls: maxHostCalls ?? this.maxHostCalls,
      maxSteps: maxSteps ?? this.maxSteps,
      maxJobRounds: maxJobRounds ?? this.maxJobRounds,
      maxTimers: maxTimers ?? this.maxTimers,
      maxResultChars: maxResultChars ?? this.maxResultChars,
      allowHostAccess: allowHostAccess ?? this.allowHostAccess,
      poisonOnScriptError: poisonOnScriptError ?? this.poisonOnScriptError,
    );
  }

  @override
  String toString() => 'SandboxPolicy(timeout: ${timeout.inMilliseconds}ms, '
      'memory: $memoryLimitBytes, hostAccess: $allowHostAccess)';
}

/// 一次操作的预算账本。操作开始重置，跨异步回调共享同一实例。
///
/// 这是「指令计数上限保护」在 Dart 侧的落地形式：没有原生中断通路时，
/// JS 与外界的每一次交互都要在此记账，超支即判定沙箱失控。
class SandboxBudget {
  SandboxBudget(this.policy, DateTime startedAt) : _startedAt = startedAt;

  final SandboxPolicy policy;
  final DateTime _startedAt;

  int _steps = 0;
  int _hostCalls = 0;
  int _jobRounds = 0;

  int get steps => _steps;
  int get hostCalls => _hostCalls;
  int get jobRounds => _jobRounds;

  Duration get elapsed => DateTime.now().difference(_startedAt);

  /// 剩余墙钟预算，已耗尽时返回 [Duration.zero]。
  Duration get remaining {
    final left = policy.timeout - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  bool get isExpired => remaining == Duration.zero;

  /// 记一步引擎动作；返回 false 表示预算已耗尽。
  bool spendStep() => ++_steps <= policy.maxSteps;

  /// 记一次宿主代理调用；返回 false 表示预算已耗尽。
  bool spendHostCall() => ++_hostCalls <= policy.maxHostCalls;

  /// 记一轮微任务排空；返回 false 表示预算已耗尽。
  bool spendJobRound() => ++_jobRounds <= policy.maxJobRounds;
}
