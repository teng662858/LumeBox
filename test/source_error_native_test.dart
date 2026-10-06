import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

/// 「网络异常」这条状态的端到端证据：在真实引擎里让 `fetch` 真的失败，
/// 断言它一路走到数据源层仍是 network，而不是被混进脚本报错。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎 · 网络失败归一', () {
    test('fetch 失败带网络标记，最终归一到 network', () async {
      final host = LumeSourceHost(
        LumeHttp(client: _FailingClient()),
        timeout: const Duration(seconds: 2),
        section: Section.video,
        sourceId: 'network-probe',
      );
      final sandbox = LumeSandbox.create(
        id: host.expectedSandboxId,
        policy: SandboxPolicy.standard.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.registry,
      );
      addTearDown(sandbox.dispose);

      final loaded = await sandbox.load('''
var LumeSource = {
  id: 'network-probe',
  name: '网络探针',
  async list() {
    await fetch('https://example.invalid/list');
    return [];
  }
};
''');
      expect(loaded.isOk, isTrue, reason: '${loaded.error}');

      final result = await sandbox.call(
        'LumeSource.list',
        <String, Object?>{'page': 1},
      );
      expect(result.isOk, isFalse, reason: '网络失败必须体现为失败，而不是空结果');
      expect(
        result.error!.message,
        contains(LumeSourceHost.networkFailureMarker),
        reason: '宿主层应在 HTTP 边界打上网络标记',
      );

      final mapped = mapSandboxFailure(result.error!);
      expect(mapped.kind, SourceErrorKind.network);
      expect(stateForError(mapped), SourceStateKind.networkError);
    }, skip: skipReason);

    test('脚本自身抛错不会被误判为网络异常', () async {
      final sandbox = LumeSandbox.create(id: 'script-failure');
      addTearDown(sandbox.dispose);

      await sandbox.load('''
var LumeSource = {
  id: 'script-probe',
  name: '脚本探针',
  async list() { throw new Error('脚本内部错误'); }
};
''');
      final result = await sandbox.call('LumeSource.list');
      expect(result.isOk, isFalse);
      expect(mapSandboxFailure(result.error!).kind, SourceErrorKind.callFailed);
      expect(
        stateForError(mapSandboxFailure(result.error!)),
        SourceStateKind.scriptError,
      );
    }, skip: skipReason);
  });
}

/// 必定失败的网络客户端：模拟连接失败（真实网络异常最常见的形态）。
class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('模拟连接失败', request.url);
  }
}

/// Windows 下取构建产物，其他平台走进程镜像（与 sandbox_native_test 一致）。
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
