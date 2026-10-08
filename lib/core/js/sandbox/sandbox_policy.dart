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

  /// 单次操作（求值 / 调用）的墙钟预算。构造后由 [clamped] 强制收敛到
  /// [minTimeout]~[maxTimeout]，越界配置不会生效。
  ///
  /// 上限从 5 秒放宽到 10 秒（真机反馈）：原区间是按「本地/快站」定的，
  /// 而列表接口走的是远端站点，**慢站点 + 移动网络下 4 秒经常不够**——
  /// 表现是「同样的源在别的阅读器很快、在这里超时」。
  ///
  /// 默认值 6 → **10 秒**（用户口径：对全部图源统一放宽；真机反馈大鸟禁漫的
  /// `home()` 报「执行超时:调用超时」——那一档预算里**含网络等待**，两个板块
  /// 各一次慢请求就顶到 6 秒了）。10 是区间上沿：既给慢站足额余量，失控脚本
  /// 也仍在 10 秒内被兜住（纯 CPU 死循环另由指令计数与中断处理器兜，
  /// 指令预算随超时同向放大，见 [instructionsFor]）。
  static const Duration minTimeout = Duration(seconds: 3);
  static const Duration maxTimeout = Duration(seconds: 10);
  static const Duration defaultTimeout = Duration(seconds: 10);

  static const int defaultMemoryLimitBytes = 64 * 1024 * 1024;

  /// JS 栈上限。**这是一个已实测的进程级崩溃开关，不能随手调大。**
  ///
  /// quickjs 靠 `JS_SetMaxStackSize` 在栈上留出余量，递归超限时抛可捕获的
  /// `RangeError: Maximum call stack size exceeded`；但这个余量必须小于宿主线程
  /// 的真实可用栈，否则守卫还没来得及触发，进程就已经撞穿 OS 栈直接死掉
  /// （无异常、无日志、整进程消失）。
  ///
  /// 实测（Windows x64，无限递归脚本 `function f(n){return f(n+1);} f(0);`）：
  /// - 768KB / 900KB / 960KB：正常抛出 RangeError，上下文可继续使用；
  /// - **1024KB（原默认值）：进程当场死亡**，测试进程连结果都发不回来。
  ///
  /// 因此取 512KB：既有 2 倍安全余量（实测边界在 960–1024KB 之间），又足够
  /// 承载真实图源脚本的递归深度（脚本解析 HTML / JSON 的常规递归远低于此）。
  static const int defaultStackLimitBytes = 512 * 1024;

  /// 指令计数上限。原生中断通路可用时（`third_party/quickjs_engine` 的补丁
  /// 已导出 `JS_SetInterruptHandler`）按 10000 条指令一次 tick 折算成 tick 预算，
  /// 耗尽即中断；通路不可用时退化为记录（见 [SandboxGuard]）。
  static const int defaultMaxInstructions = 200 * 1000 * 1000;

  /// 按墙钟预算换算指令预算：**每秒 5000 万条**，下限就是 [defaultMaxInstructions]。
  ///
  /// 为什么要换算而不是写死（用户口径：大运算量的解析要能过）：指令计数是
  /// 「防纯 CPU 空转」的兜底，墙钟超时才是一级闸门（可在设置里调 3–10s）。
  /// 两者本来就该同向：超时调到 10s 的用户，等于明说「这个源解析重、我愿意等」，
  /// 指令预算还卡在 6s 的量就不合理。纯死循环依旧会在墙钟到点时被回收。
  static int instructionsFor(Duration timeout) {
    final scaled = timeout.inMilliseconds * 50000;
    return scaled > defaultMaxInstructions ? scaled : defaultMaxInstructions;
  }

  /// 单次操作内允许的宿主代理调用次数。
  ///
  /// 64 → 256（真机反馈）：脚本一次列表/详情里并发发十几个 http 是常态
  /// （逐条目取详情、并发拉多页），64 会在正常脚本上先撞线，表现成
  /// 「莫名其妙的脚本错误」而不是网络问题。
  static const int defaultMaxHostCalls = 256;

  /// 单次操作内允许的引擎步数（求值 + 微任务排空 + 宿主回调往返 + 定时器注册）。
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
///
/// 记账口径（**能约束什么、不能约束什么，以代码为准，不靠注释承诺**）：
/// - [spendStep]：一次操作内与外界交互的总步数（求值 + 微任务轮 + 宿主往返 +
///   定时器注册），每次调用前记一步；
/// - [spendJobRound] / [spendHostCall]：微任务轮数与宿主往返数各自的细账；
/// - **看不见的**：纯 CPU 空转（`while(true){}`）不与外界交互，Dart 侧记不到账，
///   只能由原生中断通路打断（见 `SandboxGuard`）。
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

  /// 记一步「与外界交互」的动作；返回 false 表示预算已耗尽。
  ///
  /// 调用点（四处，覆盖一次操作里所有能让 JS 继续跑下去的入口）：
  /// 求值前、每轮微任务排空、每次宿主往返、每次定时器注册。
  bool spendStep() => ++_steps <= policy.maxSteps;

  /// 记一次宿主代理调用；返回 false 表示预算已耗尽。
  bool spendHostCall() => ++_hostCalls <= policy.maxHostCalls;

  /// 记一轮微任务排空；返回 false 表示预算已耗尽。
  bool spendJobRound() => ++_jobRounds <= policy.maxJobRounds;
}
