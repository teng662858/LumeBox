import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'source_scripts.dart';

/// 小说源快照用例的公共脚手架：真 QuickJS + 真脚本 + 快照应答。
///
/// 与 `test/nnhanman_source_test.dart` 同一套路，只是把「读字符串快照」换成
/// **按原始字节应答**——GBK 站点（PO文屋）的快照文件不是 UTF-8，
/// 用 `readAsStringSync()` 读会直接抛 FormatException（Dart 的 utf8 默认不放行非法字节）。
/// 字节口径下，UTF-8 站点与 GBK 站点走同一条路，脚本内部自己按站点编码解码。

/// 绑定 quickjs 原生桥；拿不到就整组跳过（不是失败）。
DynamicLibrary? resolveBridge() {
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

/// 读一份缓存里的资产（脚本或站点快照）；缺了就点名报错而不是空指针。
String readAssetText(String file) {
  final direct = File(file);
  if (direct.existsSync()) return direct.readAsStringSync();
  final path = sourceAssetPath(file);
  if (path == null) {
    throw StateError('缓存里没有 $file：跳过条件漏了这个文件？（先跑 `dart run tool/fetch_sources.dart`）');
  }
  return File(path).readAsStringSync();
}

/// 站点快照的**原始字节**（GBK / UTF-8 一律按字节给出）。
Uint8List readAssetBytes(String file) {
  final direct = File(file);
  if (direct.existsSync()) return direct.readAsBytesSync();
  final path = sourceAssetPath(file);
  if (path == null) {
    throw StateError('缓存里没有 $file：跳过条件漏了这个文件？（先跑 `dart run tool/fetch_sources.dart`）');
  }
  return File(path).readAsBytesSync();
}

/// 脚本路径（本机没拉缓存时用例会被 skip）。
String scriptPath(String name) => sourceScriptPath(name)!;

/// 用例需要的资产都在本机才跑；缺哪个点名哪一个。
String? skipUnless(List<String> names) {
  if (!Qjs.isAvailable) {
    return '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';
  }
  for (final name in names) {
    if (sourceAssetPath(name) == null) return sourceScriptsSkipReason(name);
  }
  return null;
}

/// 只回登记过的 GET 地址（按原始字节），未登记的一律 404——
/// 于是「脚本请求了别的地址」会以拉取失败的形式暴露出来，而不是静默返回空。
class SnapshotHttp extends LumeHttp {
  SnapshotHttp({this.responses = const <String, List<int>>{}}) : super();

  /// url -> 响应体字节。
  final Map<String, List<int>> responses;

  /// 本次运行里收到过请求的地址（断言「地址拼对了 / 没多请求」用）。
  final Set<String> seen = <String>{};

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    int? maxBytes,
    Duration? timeout,
  }) async {
    seen.add(url);
    final response = responses[url];
    if (response == null) {
      return LumeHttpResponse(
        statusCode: 404,
        body: Uint8List.fromList(utf8.encode('not found: $url')),
        headers: const <String, String>{},
      );
    }
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(response),
      headers: const <String, String>{'content-type': 'text/html'},
    );
  }
}

/// 用快照文件拼一张 url -> 字节 的表。
Map<String, List<int>> snapshotMap(Map<String, String> urlToFile) {
  return urlToFile.map(
    (url, file) => MapEntry(url, readAssetBytes(file)),
  );
}

class BootedSource {
  BootedSource({required this.data, required this.dispose});

  final JsDataSource data;
  final void Function() dispose;
}

/// 起一个真沙箱：真引擎 + 真脚本 + 给定的 HTTP 替身。
Future<BootedSource> bootNovelSource(
  String scriptName, {
  required SnapshotHttp http,
  Section section = Section.novel,
}) async {
  final script = readAssetText(scriptPath(scriptName));
  final host = LumeSourceHost(
    http,
    timeout: const Duration(seconds: 5),
    section: section,
    sourceId: 'snapshot',
  );
  final sandbox = LumeSandbox.create(
    id: host.expectedSandboxId,
    policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
    host: host,
    polyfills: LumeSourcePolyfills.forSection(section),
  );
  final loaded = await sandbox.load(script);
  expect(loaded.isOk, isTrue, reason: '脚本必须能载入: $scriptName: ${loaded.error}');
  return BootedSource(
    data: JsDataSource(
      id: 'snapshot',
      name: 'snapshot',
      section: section,
      runtime: SandboxRuntime(sandbox),
    ),
    dispose: () {
      sandbox.dispose();
      host.dispose();
    },
  );
}

class SandboxRuntime implements JsSourceRuntime {
  SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'home', 'list', 'detail', 'chapters', 'content'};

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
}
