import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';

import 'support/js_sandbox_support.dart';

/// 安全测试第 4 条：恶意 / 失控脚本矩阵。
///
/// 每一类都断言**三件事**，缺一不可：
/// 1. 失败分类正确（不把失控说成脚本 bug，也不反过来）；
/// 2. 上下文被销毁（污染标记 + 在册数回落），旧上下文绝不复用；
/// 3. App 侧仍可继续工作——重建后的新上下文照常跑。
///
/// 这组用例是安全承诺的回归护栏：以后任何一次重构，只要把某类失控从
/// 「被兜住」改成「被收下」，这里就会红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  setUp(enableEngineOnThisPlatform);
  tearDown(restoreEnginePlatformGate);

  /// 建一个真实沙箱（严格策略：3s 墙钟、更小的预算池）。
  LumeSandbox newSandbox({
    String id = 'attack-probe',
    SandboxPolicy? policy,
  }) =>
      LumeSandbox.create(
        id: id,
        policy: policy ?? smokePolicy(),
        host: const DenyAllSandboxHost(),
      );

  /// 断言「上下文已被回收 + 重建后可用」这条共同底线。
  Future<void> expectRecovered(
    LumeSandbox sandbox, {
    required int generationBefore,
    required String reason,
  }) async {
    expect(
      sandbox.generation,
      greaterThan(generationBefore),
      reason: '$reason：必须重建全新上下文，不复用旧的',
    );
    final alive = await sandbox.eval('1 + 1');
    expect(alive.isOk, isTrue, reason: '$reason：重建后的上下文要能照常工作');
    expect(alive.value, 2);
  }

  group('4) 恶意脚本矩阵', () {
    test(
      '4a 灾难性正则回溯：走中断 / 预算通路被判定失控，不挂死',
      () async {
        final sandbox = newSandbox(id: 'regex-bomb');
        addTearDown(sandbox.dispose);
        final before = sandbox.generation;

        // `(a+)+$` 对一长串 a 是经典的指数级回溯；正则引擎自己会轮询中断。
        final result = await sandbox.eval(
          r"/(a+)+$/.test('a'.repeat(40) + 'b')",
        );

        expect(result.isOk, isFalse, reason: '回溯爆炸必须被兜住，不能当成正常结果');
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.timeout, SandboxErrorKind.instructions),
          reason: '要么被墙钟预算判超时，要么被指令计数判超限，两者都算兜住',
        );
        await expectRecovered(sandbox, generationBefore: before, reason: '正则回溯');
      },
      skip: skipReason,
    );

    test(
      '4b 无限递归：按内存 / 栈溢出或脚本错误分类，且上下文可回收',
      () async {
        final sandbox = newSandbox(id: 'deep-recursion');
        addTearDown(sandbox.dispose);
        final before = sandbox.generation;

        final result = await sandbox.eval(
          'function f(n) { return f(n + 1); } f(0);',
        );

        expect(result.isOk, isFalse);
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.memory, SandboxErrorKind.script),
          reason: '栈溢出是引擎级失败；被归类为内存或脚本错误都合理，但不能是 ok',
        );
        // 脚本类错误按策略不污染（可继续用）；引擎级失败必须重建。
        if (result.error!.kind.poisonsContext) {
          await expectRecovered(sandbox, generationBefore: before, reason: '无限递归');
        } else {
          final alive = await sandbox.eval('1 + 1');
          expect(alive.isOk, isTrue, reason: '可捕获的脚本错误不该连累上下文');
        }
      },
      skip: skipReason,
    );

    test(
      '4c 大分配：命中内存上限，销毁重建后可用',
      () async {
        final sandbox = newSandbox(id: 'memory-bomb');
        addTearDown(sandbox.dispose);
        final before = sandbox.generation;

        final result = await sandbox.eval(
          'var sink = []; while (true) { sink.push(new Array(100000).fill(1)); }',
        );

        expect(result.isOk, isFalse);
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.memory, SandboxErrorKind.timeout),
          reason: '分配型失控：内存上限是原生硬限制，应当命中',
        );
        await expectRecovered(sandbox, generationBefore: before, reason: '大分配');
      },
      skip: skipReason,
    );

    test(
      '4d 微任务自循环：按微任务 / 步数预算判定失控',
      () async {
        final sandbox = newSandbox(id: 'microtask-loop');
        addTearDown(sandbox.dispose);
        final before = sandbox.generation;

        // 无限微任务链：每一轮都排空一个微任务，永远排不完。
        // 用「自己排自己」而不是「预先排 10 万个 then」——后者是有限链条，
        // 只会把栈撑爆（RangeError），测不到预算本身。
        final result = await sandbox.eval('''
var spin = Promise.resolve();
function loop() { spin = spin.then(loop); }
loop();
'x';
''');

        expect(result.isOk, isFalse, reason: '排不完的微任务必须被预算截断');
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.instructions, SandboxErrorKind.timeout),
        );
        await expectRecovered(sandbox, generationBefore: before, reason: '微任务自循环');
      },
      skip: skipReason,
    );

    test(
      '4e 宿主调用风暴：按宿主调用 / 步数预算截断，且真实请求次数与记账一致',
      () async {
        final http = _CountingHttp();
        final host = LumeSourceHost(
          http,
          timeout: const Duration(seconds: 2),
          section: Section.novel,
          sourceId: 'storm',
        );
        final sandbox = LumeSandbox.create(
          id: host.expectedSandboxId,
          policy: smokePolicy(),
          host: host,
          polyfills: LumeSourcePolyfills.registry,
        );
        addTearDown(() {
          sandbox.dispose();
          host.dispose();
        });
        final before = sandbox.generation;

        // 必须走 load + call：`eval` 只是把脚本顶层求值完就返回（拿到的是
        // Promise 对象本身），异步风暴会在操作结束后继续跑，测不到预算。
        // `call` 会真正驱动到脚本给出结果或预算耗尽。
        final loaded = await sandbox.load('''
var LumeSource = {
  id: 'storm',
  name: '调用风暴',
  async run() {
    var total = 0;
    for (var i = 0; i < 100000; i++) {
      await LumeSource.http.get('https://example.com/' + i);
      total++;
    }
    return total;
  }
};
''');
        expect(loaded.isOk, isTrue, reason: '脚本本身要能载入（否则测的不是预算）');
        final result = await sandbox.call('LumeSource.run');

        expect(result.isOk, isFalse, reason: '宿主调用风暴必须被预算截断');
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.instructions, SandboxErrorKind.timeout),
        );
        expect(
          http.calls,
          lessThanOrEqualTo(smokePolicy().maxHostCalls),
          reason: '真实请求次数不得超出宿主调用预算（记账与放行必须一致）',
        );
        expect(http.calls, greaterThan(0), reason: '前面的调用确实发出过，不是一开始就被拦');
        await expectRecovered(sandbox, generationBefore: before, reason: '宿主调用风暴');
      },
      skip: skipReason,
    );

    test(
      '4f 定时器风暴：超出上限的注册被忽略，不把上下文拖垮',
      () async {
        final sandbox = newSandbox(id: 'timer-storm');
        addTearDown(sandbox.dispose);

        // 每个定时器都重新注册自己：数量上不去（上限兜住），但会持续跑。
        final result = await sandbox.eval('''
var n = 0;
function tick() { n++; setTimeout(tick, 1); }
for (var i = 0; i < 500; i++) { setTimeout(tick, 1); }
'n=' + n;
''');

        // 同步求值本身会返回；真正的约束是「定时器数量不超过上限」。
        expect(
          logLinesContaining('定时器数量超出上限'),
          isNotEmpty,
          reason: '被忽略的注册要留下日志，便于排查',
        );
        expect(result.error?.kind, anyOf(isNull, SandboxErrorKind.instructions));
      },
      skip: skipReason,
    );

    test(
      '4g 超大返回值：按协议异常处理，不把内存交给上层',
      () async {
        final sandbox = newSandbox(
          id: 'huge-result',
          policy: smokePolicy().copyWith(maxResultChars: 1024),
        );
        addTearDown(sandbox.dispose);
        final before = sandbox.generation;

        final result = await sandbox.eval("'x'.repeat(100000)");

        expect(result.isOk, isFalse);
        expect(
          result.error!.kind,
          SandboxErrorKind.protocol,
          reason: '超出结果上限属于协议异常（脚本给的不是我们约定的东西）',
        );
        await expectRecovered(sandbox, generationBefore: before, reason: '超大返回值');
      },
      skip: skipReason,
    );

    test(
      '4h 伪造沙箱身份：宿主层拒绝，且不触达网络与存储',
      () async {
        final http = _CountingHttp();
        final host = LumeSourceHost(
          http,
          timeout: const Duration(seconds: 2),
          section: Section.novel,
          sourceId: 'real-source',
        );
        addTearDown(host.dispose);

        // 冒充别的板块 / 别的来源：三种伪造都必须在入口被拒。
        for (final forged in <String>[
          'comic:real-source',
          'novel:other-source',
          'comic:other-source',
          '',
        ]) {
          await expectLater(
            () => host.invoke(
              SandboxHostRequest(
                sandboxId: forged,
                method: SandboxHostMethods.storeWrite,
                payload: <String, Object?>{'key': 'probe', 'value': 'x'},
              ),
            ),
            throwsA(
              isA<SandboxHostException>().having(
                (error) => error.message,
                'message',
                allOf(contains('拒绝跨沙箱宿主调用'), contains(host.expectedSandboxId)),
              ),
            ),
            reason: '伪造身份「$forged」必须被拒绝，且错误信息点明宿主服务的身份',
          );
        }

        expect(http.calls, 0, reason: '被拒的调用不得触达网络');
        expect(host.store.entryCount, 0, reason: '被拒的调用不得写入沙盒存储');
        expect(
          logLinesContaining('拒绝跨沙箱宿主调用'),
          isNotEmpty,
          reason: '拒绝要留日志（安全事件必须可审计）',
        );
      },
      skip: skipReason,
    );

    test(
      '4i 身份校验不会误伤：本板块本来源的正常调用照旧',
      () async {
        final host = LumeSourceHost(
          _CountingHttp(),
          timeout: const Duration(seconds: 2),
          section: Section.comic,
          sourceId: 'legit',
        );
        addTearDown(host.dispose);

        final written = await host.invoke(
          SandboxHostRequest(
            sandboxId: host.expectedSandboxId,
            method: SandboxHostMethods.storeWrite,
            payload: <String, Object?>{'key': 'k', 'value': 'v'},
          ),
        );
        expect(written, isA<Map<String, Object?>>());

        final read = await host.invoke(
          SandboxHostRequest(
            sandboxId: host.expectedSandboxId,
            method: SandboxHostMethods.storeRead,
            payload: <String, Object?>{'key': 'k'},
          ),
        );
        expect((read! as Map<String, Object?>)['value'], 'v');
        expect(host.store.entryCount, 1);
      },
      skip: skipReason,
    );

    test(
      '4j 一个源失控不牵连其他源：另一实例全程可用',
      () async {
        final victim = newSandbox(id: 'victim');
        final bystander = newSandbox(id: 'bystander');
        addTearDown(victim.dispose);
        addTearDown(bystander.dispose);

        await bystander.eval('var marker = "bystander-ok";');

        final result = await victim.eval(
          'var sink = []; while (true) { sink.push(new Array(100000).fill(1)); }',
        );
        expect(result.isOk, isFalse, reason: '失控方应当被兜住');

        final survivor = await bystander.eval('marker');
        expect(survivor.isOk, isTrue, reason: '旁观者不该被牵连');
        expect(survivor.value, 'bystander-ok');
      },
      skip: skipReason,
    );
  });
}

/// 只数次数、不真发请求的 HTTP 替身（宿主调用风暴用）。
class _CountingHttp extends LumeHttp {
  _CountingHttp() : super();

  int calls = 0;

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    // 宿主签名里的「读满上限就断开」（探测型请求用，见 network_queue 的 maxBytes）。
    int? maxBytes,
    Duration? timeout,
  }) async {
    calls++;
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode('{"ok":true}')),
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}
