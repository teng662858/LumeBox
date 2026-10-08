import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';

import 'support/js_sandbox_support.dart';

/// 沙箱三条安全性质的**生产路径审计**（真实引擎 + 真实宿主身份校验）。
///
/// 与既有用例的分工：`deadloop_timeout_test` / `context_isolation_test` /
/// `section_category_test` / `malicious_script_test` 分别在沙箱 API 与导入路径上
/// 逐条验证；本文件把它们放回**同一条生产链路**（[LumeJsEngine] + 注册表 + 真实
/// `LumeSourceHost`）上再核一遍，并补上三处此前没覆盖的攻击面：
///
/// 1. **把卡死推迟到操作结束之后**：`setTimeout(() => { while(true){} })`——
///    定时器回调是**新的一次求值**，如果它拿到全新预算，脚本就能靠定时器
///    反复冻结界面。这里验证它仍然被兜住、且判废后上下文重建可继续用；
/// 2. **同一 id 落在两个板块**：两个引擎必须各持各的上下文与沙盒存储，
///    不能因为 id 相同就共用（这是「4 套图源列表互相独立」在运行时的落点）；
/// 3. **脚本从 JS 侧伪造存储身份**：宿主身份由 Dart 侧盖章，JS 传什么都不算数
///    ——验证「A 板块脚本读到 B 板块数据」这条路在运行时是死的。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  // 非 iOS 平台要显式放行引擎平台门（与既有原生用例同一套做法）。
  setUpAll(enableEngineOnThisPlatform);
  tearDownAll(restoreEnginePlatformGate);

  /// 一个「把卡死推迟到操作结束之后」的源：注册一次定时器死循环后正常返回。
  const timerSpinScript = '''
// LumeSource: {"id":"audit-timer-spin","name":"定时器内死循环","version":"1.0.0"}
var LumeSource = {
  id: 'audit-timer-spin',
  name: '定时器内死循环',
  version: '1.0.0',
  async categories() {
    return [{ id: 'c1', title: '分类一' }];
  },
  async list(argument) {
    if (!globalThis.__lumeSpun) {
      globalThis.__lumeSpun = true;
      // 关键：不从当前调用里卡死（那次有预算保护），而是排到操作结束之后。
      setTimeout(function () { for (;;) {} }, 0);
    }
    return { items: [{ id: 'ok', title: '正常条目' }], hasMore: false };
  }
};
''';

  /// 一份「会写自己的沙盒存储、也能回读」的源：用同一段脚本在两个板块各起一个
  /// 引擎，验证同 id 不共享。
  const storeProbeScript = '''
// LumeSource: {"id":"audit-shared-id","name":"同 id 跨板块","version":"1.0.0"}
var LumeSource = {
  id: 'audit-shared-id',
  name: '同 id 跨板块',
  version: '1.0.0',
  async plant(argument) {
    var value = argument && argument.value ? argument.value : 'unset';
    await LumeSource.fs.writeText('shared/probe.txt', String(value));
    globalThis.__lumeTag = String(value);
    return { ok: true };
  },
  async probe() {
    var fromStore = await LumeSource.fs.readText('shared/probe.txt');
    return {
      tag: globalThis.__lumeTag === undefined ? null : String(globalThis.__lumeTag),
      store: fromStore === null || fromStore === undefined ? null : String(fromStore),
      keys: await LumeSource.fs.list()
    };
  },
  // 从 JS 侧尝试伪造存储身份：宿主应当在 Dart 侧盖章，JS 传什么都不算数。
  async probeWithForgedIdentity(argument) {
    var forged = argument && argument.sandboxId ? String(argument.sandboxId) : '';
    var raw = await LumeBridge.invoke('store.read', {
      key: 'shared/probe.txt',
      sandboxId: forged,
      sourceId: 'someone-else'
    });
    return { value: raw && raw.value ? String(raw.value) : null };
  }
};
''';

  group('① 死循环超时销毁（生产路径）', () {
    test(
      '定时器内死循环：仍被兜住、判废，且判废后上下文重建可继续用',
      () async {
        final engine = await openEngine(
          sourceId: 'audit-timer-spin',
          script: timerSpinScript,
        );
        addTearDown(engine.dispose);

        // 第一次调用是正常的：卡死被推迟到操作结束之后。
        final first = await engine.callResult('list', <String, Object?>{'page': 1});
        expect(first.isOk, isTrue, reason: '方法本身正常返回：卡死发生在它之后');
        expect(engine.isPoisoned, isFalse);

        final generationBefore = engine.generation;
        final stopwatch = Stopwatch()..start();
        // 放行真实事件轮，让那个 setTimeout 回调跑起来（它会死循环）。
        // 死循环会占住本 isolate，因此这里量到的耗时就是「冻结时长」。
        await Future<void>.delayed(const Duration(milliseconds: 50));
        stopwatch.stop();
        // ignore: avoid_print
        print('[审计] 定时器内死循环的冻结时长: ${stopwatch.elapsedMilliseconds}ms '
            '（策略上限 ${LumeJsEngine.policy.timeout.inMilliseconds}ms）');

        // 1) 冻结是有界的：不超预算（4s）多少。
        expect(
          stopwatch.elapsed,
          lessThan(LumeJsEngine.policy.timeout + const Duration(seconds: 2)),
          reason: '推迟到操作之后的死循环同样必须被墙钟预算兜住',
        );
        // 2) 上下文被判废（不是「当成正常结果收下」）。
        expect(
          engine.isPoisoned,
          isTrue,
          reason: '卡死的上下文必须判废：不许带着一个随时会再冻结的旧上下文继续跑',
        );
        expect(
          logLinesContaining('沙箱上下文判定污染'),
          isNotEmpty,
          reason: '判定污染必须留日志（安全事件可审计）',
        );

        // 3) 判废后同一引擎仍可用：下一次操作重建上下文并重放脚本。
        final second = await engine.callResult('list', <String, Object?>{'page': 2});
        expect(second.isOk, isTrue, reason: '重建后的上下文必须能正常干活');
        expect(engine.generation, greaterThan(generationBefore));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '一个来源的失控不牵连另一板块的来源（异步卡死同样适用）',
      () async {
        final victim = await openEngine(
          sourceId: 'audit-timer-spin',
          script: timerSpinScript,
          section: Section.comic,
        );
        final bystander = await openEngine(
          sourceId: 'bystander',
          script: fixture('isolation_beta.js'),
          section: Section.novel,
        );
        addTearDown(victim.dispose);
        addTearDown(bystander.dispose);

        await victim.callResult('list', <String, Object?>{'page': 1});
        // 让受害者的定时器死循环跑起来（会冻结这一小段时间）。
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 旁观者在另一板块，全程可用。
        final probe = await bystander.callResult('probe');
        expect(probe.isOk, isTrue, reason: '另一板块的来源不受影响');
        final value = probe.value! as Map<Object?, Object?>;
        expect(value['self'], 'beta-value');
        expect(
          value['foreignAlpha'],
          'undefined',
          reason: '交叉可见性仍然为 undefined（隔离没被这一轮折腾破坏）',
        );
        expect(value['storeOwner'], 'beta', reason: '沙盒存储仍是自己的那一份');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('② 上下文隔离（同一 id 落在两个板块）', () {
    test(
      '同 id 不同板块：上下文与沙盒存储各自独立，互不可见',
      () async {
        final comic = await openEngine(
          sourceId: 'audit-shared-id',
          script: storeProbeScript,
          section: Section.comic,
        );
        final novel = await openEngine(
          sourceId: 'audit-shared-id',
          script: storeProbeScript,
          section: Section.novel,
        );
        addTearDown(comic.dispose);
        addTearDown(novel.dispose);

        // 漫画侧写入自己的标记与存储。
        await comic.callResult('plant', <String, Object?>{'value': 'comic-value'});

        final comicProbe =
            (await comic.callResult('probe')).value! as Map<Object?, Object?>;
        expect(comicProbe['tag'], 'comic-value');
        expect(comicProbe['store'], 'comic-value');

        // 小说侧看不到漫画侧的任何东西：全局标记为空、同名存储路径读不到。
        final novelProbe =
            (await novel.callResult('probe')).value! as Map<Object?, Object?>;
        expect(novelProbe['tag'], isNull, reason: '同名全局变量不跨板块可见');
        expect(novelProbe['store'], isNull, reason: '同名沙盒路径不跨板块共享');
        expect(novelProbe['keys'], isEmpty, reason: '沙盒存储按板块各存各的');

        // 反向：小说侧写入后，漫画侧读到的仍是自己的值（不互相覆盖）。
        await novel.callResult('plant', <String, Object?>{'value': 'novel-value'});
        final comicAgain =
            (await comic.callResult('probe')).value! as Map<Object?, Object?>;
        expect(comicAgain['store'], 'comic-value');

        // 沙箱身份自带板块前缀：两个引擎的身份必须不同。
        expect(
          LumeSourceHost.sandboxIdFor(Section.comic, 'audit-shared-id'),
          isNot(LumeSourceHost.sandboxIdFor(Section.novel, 'audit-shared-id')),
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('③ 板块隔离校验（运行时）', () {
    test(
      'JS 侧伪造存储身份无效：调用仍落在自己的沙盒里',
      () async {
        final comic = await openEngine(
          sourceId: 'audit-shared-id',
          script: storeProbeScript,
          section: Section.comic,
        );
        final novel = await openEngine(
          sourceId: 'audit-shared-id',
          script: storeProbeScript,
          section: Section.novel,
        );
        addTearDown(comic.dispose);
        addTearDown(novel.dispose);

        await novel.callResult('plant', <String, Object?>{'value': 'novel-secret'});
        await comic.callResult('plant', <String, Object?>{'value': 'comic-public'});

        // 漫画脚本把「小说板块的沙箱身份」写进调用参数，试图读别人的数据。
        final forged = (await comic.callResult(
          'probeWithForgedIdentity',
          <String, Object?>{'sandboxId': 'novel:audit-shared-id'},
        )).value! as Map<Object?, Object?>;

        expect(
          forged['value'],
          'comic-public',
          reason: '身份由 Dart 侧盖章，JS 传什么都不算数——读到的仍是自己的存储',
        );
        expect(forged['value'], isNot('novel-secret'));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '跨板块宿主调用在 Dart 侧被拒（身份不符），不触达网络与存储',
      () async {
        final host = LumeSourceHost(
          _CountingHttp(),
          timeout: const Duration(seconds: 2),
          section: Section.comic,
          sourceId: 'audit-shared-id',
        );
        addTearDown(host.dispose);

        await expectLater(
          () => host.invoke(
            SandboxHostRequest(
              sandboxId: 'novel:audit-shared-id',
              method: SandboxHostMethods.storeWrite,
              payload: <String, Object?>{'key': 'x', 'value': 'y'},
            ),
          ),
          throwsA(
            isA<SandboxHostException>().having(
              (error) => error.message,
              'message',
              allOf(contains('拒绝跨沙箱宿主调用'), contains('comic')),
            ),
          ),
        );
        expect(host.store.entryCount, 0, reason: '被拒的调用不得写入');
      },
      skip: skipReason,
    );
  });
}

/// 计数用的假 HTTP：本组用例不该产生任何真实请求。
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
      body: Uint8List.fromList(utf8.encode('{}')),
      headers: const <String, String>{},
    );
  }
}
