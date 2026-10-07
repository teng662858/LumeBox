import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

/// 真实引擎下的桥接验证（用户反馈的 Bug2）：
///
/// 宿主按严格顺序注入 console / 定时器 / 环境垫片 → **全局桥接对象
/// `LumeSource`** → 才执行用户脚本；因此
/// - 脚本只写顶层 `async function getList(page)` 也能跑通（不再出现
///   「全局对象不存在: LumeSource」）；
/// - 脚本可以直接用 `LumeSource.http.*`（宿主网络）与 `LumeSource.fs.*`
///   （按图源隔离的沙盒存储）；
/// - 对象式脚本（`var LumeSource = { … }`）照旧可用，且合并后桥接能力不丢。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言，测试进程同样适用。
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎 · LumeSource 桥接', () {
    late _RecordingHttp http;
    late LumeSourceHost host;
    late LumeSandbox sandbox;

    /// 按生产口径建沙箱（同一套策略与垫片登记表），再载入脚本。
    Future<JsDataSource> boot(
      String script, {
      Section section = Section.video,
    }) async {
      http = _RecordingHttp();
      host = LumeSourceHost(
        http,
        timeout: const Duration(seconds: 3),
        section: section,
        sourceId: 'bridge-source',
      );
      sandbox = LumeSandbox.create(
        id: host.expectedSandboxId,
        policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.forSection(section),
      );
      addTearDown(() {
        sandbox.dispose();
        host.dispose();
      });
      final loaded = await sandbox.load(script);
      expect(loaded.isOk, isTrue, reason: '脚本必须能载入: ${loaded.error}');
      return JsDataSource(
        id: 'bridge-source',
        name: '桥接用例源',
        section: section,
        runtime: _SandboxRuntime(sandbox),
      );
    }

    test('用户验证脚本：顶层 getList(page) 直接跑通', () async {
      final source = await boot(_userVerificationScript);

      final list = await source.list(page: 2);
      expect(list.items.single.title, '测试视频');
      expect(list.items.single.id, 'https://example.com/demo.mp4');
      expect(list.hasMore, isFalse);
      // 位置参数：函数式契约的第一位就是页码（不是对象）。
      expect((await sandbox.eval('__seenPage')).value, 2);
      expect((await sandbox.eval('typeof __seenPage')).value, 'number');

      // 头部元信息仍由脚本自己声明（桥接对象不冒充 id / name）。
      expect(
        SourceMetadata.parseHeader(_userVerificationScript)?.id,
        'demo-video',
      );
      expect(
        (await sandbox.eval('JSON.stringify({id: LumeSource.id})')).value,
        <String, Object?>{},
      );
    });

    test('函数式契约：分类 / 搜索 / 详情 / 章节 / 内容全套可用', () async {
      final source = await boot(_functionStyleScript);

      final categories = await source.categories();
      expect(categories.single.title, '分类一');

      final page = await source.list(page: 3);
      expect(page.items.single.id, 'v3');

      // 关键词走 getSearch(keyword, page)。
      final search = await source.list(keyword: '关键词', page: 2);
      expect(search.items.single.title, '关键词#2');

      final detail = await source.detail('v3');
      expect(detail?.title, '详情 v3');

      final chapters = await source.chapters('v3');
      expect(chapters.single.id, 'v3-1');

      final content = await source.content(itemId: 'v3', chapterId: 'v3-1');
      expect(content, isA<VideoContent>());
      expect(
        (content! as VideoContent).url.toString(),
        'https://example.com/v3/v3-1.mp4',
      );
    });

    test('桥接宿主能力：http 走宿主网络，fs 落在按图源隔离的沙盒存储', () async {
      final source = await boot(_bridgeCapabilityScript);

      final list = await source.list();
      expect(http.urls.single, 'https://api.example.com/list');
      expect(list.items.single.title, 'cache/list.json');
      expect(list.items.single.id, '列表缓存');
      expect(host.store.read('cache/list.json'), '列表缓存');

      // 脚本删掉之后，宿主侧的存储同步消失（fs 就是这张表的门面）。
      final removed = await sandbox.call('LumeSource.fs.remove', '/cache/list.json');
      expect(removed.value, isTrue);
      expect(host.store.read('cache/list.json'), isNull);
    });

    test('对象式脚本合并后桥接能力仍在', () async {
      final source = await boot(_objectStyleScript);

      expect((await sandbox.eval('LumeSource.id')).value, 'obj-source');
      expect(
        (await sandbox.eval('typeof LumeSource.http.get')).value,
        'function',
        reason: '脚本对象不能把宿主 HTTP 能力盖掉',
      );
      expect((await sandbox.eval('typeof LumeSource.fs.readText')).value, 'function');

      final list = await source.list();
      expect(list.items.single.id, 'o1');
      // 对象式收对象入参（与函数式的位置参数区分开）。
      expect(
        (await sandbox.eval('JSON.stringify(__seenArgument)')).value,
        <String, Object?>{'page': 1},
      );
    });

    test('let / const 声明的 LumeSource 同样被识别', () async {
      final source = await boot(_lexicalScript);
      final list = await source.list();
      expect(list.items.single.id, 'l1');
      expect((await sandbox.eval('LumeSource.id')).value, 'lex', reason: '脚本自己的对象');
    });

    test('反复赋值：非对象忽略、对象合并，桥接能力始终在', () async {
      final source = await boot(_reassignScript);
      final list = await source.list();
      expect(list.items.single.id, 'r1');
      expect((await sandbox.eval('LumeSource.id')).value, 'again');
      expect((await sandbox.eval('LumeSource.name')).value, '二次赋值源');
      expect((await sandbox.eval('typeof LumeSource.http.get')).value, 'function');
      expect(
        (await sandbox.eval('typeof LumeSource.fs.writeText')).value,
        'function',
      );
    });

    test('严格顺序：脚本执行时桥接与垫片都已就位', () async {
      final source = await boot(_bootOrderScript);
      expect(
        (await sandbox.eval('__boot')).value,
        'object|function|function|function|function|object',
        reason: 'LumeSource / LumeSource.http / LumeSource.fs / console / 定时器 / LumeBridge',
      );
      expect((await source.list()).items, isEmpty);
    });

    test('猫源：Node 环境垫片与桥接对象共存', () async {
      final source = await boot(_catEnvironmentScript, section: Section.cat);
      expect(
        (await sandbox.eval('__catEnv')).value,
        'object|function|function|function',
        reason: 'process / Buffer / require / LumeSource.fs',
      );
      expect((await source.list()).items, isEmpty);
    });

    test('脚本没实现方法：给出「该实现哪个函数」的可读报错', () async {
      final source = await boot(_metadataOnlyScript);

      await expectLater(
        source.list(),
        throwsA(
          isA<SourceException>()
              .having((error) => error.kind, 'kind', SourceErrorKind.callFailed)
              .having((error) => error.message, 'message', contains('没有实现 list 方法'))
              .having((error) => error.message, 'message', contains('getList'))
              .having(
                (error) => error.message,
                'message',
                isNot(contains('全局对象不存在')),
              ),
        ),
      );
    });
  }, skip: skipReason);
}

/// 用户给的验证脚本（头部元信息是导入所必需的，其余保持原样）。
const String _userVerificationScript = '''
// LumeSource: {"id":"demo-video","name":"公开样片测试源","version":"1.0.0"}
async function getList(page) {
  globalThis.__seenPage = page;
  return {
    list: [{ title: '测试视频', url: 'https://example.com/demo.mp4' }],
    hasMore: false
  };
}
''';

/// 函数式契约全套：顶层函数 + 搜索单列。
const String _functionStyleScript = '''
// LumeSource: {"id":"demo-func","name":"函数式源","version":"1.0.0"}
function getCategories() {
  return [{ id: 'c1', title: '分类一' }];
}

async function getList(page) {
  return { list: [{ id: 'v' + page, title: '第' + page + '页' }], hasMore: page < 2 };
}

async function getSearch(keyword, page) {
  return { list: [{ id: 's', title: keyword + '#' + page }] };
}

async function getDetail(id) {
  return { id: id, title: '详情 ' + id };
}

async function getChapters(id) {
  return [{ id: id + '-1', title: '第一集' }];
}

async function getContent(id, chapterId) {
  return { kind: 'video', url: 'https://example.com/' + id + '/' + chapterId + '.mp4' };
}
''';

/// 桥接能力：宿主 HTTP + 沙盒文件 IO（读回自己写下的内容）。
const String _bridgeCapabilityScript = '''
// LumeSource: {"id":"demo-bridge","name":"桥接能力源","version":"1.0.0"}
async function getList(page) {
  var reply = await LumeSource.http.get('https://api.example.com/list');
  await LumeSource.fs.writeText('/cache/list.json', reply.body);
  var cached = await LumeSource.fs.readText('cache/list.json');
  var exists = await LumeSource.fs.exists('/cache/list.json');
  var keys = await LumeSource.fs.list();
  if (!exists || keys.length !== 1 || keys[0] !== 'cache/list.json') {
    throw new Error('沙盒存储异常: ' + JSON.stringify(keys));
  }
  return { list: [{ id: cached, title: keys[0] }], hasMore: false };
}
''';

/// 对象式脚本（契约 v2）：自己声明 LumeSource，宿主能力不能被它盖掉。
const String _objectStyleScript = '''
// LumeSource: {"id":"obj-source","name":"对象式源","version":"2.0.0"}
var LumeSource = {
  id: 'obj-source',
  name: '对象式源',
  version: '2.0.0',
  async list(argument) {
    globalThis.__seenArgument = argument;
    return { items: [{ id: 'o1', title: '对象式条目' }], hasMore: false };
  }
};
''';

/// 词法声明写法：全局词法绑定优先于全局对象属性。
const String _lexicalScript = '''
// LumeSource: {"id":"lex","name":"词法源","version":"1.0.0"}
const LumeSource = {
  id: 'lex',
  name: '词法源',
  async list(argument) {
    return { items: [{ id: 'l1', title: '词法条目' }] };
  }
};
''';

/// 反复赋值：非对象忽略、对象照常合并，宿主能力不被冲掉。
const String _reassignScript = '''
// LumeSource: {"id":"again","name":"二次赋值源","version":"1.0.0"}
LumeSource = function () {};
LumeSource = {
  id: 'again',
  name: '二次赋值源',
  async list(argument) {
    return { items: [{ id: 'r1', title: '二次赋值条目' }] };
  }
};
''';

/// 启动顺序：脚本顶层代码执行时，桥接与环境垫片必须都已就位。
const String _bootOrderScript = '''
// LumeSource: {"id":"demo-boot","name":"顺序源","version":"1.0.0"}
globalThis.__boot = [
  typeof LumeSource,
  typeof LumeSource.http.get,
  typeof LumeSource.fs.writeText,
  typeof console.log,
  typeof setTimeout,
  typeof LumeBridge
].join('|');

async function getList(page) { return { list: [] }; }
''';

/// 猫源：Node 环境垫片（process / Buffer / require）与桥接对象共存。
const String _catEnvironmentScript = '''
// LumeSource: {"id":"demo-cat","name":"猫源环境源","version":"1.0.0"}
globalThis.__catEnv = [
  typeof process,
  typeof Buffer,
  typeof require,
  typeof LumeSource.fs.readText
].join('|');

function getList(page) { return { list: [] }; }
''';

/// 只有元信息、没有任何实现：报错必须点名「该实现哪个函数」。
const String _metadataOnlyScript = '''
// LumeSource: {"id":"demo-empty","name":"空实现源","version":"1.0.0"}
var LumeSource = { id: 'demo-empty', name: '空实现源' };
''';

/// 记录请求的假网络层（桥接的 http.* 最终打到它上面）。
class _RecordingHttp extends LumeHttp {
  _RecordingHttp() : super();

  final List<String> urls = <String>[];

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    urls.add(url);
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode('列表缓存')),
      headers: const <String, String>{'content-type': 'text/plain'},
    );
  }
}

/// 测试专用：把底层沙箱适配成数据源运行时端口（与 `js_source_native_test` 同口径）。
class _SandboxRuntime implements JsSourceRuntime {

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'list', 'detail', 'chapters', 'content'};
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
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
