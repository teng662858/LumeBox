import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/util/lume_log.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

/// Phase3 真机复测的**可自动化部分**。
///
/// 背景（如实说明）：真机复测需要在 macOS + Xcode + 真机/模拟器上跑，
/// 而本机是 Windows，没有 iOS 工具链（`ios_preflight` 全项不可用），
/// 因此「在 iPhone 上点一遍」这件事本身只能由人来做。
///
/// 本文件承担的是**能自动化的那一半**：在真实 QuickJS-NG 原生桥上，把两条
/// 复测清单里的每一条都跑一遍，包括用户特别要求的 FFI 内存回收表现。
/// 它跑在 Windows 的 x64 构建上，与被测的 iOS arm64 构建同源（同一份
/// `native/cxx` + 同一处补丁，见 `third_party/quickjs_engine/PATCHES.md`），
/// 因此结论对 iOS 有直接参考价值；差异只在 ABI 与调度细节。
///
/// 对应的 iOS 侧已先行核实（对 Actions 产出的 IPA 做二进制级检查）：
/// - `Frameworks/quickjs-engine-native.framework/quickjs-engine-native` 的
///   Mach-O 符号表里存在 `_jsSetInterruptHandler`（本项目的补丁导出）
///   与 `_JS_SetInterruptHandler`（quickjs 本体），说明补丁确实编进了 iOS 包；
/// - 包内 `Runner` / `App.framework` / `quickjs-engine-native` 三个二进制里
///   `node_start` / `uv_loop_init` / `napi_` 命中数均为 **0**（宪法第 9 条验收项）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  late Directory root;

  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('lume_box_phase3_accept');
    await installTempSectionRoot(root);
    SectionMemoryCache.instance.clearAll();
    // 日志缓冲是进程级的：不清空会让上一个用例的销毁记录污染本用例的断言。
    LumeLog.clear();
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    SectionMemoryCache.instance.clearAll();
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // ==========================================================================
  // 复测清单 1：沙箱死循环超时销毁
  // ==========================================================================

  group('清单 1 · 沙箱死循环超时销毁', () {
    test(
      '1-1 导入死循环脚本 → 运行 → 秒级判定超时、销毁上下文、App 可继续操作',
      () async {
        // 走真实导入链路（与 App 里「+ 添加源」同一条）：脚本能导入成功，
        // 说明死循环本身不阻塞导入。
        final registry = await SourceRegistry.open(Section.novel);
        final imported = await registry.import(
          fixture('deadloop_source.js'),
        );
        expect(
          imported.record,
          isNotNull,
          reason: '死循环脚本本身语法合法，导入阶段不该被拦（拦它的是运行期的预算）',
        );
        final sourceId = imported.record!.id;
        final engine =
            await registry.engineFor(sourceId) as QuickJsSourceEngine?;
        expect(engine, isNotNull, reason: '导入后应能取到引擎');
        final jsEngine = engine!.engine;

        final generationBefore = jsEngine.generation;
        final liveBefore = SandboxContext.liveCount;
        final watch = Stopwatch()..start();

        // 运行死循环（list 方法体里是 while(true){}）。
        final result = await jsEngine.callResult('list', <String, Object?>{'page': 1});
        watch.stop();

        // ① 判为失控，而不是成功
        expect(result.isOk, isFalse, reason: '死循环绝不能被当成正常结果收下');
        expect(
          result.error!.kind,
          anyOf(SandboxErrorKind.timeout, SandboxErrorKind.instructions),
          reason: '应判定为超时或超出指令计数（哪条预算先到取决于机器负载）',
        );

        // ② 秒级返回：这是「App 不会永久卡死」的量化表达。
        //    预算 3–5s，留一倍余量到 10s；修复前这里永远等不到。
        expect(
          watch.elapsed.inSeconds,
          lessThan(10),
          reason: '死循环应在预算内被中断（实测 ${watch.elapsedMilliseconds}ms）',
        );

        // ③ 旧上下文已销毁释放
        expect(
          SandboxContext.liveCount,
          lessThan(liveBefore),
          reason: '被判废的上下文必须销毁，不能留着继续用',
        );

        // ④ App 可继续正常操作：同一实例再调一次，落在重建后的新上下文里
        final after = await jsEngine.callResult('detail', <String, Object?>{'id': 'x'});
        expect(after.isOk, isTrue, reason: '死循环之后 App 必须还能继续干活');
        expect(
          jsEngine.generation,
          greaterThan(generationBefore),
          reason: '后续请求应落在重建后的全新上下文（代数递增）',
        );

        // ⑤ 超时销毁在日志里留痕（真机排障要看的那一条）
        expect(
          logLinesContaining('判定污染'),
          isNotEmpty,
          reason: '销毁必须在日志里留痕',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '1-2 死循环不牵连其它图源：另起一个源全程可用',
      () async {
        final registry = await SourceRegistry.open(Section.novel);
        final dead = await registry.import(fixture('deadloop_source.js'));
        final alive = await registry.import(fixture('isolation_beta.js'));
        expect(dead.record, isNotNull);
        expect(alive.record, isNotNull);

        final deadEngine =
            await registry.engineFor(dead.record!.id) as QuickJsSourceEngine?;
        final aliveEngine =
            await registry.engineFor(alive.record!.id) as QuickJsSourceEngine?;
        expect(deadEngine, isNotNull);
        expect(aliveEngine, isNotNull);

        // 先确认正常源可用
        final before = await aliveEngine!.callResult('list', <String, Object?>{'page': 1});
        expect(before.isOk, isTrue, reason: '正常源在失控发生前应可用');

        // 让死循环源失控
        final crashed = await deadEngine!.callResult('list', <String, Object?>{'page': 1});
        expect(crashed.isOk, isFalse);

        // 正常源不受影响
        final after = await aliveEngine.callResult('list', <String, Object?>{'page': 1});
        expect(after.isOk, isTrue, reason: '一个源失控不得牵连另一个源');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '1-3 反复触发死循环 5 次：每次都收得回来，且原生句柄不持续增长（FFI 回收）',
      () async {
        final registry = await SourceRegistry.open(Section.novel);
        final imported = await registry.import(fixture('deadloop_source.js'));
        final engine = await registry.engineFor(imported.record!.id)
            as QuickJsSourceEngine?;
        expect(engine, isNotNull);
        final jsEngine = engine!.engine;

        final baselineLive = SandboxContext.liveCount;
        final baselineAbandoned = Qjs.abandonedRuntimes;
        final generations = <int>[];

        for (var round = 1; round <= 5; round++) {
          final result = await jsEngine.callResult('list', <String, Object?>{'page': 1});
          expect(
            result.isOk,
            isFalse,
            reason: '第 $round 轮死循环必须被判废',
          );
          generations.add(jsEngine.generation);
          // 每轮结束后立刻证明「还能继续用」
          final alive = await jsEngine.callResult('detail', <String, Object?>{'id': 'x'});
          expect(alive.isOk, isTrue, reason: '第 $round 轮之后实例仍应可用');
        }

        // 代数逐轮严格递增：每轮都是全新上下文，绝不复用旧的。
        // 起点是 1 而不是 2——引擎上下文是**首次操作时**才创建的，
        // 因此第 1 轮之前还没有任何上下文被销毁。
        expect(
          generations,
          orderedEquals(<int>[1, 2, 3, 4, 5]),
          reason: '每轮都应落在全新上下文（代数递增），实际 $generations',
        );
        expect(
          generations.toSet().length,
          generations.length,
          reason: '代数不得重复：重复即意味着复用了旧上下文',
        );

        // FFI 侧在册上下文数不增长（旧上下文确实被释放，不是攒着）
        expect(
          SandboxContext.liveCount,
          lessThanOrEqualTo(baselineLive),
          reason: '反复销毁重建不得让在册上下文累积'
              '（基线 $baselineLive，现在 ${SandboxContext.liveCount}）',
        );

        // 已知泄漏（deferred-todo.md「stringifyFn 泄漏 → JSRuntime 无法回收」）：
        // JSRuntime 因插件泄漏而只能记账不释放，这里只记录增量、不做断言，
        // 也不在本轮处理。
        final abandonedDelta = Qjs.abandonedRuntimes - baselineAbandoned;
        // ignore: avoid_print
        print('[FFI 内存观察] 5 轮死循环：在册上下文 $baselineLive → '
            '${SandboxContext.liveCount}；放弃回收的 JSRuntime 增加 $abandonedDelta '
            '（已知插件泄漏，记录用）');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });

  // ==========================================================================
  // 复测清单 2：图源导入冒烟
  // ==========================================================================

  group('清单 2 · 图源导入冒烟', () {
    test(
      '2-1 单条导入：脚本 → 落库 → 启用 → 取分类 / 列表，全链路无异常',
      () async {
        final registry = await SourceRegistry.open(Section.novel);
        final imported = await registry.import(fixture('isolation_alpha.js'));
        expect(imported.record, isNotNull, reason: '合法脚本应导入成功');
        expect(imported.record!.enabled, isTrue, reason: '导入后默认启用');

        // 列表可见
        expect(
          registry.sources.map((s) => s.id),
          contains(imported.record!.id),
        );

        // 执行加载：走与 App 浏览完全同一条数据源接口
        final engine =
            await registry.engineFor(imported.record!.id) as QuickJsSourceEngine?;
        expect(engine, isNotNull);

        final categories = await engine!.callResult('categories');
        expect(categories.isOk, isTrue, reason: '取分类不应报错');
        expect((categories.value! as List), isNotEmpty);

        final list = await engine.callResult('list', <String, Object?>{'page': 1});
        expect(list.isOk, isTrue, reason: '取列表不应报错');
        final items = (list.value! as Map)['items'] as List;
        expect(items, isNotEmpty, reason: '列表应有条目（不空转）');
        expect(
          logLinesContaining('判定污染'),
          isEmpty,
          reason: '正常加载不该产生任何上下文销毁',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '2-2 多选导入：一次导入多份脚本，逐条落库且互不干扰',
      () async {
        final registry = await SourceRegistry.open(Section.novel);
        // 模拟「本地多文件导入」：一次提交多份脚本文本，逐条走导入。
        final scripts = <String>[
          fixture('isolation_alpha.js'),
          fixture('isolation_beta.js'),
        ];

        final importedIds = <String>[];
        for (final script in scripts) {
          final outcome = await registry.import(script);
          expect(outcome.record, isNotNull, reason: '多选里的每一份都应导入成功');
          importedIds.add(outcome.record!.id);
        }

        // 两份都在库里，且 id 不同（不是互相覆盖）
        expect(importedIds.toSet().length, 2, reason: '两份脚本应是两个独立图源');
        final ids = registry.sources.map((s) => s.id).toList();
        for (final id in importedIds) {
          expect(ids, contains(id));
        }

        // 逐条都能跑，且各自的状态互不可见（隔离）
        for (final id in importedIds) {
          final engine = await registry.engineFor(id) as QuickJsSourceEngine?;
          expect(engine, isNotNull, reason: '$id 应能取到引擎');
          final list = await engine!.callResult('list', <String, Object?>{'page': 1});
          expect(list.isOk, isTrue, reason: '$id 应能正常出列表');
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '2-3 启用 / 停用 / 切换图源：状态落库、运行时按需释放、切换后出内容',
      () async {
        final registry = await SourceRegistry.open(Section.novel);
        final a = await registry.import(fixture('isolation_alpha.js'));
        final b = await registry.import(fixture('isolation_beta.js'));
        final idA = a.record!.id;
        final idB = b.record!.id;

        // 切换当前源到 B
        final selected = registry.selectSource(idB);
        expect(selected?.id, idB, reason: '应能切换当前源');
        expect(registry.currentSource()?.id, idB);

        // 停用 B：运行时释放，且不能再被选为当前源
        registry.setEnabled(idB, false);
        expect(
          registry.source(idB)!.enabled,
          isFalse,
          reason: '停用状态要落库',
        );
        expect(
          registry.selectSource(idB),
          isNull,
          reason: '停用的源不能被选为当前源',
        );
        expect(
          registry.currentSource()?.id,
          isNot(idB),
          reason: '当前源应回退到仍启用的源',
        );

        // 停用的源取不到引擎（运行时已释放）
        expect(
          await registry.engineFor(idB),
          isNull,
          reason: '停用即释放运行时',
        );

        // 重新启用 A 并切换过去，加载正常
        registry.setEnabled(idA, true);
        expect(registry.selectSource(idA)?.id, idA);
        final engineA = await registry.engineFor(idA) as QuickJsSourceEngine?;
        expect(engineA, isNotNull, reason: '重新启用后应能取到引擎');
        final list = await engineA!.callResult('list', <String, Object?>{'page': 1});
        expect(list.isOk, isTrue, reason: '切换后加载应正常');

        // 全程无上下文判废（正常操作不该触发销毁）
        expect(
          logLinesContaining('判定污染'),
          isEmpty,
          reason: '启停 / 切换是正常操作，不该产生任何销毁',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '2-4 冒烟循环 10 轮（导入 → 加载 → 释放）：无异常、原生句柄不累积',
      () async {
        final baselineLive = SandboxContext.liveCount;
        final baselineAbandoned = Qjs.abandonedRuntimes;

        for (var round = 1; round <= 10; round++) {
          final registry = await SourceRegistry.open(Section.novel);
          final imported = await registry.import(fixture('isolation_alpha.js'));
          expect(imported.record, isNotNull, reason: '第 $round 轮导入应成功');

          final engine =
              await registry.engineFor(imported.record!.id) as QuickJsSourceEngine?;
          expect(engine, isNotNull);
          final list = await engine!.callResult('list', <String, Object?>{'page': 1});
          expect(list.isOk, isTrue, reason: '第 $round 轮加载应成功');

          // 释放：与 App 退出板块 / 覆盖导入时的口径一致
          registry.release(imported.record!.id);
        }

        // 循环 10 轮之后，在册上下文不应累积
        expect(
          SandboxContext.liveCount,
          lessThanOrEqualTo(baselineLive),
          reason: '反复导入 / 释放不得让在册上下文累积'
              '（基线 $baselineLive，现在 ${SandboxContext.liveCount}）',
        );

        final abandonedDelta = Qjs.abandonedRuntimes - baselineAbandoned;
        // ignore: avoid_print
        print('[FFI 内存观察] 冒烟 10 轮：在册上下文 $baselineLive → '
            '${SandboxContext.liveCount}；放弃回收的 JSRuntime 增加 $abandonedDelta '
            '（已知插件泄漏，记录用）');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 180)),
    );

    test(
      '2-5 导入非法脚本 / 失控脚本都不闪退：给出可读原因，App 状态干净',
      () async {
        final registry = await SourceRegistry.open(Section.novel);

        // 语法错误
        final broken = await registry.import('var LumeSource = (');
        expect(broken.record, isNull, reason: '语法错误应被拒绝');
        expect(broken.message, isNotNull, reason: '要给出可读原因');

        // 跨板块脚本（宪法第 3 条）：该脚本自报 category=novel，
        // 必须把它导入**漫画**板块才能验证「跨板块被拒」。
        // （导入小说板块是合法的，属于反向对照，见 section_category_test）
        final comicRegistry = await SourceRegistry.open(Section.comic);
        final crossBoard = await comicRegistry.import(
          fixture('section_mismatch_novel.js'),
        );
        expect(
          crossBoard.record,
          isNull,
          reason: '声明为小说板块的脚本不得导入漫画板块',
        );
        expect(
          comicRegistry.sources,
          isEmpty,
          reason: '被拒的跨板块脚本不得落库',
        );

        // 以上失败都不得在库里留下痕迹
        expect(
          registry.sources,
          isEmpty,
          reason: '导入失败不得落库（失败即零写入）',
        );
        expect(
          logLinesContaining('拒绝跨板块源'),
          isNotEmpty,
          reason: '跨板块拒绝要留日志（安全事件必须可审计）',
        );
        expect(
          logLinesContaining('判定污染'),
          isEmpty,
          reason: '导入期的拒绝不该产生上下文销毁',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
