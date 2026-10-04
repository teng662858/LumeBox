import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

/// 真实引擎用例：直接驱动 quickjs 原生桥，验证隔离、异常、内存上限、
/// 超时销毁重建、宿主代理与资源释放。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发 quickjs 的泄漏断言并 abort 进程
    // （插件在每个上下文里泄漏一个 stringifyFn），实测结论同样适用于测试进程。
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎', () {
    test('求值结果按 JSON 回传 Dart', () async {
      final sandbox = LumeSandbox.create(id: 'eval');
      addTearDown(sandbox.dispose);

      expect((await sandbox.eval('1+1')).value, 2);

      final structured = await sandbox.eval('JSON.stringify({n: 1+1, list: [1,2]})');
      expect(structured.isOk, isTrue);
      final decoded = structured.value! as Map;
      expect(decoded['n'], 2);
      expect(decoded['list'], <Object?>[1, 2]);
    });

    test('多个上下文互相隔离', () async {
      final a = LumeSandbox.create(id: 'iso-a');
      final b = LumeSandbox.create(id: 'iso-b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      expect((await a.eval('globalThis.__mark = 42; __mark')).value, 42);
      expect((await b.eval('typeof __mark')).value, 'undefined');
      expect((await a.eval('__mark')).value, 42);
      expect(a.generation, 1);
      expect(b.generation, 1);
    });

    test('脚本异常给出真实消息且不污染上下文', () async {
      final sandbox = LumeSandbox.create(id: 'errors');
      addTearDown(sandbox.dispose);

      final thrown = await sandbox.eval('throw new Error("boom")');
      expect(thrown.isOk, isFalse);
      expect(thrown.error!.kind, SandboxErrorKind.script);
      expect(thrown.error!.message, contains('boom'));

      final typeError = await sandbox.eval('null.foo');
      expect(typeError.error!.kind, SandboxErrorKind.script);
      expect(typeError.error!.message, contains('TypeError'));

      // 异常已被消费：旧实现在这里会被残留异常持续污染。
      expect(sandbox.isPoisoned, isFalse);
      expect((await sandbox.eval('1+1')).value, 2);
      expect(sandbox.generation, 1);
    });

    test('Dart ↔ JS 调用桥：载入脚本后按名调用', () async {
      final sandbox = LumeSandbox.create(id: 'bridge');
      addTearDown(sandbox.dispose);

      final loaded = await sandbox.load('''
        var LumeSource = {
          latest: async function (argument) {
            var page = argument && argument.page ? argument.page : 1;
            return [{ id: 'demo-' + page, title: '条目 ' + page }];
          }
        };
      ''');
      expect(loaded.isOk, isTrue);

      final result = await sandbox.call('LumeSource.latest', <String, Object?>{'page': 3});
      expect(result.isOk, isTrue);
      final items = result.value! as List;
      expect((items.first as Map)['title'], '条目 3');

      final missing = await sandbox.call('LumeSource.notImplemented');
      expect(missing.isOk, isFalse);
      expect(missing.error!.message, contains('方法不存在'));
    });

    test('宿主代理：默认拒绝外部能力，显式注入后可用', () async {
      const probe = '''
        var probe = async function () {
          try {
            var reply = await LumeBridge.invoke('http.fetch', { url: 'https://example.com' });
            return { allowed: true, status: reply && reply.status ? reply.status : 0 };
          } catch (error) {
            return { allowed: false, message: String(error && error.message ? error.message : error) };
          }
        };
      ''';

      final closed = LumeSandbox.create(id: 'closed');
      addTearDown(closed.dispose);
      await closed.load(probe);
      final denied = await closed.call('probe');
      expect(denied.isOk, isTrue);
      final deniedValue = denied.value! as Map;
      expect(deniedValue['allowed'], isFalse);
      expect('${deniedValue['message']}', contains('未开放外部能力'));

      final opened = LumeSandbox.create(
        id: 'opened',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: _FakeHost(),
      );
      addTearDown(opened.dispose);
      await opened.load(probe);
      final allowed = await opened.call('probe');
      expect(allowed.isOk, isTrue);
      final allowedValue = allowed.value! as Map;
      expect(allowedValue['allowed'], isTrue);
      expect(allowedValue['status'], 200);
    });

    test('内存上限硬性中止分配型失控，并重建全新上下文', () async {
      final sandbox = LumeSandbox.create(
        id: 'memory',
        policy: SandboxPolicy.standard.copyWith(memoryLimitBytes: 16 * 1024 * 1024),
        polyfills: PolyfillRegistry(<SandboxPolyfill>[const _ShimPolyfill()]),
      );
      addTearDown(sandbox.dispose);

      final runaway = await sandbox.eval(
        'var junk = []; for (;;) { junk.push(new Array(10000).fill("x")); }',
      );
      expect(runaway.isOk, isFalse);
      expect(runaway.error!.kind, SandboxErrorKind.memory);
      final generationBefore = sandbox.generation;

      // 上下文已被销毁：下一次操作拿到全新上下文，且垫片随之重新注入。
      expect((await sandbox.eval('1+1')).value, 2);
      expect(sandbox.generation, greaterThan(generationBefore));
      expect((await sandbox.eval('typeof __lumeProbeShim')).value, 'string');
    });

    test('宿主无响应触发超时：销毁上下文并按脚本重建', () async {
      final sandbox = LumeSandbox.create(
        id: 'timeout',
        policy: SandboxPolicy.strict.copyWith(allowHostAccess: true),
        host: _StuckHost(),
      );
      addTearDown(sandbox.dispose);

      await sandbox.load('''
        var LumeSource = {
          hang: function () {
            return LumeBridge.invoke('http.fetch', { url: 'https://never.example' });
          }
        };
      ''');

      final generationBefore = sandbox.generation;
      final result = await sandbox.call('LumeSource.hang');
      expect(result.isOk, isFalse);
      expect(result.error!.kind, SandboxErrorKind.timeout);
      expect(sandbox.lastFailure!.kind, SandboxErrorKind.timeout);

      // 旧上下文已销毁，新上下文可用且脚本被自动重放。
      expect((await sandbox.eval('1+1')).value, 2);
      expect(
        (await sandbox.eval('typeof LumeSource.hang')).value,
        'function',
      );
      expect(sandbox.generation, greaterThan(generationBefore));
    });

    test('销毁可重复调用并逐次回收上下文', () async {
      for (var i = 0; i < 12; i++) {
        final sandbox = LumeSandbox.create(id: 'cycle$i');
        expect((await sandbox.eval('1+1')).value, 2);
        sandbox.dispose();
        sandbox.dispose();
      }
      expect(SandboxContext.liveCount, 0);
      expect(Qjs.abandonedRuntimes, greaterThanOrEqualTo(12));
    });

    test('释放后的操作返回 disposed 而不是崩溃', () async {
      final sandbox = LumeSandbox.create(id: 'dead');
      sandbox.dispose();
      final result = await sandbox.eval('1+1');
      expect(result.isOk, isFalse);
      expect(result.error!.kind, SandboxErrorKind.disposed);
    });

    test('管理表与作用域的销毁语义', () async {
      final manager = SandboxManager();
      final first = manager.open('shared');
      final second = manager.open('shared');
      expect(identical(first, second), isTrue);
      expect(manager.count, 1);
      manager.disposeAll();
      expect(manager.count, 0);
      expect(first.isDisposed, isTrue);

      final scope = SandboxScope(owner: 'page');
      final owned = scope.open('engine');
      expect(scope.count, 1);
      scope.dispose();
      expect(scope.isDisposed, isTrue);
      expect(owned.isDisposed, isTrue);

      // 作用域销毁后仍可调用，但拿到的沙箱立刻被回收。
      final late = scope.open('late');
      expect(late.isDisposed, isTrue);
    });

    test('中断通路探测结果与降级事实一致', () {
      // 当前插件构建把 quickjs 本体符号设为 hidden，中断通路不可用，
      // 超时保护依赖预算机制（真值变化时该断言会提醒更新文档）。
      expect(Qjs.isAvailable, isTrue);
      expect(SandboxGuard.interruptAvailable, Qjs.interruptHookAvailable);
    });
  }, skip: skipReason);
}

class _FakeHost implements SandboxHost {
  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    if (request.method != SandboxHostMethods.httpFetch) {
      throw const SandboxHostException('未支持的宿主方法');
    }
    return <String, Object?>{
      'status': 200,
      'headers': <String, String>{'content-type': 'text/plain'},
      'body': 'ok',
    };
  }
}

/// 永远不返回的宿主：用于制造超时。
class _StuckHost implements SandboxHost {
  @override
  Future<Object?> invoke(SandboxHostRequest request) =>
      Completer<Object?>().future;
}

class _ShimPolyfill implements SandboxPolyfill {
  const _ShimPolyfill();

  @override
  String get id => 'test.probe.shim';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => "globalThis.__lumeProbeShim = 'injected';";
}

/// Windows 下取构建产物，其他平台走进程镜像。
DynamicLibrary? _resolveBridge() {
  if (!Platform.isWindows) {
    try {
      return DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (!file.existsSync()) continue;
    try {
      return DynamicLibrary.open(file.absolute.path);
    } catch (_) {
      continue;
    }
  }
  return null;
}
