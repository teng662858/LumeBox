import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';

/// 猫源垫片的真实引擎验证（与 sandbox_native_test 同一套原生桥）。
///
/// 覆盖：垫片全量可用（process / Buffer / require / console / 定时器）、
/// 只对猫源注入、WASM 与 .node 的友好拒绝、网络仍走宿主桥接层、
/// 以及超时销毁重建后垫片状态全新。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  /// 建一个带猫源垫片的沙箱。
  LumeSandbox catSandbox({SandboxHost host = const _NullHost()}) =>
      LumeSandbox.create(
        id: 'cat-shim',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.catRegistry,
      );

  Future<Object?> evalValue(LumeSandbox sandbox, String script) async {
    final result = await sandbox.eval(script);
    expect(result.isOk, isTrue, reason: result.error?.message);
    return result.value;
  }

  group('猫源垫片', () {
    test('全量注入：process / Buffer / require / console 补全 / 定时器补全', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(await evalValue(sandbox, 'typeof globalThis.process'), 'object');
      expect(await evalValue(sandbox, 'typeof globalThis.Buffer'), 'function');
      expect(await evalValue(sandbox, 'typeof globalThis.require'), 'function');
      expect(
        await evalValue(sandbox, 'typeof globalThis.setInterval'),
        'function',
      );
      expect(
        await evalValue(sandbox, 'typeof globalThis.setImmediate'),
        'function',
      );
      expect(await evalValue(sandbox, 'typeof console.info'), 'function');
      expect(await evalValue(sandbox, 'typeof console.debug'), 'function');
      expect(await evalValue(sandbox, 'typeof console.assert'), 'function');
    });

    test('只对猫源注入：通用垫片表里没有这些内建', () async {
      final generic = LumeSandbox.create(
        id: 'novel-shim',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: const _NullHost(),
        polyfills: LumeSourcePolyfills.registry,
      );
      addTearDown(generic.dispose);

      expect(await evalValue(generic, 'typeof globalThis.process'), 'undefined');
      expect(await evalValue(generic, 'typeof globalThis.Buffer'), 'undefined');
      expect(await evalValue(generic, 'typeof globalThis.require'), 'undefined');
      expect(await evalValue(generic, 'typeof globalThis.setInterval'), 'undefined');
      // 通用表仍有网络垫片。
      expect(await evalValue(generic, 'typeof globalThis.fetch'), 'function');

      // 猫源表同样保留网络垫片（在通用垫片之上叠加）。
      final cat = catSandbox();
      addTearDown(cat.dispose);
      expect(await evalValue(cat, 'typeof globalThis.fetch'), 'function');
    });

    test('process：平台 / 环境 / nextTick / 不假装 Node 版本', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(await evalValue(sandbox, 'process.platform'), 'darwin');
      expect(await evalValue(sandbox, 'typeof process.env'), 'object');
      expect(await evalValue(sandbox, 'Object.keys(process.env).length'), 0);
      expect(await evalValue(sandbox, 'process.version'), 'v0.0.0-lume');
      expect(await evalValue(sandbox, 'process.versions.node === undefined'), true);

      // nextTick 是微任务：同步阶段看不到，排空后可看到。
      final immediate = await evalValue(sandbox, '''
        (function () {
          globalThis.__order = [];
          __order.push('sync');
          process.nextTick(function () { __order.push('tick'); });
          __order.push('after');
          return JSON.stringify(__order);
        })()
      ''');
      expect(immediate, <String>['sync', 'after']);
      expect(
        await evalValue(sandbox, 'JSON.stringify(__order)'),
        <String>['sync', 'after', 'tick'],
      );

      // 退出 / 杀进程这类能力不存在：抛出友好错误而不是静默。
      final exitError = await evalValue(sandbox, '''
        (function () {
          try { process.exit(0); return 'no-error'; }
          catch (error) { return error.code + '|' + error.message; }
        })()
      ''');
      expect(exitError, contains('LUME_UNSUPPORTED'));
      expect(exitError, contains('process.exit'));
    });

    test('Buffer：utf8 / base64 / hex 编解码与常用方法', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      // 常见用法：base64 编解码。
      expect(
        await evalValue(sandbox, "Buffer.from('hello').toString('base64')"),
        'aGVsbG8=',
      );
      expect(
        await evalValue(sandbox, "Buffer.from('aGVsbG8=', 'base64').toString('utf8')"),
        'hello',
      );
      // URL 安全 base64 也认。
      expect(
        await evalValue(sandbox, "Buffer.from('a-_w', 'base64').toString('hex')"),
        '6beff0',
      );
      // hex 与 utf8（含中文与代理对）。
      expect(
        await evalValue(sandbox, "Buffer.from('414243', 'hex').toString('utf8')"),
        'ABC',
      );
      expect(
        await evalValue(sandbox, "Buffer.from('猫源😺', 'utf8').toString('hex')"),
        'e78cabe6ba90f09f98ba',
        reason: '含中文与代理对的 UTF-8 编码',
      );
      expect(
        await evalValue(sandbox, "Buffer.from('猫源', 'utf8').toString('utf8')"),
        '猫源',
      );

      // 静态与实例方法。
      expect(await evalValue(sandbox, 'Buffer.isBuffer(Buffer.from([1, 2, 3]))'), true);
      expect(await evalValue(sandbox, 'Buffer.isBuffer({})'), false);
      expect(await evalValue(sandbox, 'Buffer.alloc(5).length'), 5);
      expect(await evalValue(sandbox, 'Buffer.alloc(5).toString("hex")'), '0000000000');
      expect(
        await evalValue(sandbox, "Buffer.byteLength('猫源', 'utf8')"),
        6,
      );
      expect(
        await evalValue(
          sandbox,
          "Buffer.concat([Buffer.from('ab'), Buffer.from('cd')]).toString('utf8')",
        ),
        'abcd',
      );
      expect(
        await evalValue(sandbox, "Buffer.from('abcdef').slice(1, 4).toString('utf8')"),
        'bcd',
      );
      expect(
        await evalValue(
          sandbox,
          "Buffer.from('ab').equals(Buffer.from('ab'))",
        ),
        true,
      );
      // 下标读写（引擎支持 Proxy 时生效）。
      final indexAccess = await evalValue(sandbox, '''
        (function () {
          if (typeof Proxy !== 'function') return 'no-proxy';
          return 'idx=' + Buffer.from([7, 8])[1];
        })()
      ''');
      expect(indexAccess, anyOf('idx=8', 'no-proxy'));
      expect(
        await evalValue(sandbox, 'JSON.stringify(Buffer.from([1, 255]))'),
        <String, Object?>{'type': 'Buffer', 'data': <int>[1, 255]},
      );
      // 编码白名单：utf8 / utf16le / base64 / hex / latin1，其余友好错误。
      expect(
        await evalValue(sandbox, "Buffer.from('猫源', 'utf16le').toString('utf16le')"),
        '猫源',
        reason: 'utf16le 已在扩展轮补齐',
      );
      final encodingError = await evalValue(sandbox, '''
        (function () {
          try { Buffer.from('x').toString('gbk'); return 'no-error'; }
          catch (error) { return error.code + '|' + error.message; }
        })()
      ''');
      expect(encodingError, contains('LUME_UNSUPPORTED'));
    });

    test('require：内建与模块垫片可用，越界模块友好拒绝（net / .node / WASM）', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(
        await evalValue(sandbox, "require('buffer').Buffer === Buffer"),
        true,
      );
      expect(
        await evalValue(sandbox, "require('node:process') === process"),
        true,
      );
      expect(await evalValue(sandbox, "typeof require('timers').setInterval"), 'function');
      expect(await evalValue(sandbox, "require('console').log === console.log"), true);
      // 模块垫片：crypto / path / http 等已就位。
      expect(await evalValue(sandbox, "typeof require('crypto').createHash"), 'function');
      expect(await evalValue(sandbox, "typeof require('path').join"), 'function');
      expect(await evalValue(sandbox, "typeof require('http').request"), 'function');
      expect(await evalValue(sandbox, "typeof require('fs').readFileSync"), 'function');

      Future<String> requireError(String name) async =>
          (await evalValue(sandbox, '''
            (function () {
              try { require(${_jsString(name)}); return 'no-error'; }
              catch (error) { return error.code + '|' + error.message; }
            })()
          '''))! as String;

      // 底层网络与进程能力依旧被拒绝（没有真实 socket / 子进程）。
      final net = await requireError('node:net');
      expect(net, contains('LUME_UNSUPPORTED'));
      expect(net, contains('沙箱不提供进程、线程与底层网络'), reason: '要指向宿主桥接层');

      final tls = await requireError('tls');
      expect(tls, contains('LUME_UNSUPPORTED'));

      final native = await requireError('crypto.node');
      expect(native, contains('.node'));

      final wasm = await requireError('fast.wasm');
      expect(wasm, contains('WebAssembly'));

      final unknown = await requireError('lodash');
      expect(unknown, contains('buffer / process / console / timers'));
    });

    test('WebAssembly：存根一用就报友好错误，不做兼容', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      expect(await evalValue(sandbox, 'typeof WebAssembly'), 'object');
      final wasmError = await evalValue(sandbox, '''
        (function () {
          try { WebAssembly.compile(new Uint8Array([0])); return 'no-error'; }
          catch (error) { return error.code + '|' + error.message; }
        })()
      ''');
      expect(wasmError, contains('LUME_UNSUPPORTED'));
      expect(wasmError, contains('WebAssembly'));

      final ctorError = await evalValue(sandbox, '''
        (function () {
          try { new WebAssembly.Module(new Uint8Array([0])); return 'no-error'; }
          catch (error) { return error.message; }
        })()
      ''');
      expect(ctorError, contains('不支持'));
    });

    test('定时器：setInterval 周期执行、clearInterval 停下、setTimeout 附加参数', () async {
      final sandbox = catSandbox();
      addTearDown(sandbox.dispose);

      await evalValue(sandbox, '''
        globalThis.__ticks = 0;
        globalThis.__iv = setInterval(function () { globalThis.__ticks += 1; }, 10);
        globalThis.__sum = 0;
        setTimeout(function (a, b) { globalThis.__sum = a + b; }, 0, 2, 3);
        'scheduled'
      ''');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      final ticks = await evalValue(sandbox, 'globalThis.__ticks') as int;
      expect(ticks, greaterThanOrEqualTo(2), reason: '间隔定时器应当跑了多轮');
      expect(await evalValue(sandbox, 'globalThis.__sum'), 5, reason: '附加参数透传');

      await evalValue(sandbox, 'clearInterval(globalThis.__iv); "cleared"');
      final afterClear = await evalValue(sandbox, 'globalThis.__ticks') as int;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await evalValue(sandbox, 'globalThis.__ticks'), afterClear);
    });

    test('网络仍走宿主桥接层：fetch 由 Dart 侧发出', () async {
      final host = _RecordingHost();
      final sandbox = catSandbox(host: host);
      addTearDown(sandbox.dispose);

      await evalValue(sandbox, '''
        globalThis.__reply = null;
        fetch('https://example.com/data.json').then(function (response) {
          globalThis.__reply = response.status + '|' + response.body;
        });
        'started'
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(host.calls, <String>['https://example.com/data.json']);
      expect(await evalValue(sandbox, 'globalThis.__reply'), '200|ok');
    });

    test('超时销毁重建：上下文与垫片状态都是全新的', () async {
      final sandbox = LumeSandbox.create(
        id: 'cat-timeout',
        policy: SandboxPolicy.strict.copyWith(allowHostAccess: true),
        host: _StuckHost(),
        polyfills: LumeSourcePolyfills.catRegistry,
      );
      addTearDown(sandbox.dispose);

      await sandbox.load('''
        var LumeSource = {
          hang: function () {
            return LumeBridge.invoke('http.fetch', { url: 'https://never.example' });
          }
        };
      ''');
      // 污染垫片状态：重建后这些痕迹必须消失。
      await evalValue(sandbox, '''
        globalThis.__mutated = 'dirty';
        Buffer.__dirty = true;
        process.__dirty = true;
        'prepared'
      ''');

      final generationBefore = sandbox.generation;
      final result = await sandbox.call('LumeSource.hang');
      expect(result.isOk, isFalse);
      expect(result.error!.kind, SandboxErrorKind.timeout);

      // 脚本被自动重放（重建在下次操作时发生）。
      expect(await evalValue(sandbox, 'typeof LumeSource.hang'), 'function');
      expect(sandbox.generation, greaterThan(generationBefore));
      // 垫片重新注入且是全新的：全局痕迹与垫片上的痕迹都不在。
      expect(await evalValue(sandbox, 'typeof globalThis.Buffer'), 'function');
      expect(await evalValue(sandbox, 'typeof globalThis.__mutated'), 'undefined');
      expect(await evalValue(sandbox, 'typeof Buffer.__dirty'), 'undefined');
      expect(await evalValue(sandbox, 'typeof process.__dirty'), 'undefined');
      // 重建后依然能正常编码。
      expect(
        await evalValue(sandbox, "Buffer.from('again').toString('base64')"),
        'YWdhaW4=',
      );
    });

    test('两个猫源实例互不共享垫片状态', () async {
      final a = catSandbox();
      final b = LumeSandbox.create(
        id: 'cat-shim-b',
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: const _NullHost(),
        polyfills: LumeSourcePolyfills.catRegistry,
      );
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await evalValue(a, "globalThis.__onlyA = 1; Buffer.__onlyA = true; 'ok'");
      expect(await evalValue(b, 'typeof globalThis.__onlyA'), 'undefined');
      expect(await evalValue(b, 'typeof Buffer.__onlyA'), 'undefined');
    });
  }, skip: skipReason);
}

class _NullHost implements SandboxHost {
  const _NullHost();

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    throw const SandboxHostException('未支持的宿主方法');
  }
}

class _RecordingHost implements SandboxHost {
  final List<String> calls = <String>[];

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    final payload = request.payload;
    calls.add('${payload is Map ? payload['url'] : payload}');
    return <String, Object?>{
      'status': 200,
      'headers': <String, String>{'content-type': 'application/json'},
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

/// 把 Dart 字符串安全地嵌进 JS 单引号字面量（转义反斜杠与单引号）。
String _jsString(String value) {
  final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  return "'$escaped'";
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
