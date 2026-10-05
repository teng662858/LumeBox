import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/util/lume_log.dart';

import 'support/js_sandbox_support.dart';

/// 日志留档：把关键场景跑一遍，把沙箱内部日志（污染判定 / 上下文重建 / 拒绝）
/// 落到 `test/js_sandbox/logs/evidence.log`，供人工复核。
///
/// 这些日志是「行为确实发生」的直接证据——测试断言证明结论，日志证明过程：
/// 例如「旧中毒上下文被销毁」这件事，在日志里表现为一条「判定污染」加一条
/// 「丢弃污染上下文…重建全新上下文」。
void main() {
  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  setUp(enableEngineOnThisPlatform);
  tearDown(restoreEnginePlatformGate);

  test(
    '留档：超时销毁 / 内存失控 / 板块拒绝 的内部日志',
    () async {
      LumeLog.clear();
      final evidence = <String>[];

      void section(String title) {
        evidence.add('');
        evidence.add('======== $title ========');
      }

      void snapshot() {
        for (final entry in LumeLog.snapshot) {
          evidence.add('[${entry.level.id}] ${entry.message}');
        }
      }

      // 1) 超预算脚本 → 判定超时 → 销毁重建。
      // 空转时长刻意比预算多 2s：贴着边界会因毫秒级计时误差变成不确定断言。
      section('场景 1：脚本 CPU 空转超预算 → 应判定超时并销毁上下文');
      final overrun = await openEngine(
        sourceId: 'evidence-overrun',
        script: fixture('deadloop_source.js'),
      );
      final budget = LumeJsEngine.policy.timeout;
      final genBefore = overrun.generation;
      final liveBefore = SandboxContext.liveCount;
      final overrunResult = await overrun.callResult(
        'boundedOverrun',
        <String, Object?>{'spinMs': budget.inMilliseconds + 2000},
      );
      evidence.add('调用结果: ok=${overrunResult.isOk} '
          'kind=${overrunResult.error?.kind.id} msg=${overrunResult.error?.message}');
      evidence.add('上下文: 代数 $genBefore → ${overrun.generation}，'
          '在册数 $liveBefore → ${SandboxContext.liveCount}');
      snapshot();

      // 2) 内存失控 → 引擎级错误 → 销毁重建。
      section('场景 2：脚本方法体内堆爆 → 应判为 memory 并销毁上下文');
      final oom = await openEngine(
        sourceId: 'evidence-oom',
        script: fixture('isolation_alpha.js'),
      );
      final oomLive = SandboxContext.liveCount;
      final oomResult = await oom.callResult('runaway');
      evidence.add('调用结果: ok=${oomResult.isOk} '
          'kind=${oomResult.error?.kind.id} msg=${oomResult.error?.message}');
      evidence.add('上下文: 在册数 $oomLive → ${SandboxContext.liveCount}');
      snapshot();

      // 3) 死循环：留档「未能回收」的观测事实。
      section('场景 3：纯 CPU 死循环 → 已知缺陷：无法在预算内回收');
      final hang = await runSandboxCallInWorker(
        script: fixture('deadloop_source.js'),
        method: 'list',
        budget: const Duration(seconds: 10),
      );
      evidence.add('中断通路可用: ${SandboxGuard.interruptAvailable}');
      evidence.add('worker 已开始调用: ${hang.armed}');
      evidence.add('预算 3s，等待 ${hang.waited.inSeconds}s 后是否收尾: ${hang.completed}');
      evidence.add('worker 事件: ${hang.events}');
      evidence.add('结论: 纯 CPU 死循环未被回收（详见 deferred-todo.md）');
      hang.kill();

      // 清理：把两个引擎释放掉，避免留档过程本身留下在册上下文。
      overrun.dispose();
      oom.dispose();
      evidence.add('');
      evidence.add('收尾: 在册上下文数 = ${SandboxContext.liveCount}');

      // 落盘（覆盖写，每次运行都是最新证据）。
      final file = File('test/js_sandbox/logs/evidence.log');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('${evidence.join('\n')}\n');

      // 留档本身也断言：文件确实写出来了、且含关键证据行。
      //
      // 证据分两类，都在文件里：
      // - 沙箱内部日志（「判定污染」）证明上下文被判废；
      // - 在册上下文数下降 + 代数递增证明旧实例真的被销毁、后续走的是新实例。
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('判定污染'), reason: '污染判定必须留痕');
      expect(text, contains('kind=timeout'), reason: '超预算脚本应判超时');
      expect(text, contains('kind=memory'), reason: '堆爆应判内存超限');
      expect(text, contains('在册数 1 → 0'), reason: '中毒上下文必须被销毁');
      expect(text, contains('已知缺陷'), reason: '纯 CPU 死循环的缺陷要留档');
      expect(
        text,
        isNot(contains('Bad state')),
        reason: '不该出现二次完成之类的引擎级异常',
      );
    },
    skip: skipReason,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
