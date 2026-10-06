import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

import 'support/js_sandbox_support.dart';

/// FFI 内存回收表现观测（Phase3 真机复测要求「留意 FFI 内存回收」）。
///
/// 本用例**不做通过/失败判定**（已知插件泄漏尚未修，见 deferred-todo.md
/// 「stringifyFn 泄漏 → JSRuntime 无法回收」），只把可量化的数字打出来：
/// - `SandboxContext.liveCount`：在册 JSContext 数（应回落，否则是泄漏）；
/// - `Qjs.abandonedRuntimes`：因插件泄漏而只记账不释放的 JSRuntime 数；
/// - `ProcessInfo.currentRss`：进程实际驻留内存。
///
/// 目的是给出「泄漏速率」这个可比较的基线数字，供后续修复时对照。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  final skipReason = available ? null : '未找到可用的 quickjs 原生桥';

  int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

  test('观测：正常创建 / 销毁循环的 FFI 回收表现', () async {
    // 先热身，避开首次加载原生库与 JIT 的一次性开销。
    for (var i = 0; i < 3; i++) {
      final s = LumeSandbox.create(
        id: 'warm-$i',
        policy: smokePolicy(),
        host: const DenyAllSandboxHost(),
      );
      await s.eval('1+1');
      s.dispose();
    }
    final warmRss = rssMb();
    final warmLive = SandboxContext.liveCount;
    final warmAbandoned = Qjs.abandonedRuntimes;

    const rounds = 50;
    for (var i = 0; i < rounds; i++) {
      final sandbox = LumeSandbox.create(
        id: 'cycle-$i',
        policy: smokePolicy(),
        host: const DenyAllSandboxHost(),
      );
      final r = await sandbox.eval('var a = 1; a + 1;');
      expect(r.isOk, isTrue, reason: '第 $i 轮求值应成功');
      sandbox.dispose();
    }

    final endRss = rssMb();
    final endLive = SandboxContext.liveCount;
    final endAbandoned = Qjs.abandonedRuntimes;

    // ignore: avoid_print
    print('''
[FFI 内存观测 · 正常创建/销毁 $rounds 轮]
  在册 JSContext : $warmLive → $endLive   （差值 ${endLive - warmLive}，应为 0）
  JSRuntime 放弃回收: $warmAbandoned → $endAbandoned   （差值 ${endAbandoned - warmAbandoned}）
  进程 RSS       : ${warmRss}MB → ${endRss}MB   （差值 ${endRss - warmRss}MB）
  每轮泄漏 runtime: ${((endAbandoned - warmAbandoned) / rounds).toStringAsFixed(2)} 个
''');

    // 唯一能断言的硬事实：JSContext 必须回落（那是我们直接管的对象）
    expect(
      endLive,
      lessThanOrEqualTo(warmLive),
      reason: 'JSContext 必须被释放，不得累积',
    );
  }, skip: skipReason, timeout: const Timeout(Duration(seconds: 300)));

  test('观测：失控销毁重建循环的 FFI 回收表现（最坏路径）', () async {
    final sandbox = LumeSandbox.create(
      id: 'deadloop-cycle',
      policy: smokePolicy(),
      host: const DenyAllSandboxHost(),
    );
    addTearDown(sandbox.dispose);

    // 先跑一轮正常求值热身
    await sandbox.eval('1+1');
    final warmRss = rssMb();
    final warmLive = SandboxContext.liveCount;
    final warmAbandoned = Qjs.abandonedRuntimes;
    final warmGen = sandbox.generation;

    const rounds = 20;
    for (var i = 0; i < rounds; i++) {
      // 纯 CPU 死循环 → 每轮触发一次「判废 + 销毁 + 重建」
      final r = await sandbox.eval('while(true){}');
      expect(r.isOk, isFalse, reason: '第 $i 轮死循环应被判废');
      // 立刻证明还能继续用
      final alive = await sandbox.eval('1+1');
      expect(alive.isOk, isTrue, reason: '第 $i 轮后应仍可用');
    }

    final endRss = rssMb();
    final endLive = SandboxContext.liveCount;
    final endAbandoned = Qjs.abandonedRuntimes;

    // ignore: avoid_print
    print('''
[FFI 内存观测 · 失控销毁重建 $rounds 轮]
  代数          : $warmGen → ${sandbox.generation}   （每轮 +1 表示确实重建）
  在册 JSContext : $warmLive → $endLive   （差值 ${endLive - warmLive}，应为 0）
  JSRuntime 放弃回收: $warmAbandoned → $endAbandoned   （差值 ${endAbandoned - warmAbandoned}）
  进程 RSS       : ${warmRss}MB → ${endRss}MB   （差值 ${endRss - warmRss}MB）
  每轮泄漏 runtime: ${((endAbandoned - warmAbandoned) / rounds).toStringAsFixed(2)} 个
''');

    expect(
      sandbox.generation,
      warmGen + rounds,
      reason: '每轮失控都应重建上下文（代数逐轮 +1）',
    );
    expect(
      endLive,
      lessThanOrEqualTo(warmLive),
      reason: '反复销毁重建不得让 JSContext 累积',
    );
  }, skip: skipReason, timeout: const Timeout(Duration(seconds: 300)));
}
