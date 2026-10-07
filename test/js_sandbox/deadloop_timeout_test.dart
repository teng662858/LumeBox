import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

import 'support/js_sandbox_support.dart';

/// 安全测试第 1 条：死循环 & 超时销毁。
///
/// 三条要求，逐条验证：
/// - 失控脚本被中断并销毁 JSContext；
/// - App 不会卡死（一个图源失控不影响其它上下文与主线程）；
/// - 后续新请求可以重建全新上下文并正常工作。
///
/// 硬性要求：旧中毒上下文必须销毁释放资源，不允许复用已经卡死的实例。
///
/// 关于「纯 CPU 死循环」：原先这是本套件唯一**不成立**的安全属性——插件不导出
/// `JS_SetInterruptHandler`，纯 CPU 空转无人能打断。本轮已修复，且修的不止一处：
/// 1. `third_party/quickjs_engine` 的本地补丁重新导出该符号（见其 `PATCHES.md`）；
/// 2. `SandboxContext._evaluate` 原先「先 disarm 再 drain」，而 `async` 方法体
///    `await` 之后的部分正是在排空阶段执行的——死循环就卡在那里且中断已解除。
///    现在装备一直保持到排空结束。
void main() {
  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  setUp(enableEngineOnThisPlatform);
  tearDown(restoreEnginePlatformGate);

  group('1) 死循环 & 超时销毁', () {
    test(
      '1a 纯 CPU 死循环 while(true){}：应被中断并回收上下文',
      () async {
        // 纯 CPU 空转最凶险：不分配内存、不触碰宿主、不产生 Promise，只在字节码层
        // 无限空转，同时绕开内存上限、宿主调用 / 微任务预算与 Dart 侧墙钟超时
        // （同步 FFI 调用期间事件循环没有机会运行）。唯一能夺回控制权的手段是
        // 原生中断处理器，本轮已修复（符号导出 + 装备保持到排空结束）。
        final run = await runSandboxCallInWorker(
          script: fixture('deadloop_source.js'),
          method: 'list',
          budget: const Duration(seconds: 12),
        );
        addTearDown(run.kill);

        expect(
          run.armed,
          isTrue,
          reason: 'worker 应已进到调用脚本这一步（否则测的不是死循环）',
        );

        if (!run.completed) {
          // 未被回收：把中断通路的可用性一起留档，便于定位是「通路没接上」
          // 还是「通路可用但判定没生效」。
          expect(
            SandboxGuard.interruptAvailable,
            isFalse,
            reason: '中断通路可用却没能回收，说明问题不在中断通路，需要重新定位',
          );
          markTestSkipped(
            '中断通路不可用：纯 CPU 死循环无法被中断回收。'
            '本次观测：预算 3s，等待 ${run.waited.inSeconds}s 后仍未收尾；'
            'armed=${run.armed} completed=${run.completed} events=${run.events}。'
            '（需要 third_party/quickjs_engine 的补丁导出，见其 PATCHES.md）',
          );
          return;
        }

        // 被回收了：验证回收质量——判定为失控、且能重建全新上下文。
        final report = run.report!;
        //
        // 分类接受 timeout 与 instructions 两种：两者都是「失控被兜住」的正当
        // 结论，谁先到取决于脚本与预算的相对大小。默认指令预算
        // （2 亿条 / 每 10000 条一次 tick = 20000 tick）在这种纯空转里比 3 秒墙钟
        // 先耗尽，因此实际判定为 instructions；若把指令预算调得很大，则会先撞
        // 墙钟判 timeout。**关键是不能是 ok，也不能是 script**（不能把它当成
        // 脚本自己抛的普通错误）。
        expect(
          report['errorKind'],
          anyOf(SandboxErrorKind.timeout.id, SandboxErrorKind.instructions.id),
          reason: '死循环被回收时应判定为失控（超时或超出指令计数），而不是别的分类',
        );
        expect(
          report['generationAfter'],
          greaterThan(report['generation']! as int),
          reason: '回收后必须重建全新上下文（旧实例不复用）',
        );
        expect(report['rebuiltOk'], isTrue, reason: '重建后的上下文必须能正常干活');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '1b 超出预算但会返回的脚本：判定超时、销毁上下文，而不是当成正常结果',
      () async {
        // 脚本空转 6s 后正常返回；引擎预算是 4s（`LumeJsEngine.policy`）。
        // 刻意留出 2s 余量而不是卡在边界上：空转时长与预算相等时，
        // 「算不算超时」取决于毫秒级计时误差，断言会变成掷骰子。
        final engine = await openEngine(
          sourceId: 'smoke-overrun',
          script: fixture('deadloop_source.js'),
        );
        addTearDown(engine.dispose);
        final budget = LumeJsEngine.policy.timeout;

        final generationBefore = engine.generation;
        final liveBefore = SandboxContext.liveCount;
        final result = await engine.callResult(
          'boundedOverrun',
          <String, Object?>{'spinMs': budget.inMilliseconds + 2000},
        );

        expect(
          result.isOk,
          isFalse,
          reason: '空转超过 ${budget.inMilliseconds}ms 预算，不能被当成成功',
        );
        // 判定接受 timeout 与 instructions 两种，并给出各自应成立的证据：
        // - 空闲机器上先撞 4 秒墙钟 → timeout，消息带「超时」；
        // - 机器有负载时（例如整套测试并行跑）单条指令被拖慢，20000 tick 的
        //   指令预算可能先耗尽 → instructions，消息带「指令计数」。
        // 两者都是「失控被兜住」的正当结论，本用例要守的是「不能当成功收下」，
        // 而不是限定是哪一种预算先到（那取决于机器负载，不是被测行为）。
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.timeout, SandboxErrorKind.instructions),
          reason: '空转超预算必须被判为失控',
        );
        expect(
          result.error!.message,
          anyOf(contains('超时'), contains('指令计数')),
          reason: '失败原因要指明是哪条预算拦下的',
        );

        // 硬性要求：旧上下文被销毁，绝不复用。销毁发生在操作收尾的安全点，
        // 此刻在册上下文数应当已经减少（而不是留着一个超预算的实例）。
        expect(
          SandboxContext.liveCount,
          lessThan(liveBefore),
          reason: '超时后旧上下文必须被销毁释放',
        );
        expect(
          logLinesContaining('判定污染').where(
            (line) => line.contains('timeout') || line.contains('instructions'),
          ),
          isNotEmpty,
          reason: '污染销毁必须在日志里留痕（点名是哪条预算）',
        );

        // 后续请求在全新上下文里正常工作（代数递增 = 确实是新建的实例）。
        final after = await engine.callResult('detail', <String, Object?>{'id': 'x'});
        expect(after.isOk, isTrue);
        expect((after.value! as Map)['title'], '详情');
        expect(
          engine.generation,
          greaterThan(generationBefore),
          reason: '新请求应当落在重建后的全新上下文里',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '1c 污染后重建：新上下文可用，旧实例不被复用',
      () async {
        final engine = await openEngine(
          sourceId: 'smoke-rebuild',
          script: fixture('isolation_alpha.js'),
        );
        addTearDown(engine.dispose);

        // 先证明上下文是活的。
        final before = await engine.callResult('probe');
        expect(before.isOk, isTrue);
        expect(engine.generation, 1);

        // 用「分配型失控」制造一次引擎级失败：内存上限是硬性的，
        // 这条路径不依赖原生中断通路，因此一定能观察到销毁重建。
        final liveBefore = SandboxContext.liveCount;
        final runaway = await engine.callResult('runaway');
        expect(runaway.isOk, isFalse);
        expect(
          runaway.error!.kind,
          SandboxErrorKind.memory,
          reason: '脚本方法体内堆爆属于引擎级错误，不能被当成可捕获的普通脚本错误',
        );
        expect(
          SandboxContext.liveCount,
          lessThan(liveBefore),
          reason: '内存失控的上下文必须销毁，不能留着继续用',
        );

        // 新上下文能正常干活，且全局状态随旧上下文一起消失
        //（probe 会重新写入标记，因此这里验证的是「能跑通」与「代数递增」）。
        final after = await engine.callResult('probe');
        expect(after.isOk, isTrue, reason: '新上下文必须能正常干活');
        expect(engine.generation, greaterThan(1));
        expect(
          engine.isPoisoned,
          isFalse,
          reason: '污染标记属于旧上下文，新上下文应当是干净的',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '1d 卡死隔离：一个源失控不阻塞主线程，新上下文照常建立',
      () async {
        // 主 isolate 必须始终能调度：失控脚本在 worker isolate 里跑，无论它是被
        // 及时回收还是把线程占满，主 isolate 的定时器都不能停。
        //
        // 判据刻意用**相邻两次 tick 的最大空档**，而不是 tick 总次数：
        // 回收得越快，观测窗口越短，总次数自然越少——把总次数写成阈值，
        // 等于「谁回收得快谁失败」（本轮实测：修复中断通路后死循环约 0.4 秒
        // 就被回收，窗口内只有 3–4 次 tick，原断言 `> 3` 在负载下必然翻车）。
        // 空档则与窗口长短无关：主 isolate 只要没被占住，间隔就应当贴着定时器
        // 周期；真被失控脚本占住时，`Timer.periodic` 的 tick 会一次性跳过
        // 整个卡顿时长的周期数（tick 的定义就是「此前经过了多少个周期」）。
        final period = const Duration(milliseconds: 50);
        final ticks = <int>[];
        final stamps = <DateTime>[];
        final timer = Timer.periodic(period, (t) {
          ticks.add(t.tick);
          stamps.add(DateTime.now());
        });
        addTearDown(timer.cancel);

        final run = await runSandboxCallInWorker(
          script: fixture('deadloop_source.js'),
          method: 'list',
          budget: const Duration(seconds: 6),
        );
        addTearDown(run.kill);

        expect(run.armed, isTrue, reason: 'worker 应已进到调用脚本这一步');
        expect(
          run.completed,
          isTrue,
          reason: '失控脚本应在预算内被回收（修复中断通路后的正向断言）',
        );

        // 观测窗口很短（约 0.4 秒）时也至少要两次 tick，否则量不出空档。
        expect(
          ticks.length,
          greaterThanOrEqualTo(2),
          reason: '观测窗口内至少要有两次 tick 才能测出空档'
              '（实际 ${ticks.length} 次；0 次意味着主线程被卡住）',
        );
        // 取相邻 tick 的最大空档（tick 数 × 周期 = 真实卡顿时长的下界）。
        var maxGapPeriods = 0;
        for (var i = 1; i < ticks.length; i++) {
          final gap = ticks[i] - ticks[i - 1];
          if (gap > maxGapPeriods) maxGapPeriods = gap;
        }
        var maxGapWall = Duration.zero;
        for (var i = 1; i < stamps.length; i++) {
          final gap = stamps[i].difference(stamps[i - 1]);
          if (gap > maxGapWall) maxGapWall = gap;
        }
        const stallLimit = Duration(seconds: 1);
        expect(
          maxGapWall,
          lessThan(stallLimit),
          reason: '主 isolate 在失控脚本运行期间必须持续调度：'
              '相邻 tick 的空档不应超过 1 秒'
              '（实测最大空档 ${maxGapWall.inMilliseconds}ms ≈ '
              '$maxGapPeriods 个周期，共 ${ticks.length} 次 tick，'
              '周期 ${period.inMilliseconds}ms）。'
              '空档接近整个预算（6 秒）才说明主线程真被占住了',
        );

        // 另起一个全新上下文：失控的源不影响新源建立。
        final fresh = await openEngine(
          sourceId: 'smoke-fresh-during-hang',
          script: fixture('isolation_beta.js'),
        );
        addTearDown(fresh.dispose);
        final probe = await fresh.callResult('probe');
        expect(probe.isOk, isTrue);
        expect((probe.value! as Map)['self'], 'beta-value');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('1e 超时预算口径（不依赖原生中断通路）', () {
    test('策略超时被收敛到 3–5 秒区间', () {
      expect(SandboxPolicy.minTimeout, const Duration(seconds: 3));
      expect(SandboxPolicy.maxTimeout, const Duration(seconds: 5));
      expect(smokePolicy().timeout, SandboxPolicy.minTimeout);
      expect(
        const SandboxPolicy(timeout: Duration(milliseconds: 100)).clamped().timeout,
        SandboxPolicy.minTimeout,
      );
    });

    test('超预算脚本的耗时能被预算账本如实记账', () {
      final policy = SandboxPolicy.strict;
      final budget = SandboxBudget(
        policy,
        DateTime.now().subtract(policy.timeout + const Duration(seconds: 1)),
      );
      expect(budget.isExpired, isTrue, reason: '越过墙钟预算必须判定到期');
      expect(budget.remaining, Duration.zero);
    });
  });
}
