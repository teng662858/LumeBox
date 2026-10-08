import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 导入失败的提示口径（用户反馈：只看到一句「脚本载入失败：语法错误、运行异常，
/// 或用到了沙箱不支持的能力」，得翻运行日志才知道真实原因）。
///
/// 这里在**真实引擎**上驱动整条导入链路（含元信息解析与落库），确认：
/// - 沙箱给出的具体原因（点名 dns / 语法错误）原样进到提示里；
/// - 用到 socket / 进程 / 端口这类能力时，再补一句「自建服务端程序不是图源脚本」的定向说明；
/// - 合法脚本照旧导入成功。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言，测试进程同样适用。
    Qjs.reclaimRuntime = false;
  }

  final available = Qjs.isAvailable;
  final skipReason =
      available ? null : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_import_failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 猫源在 Android 上就有引擎（QuickJS 二选一），配合下面的引擎覆盖，
    // 这套用例在非 iOS 的平台也能跑真实沙箱。
    CatEngines.debugPlatformOverride = 'android';
    LumeJsEngine.debugSupportedOverride = true;
    SectionMemoryCache.instance.clearAll();
  });

  tearDown(() async {
    SectionMemoryCache.instance.clearAll();
    SourceRegistry.close(Section.cat);
    SourceRegistry.close(Section.video);
    await SectionScope.closeAll();
    CatEngines.debugPlatformOverride = null;
    LumeJsEngine.debugSupportedOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SourceRegistry> openRegistry(Section section) async {
    await SectionScope.open(section);
    return SourceRegistry.open(section);
  }

  test('猫源脚本真的用到 dns：提示点名 dns，并说明自建服务端程序不是图源脚本', () async {
    final registry = await openRegistry(Section.cat);
    final outcome = await registry.import('''
// LumeSource: {"id":"cat-dns","name":"猫源服务","version":"1.0.0"}
var dns = require('dns');
// 真调用才算「用到了」——require 本身不再抛（见下一条）。
dns.lookup('example.com');
function getList(page) { return { list: [] }; }
''');

    expect(outcome.isSuccess, isFalse);
    final message = outcome.message!;
    expect(message, contains('脚本载入失败：'), reason: '保留「导入失败」的稳定前缀');
    expect(message, contains('dns'), reason: '必须点名是哪个能力不支持');
    expect(
      message,
      contains('Node 程序'),
      reason: '这类脚本要给一句「这是打包过的 Node 程序，App 跑不了它」的定向说明',
    );
    expect(
      message,
      contains('catvod_bridge_source.js'),
      reason: '并给出可行动的出路（薄壳脚本经 LumeSource.http 转发）',
    );
    expect(registry.sources, isEmpty, reason: '失败不落库');
  }, skip: skipReason);

  test('按脚本内容认出「打包过的 Node 程序」：报错文案点名它，并给两条出路', () async {
    // 真机那份 6MB 订阅就是这一类：失败文案只有一句 TypeError: not a function，
    // 但正文里到处是 process.hrtime / require —— 必须在导入阶段按内容定性。
    final registry = await openRegistry(Section.cat);
    final outcome = await registry.import('''
// LumeSource: {"id":"node-bundle","name":"打包程序","version":"1.0.0"}
var t = process.hrtime.bigint();
var fs = require('fs');
function getList(page) { return { list: [] }; }
''');

    expect(outcome.isSuccess, isFalse);
    final message = outcome.message!;
    expect(message, contains('打包过的 Node 程序'), reason: '要点名它是 Node 程序');
    expect(message, contains('getList'), reason: '要给出「换接口型脚本」这条出路');
    expect(message, contains('LumeSource.http'), reason: '并给薄壳转发的写法指引');
    expect(registry.sources, isEmpty, reason: '失败不落库');
  }, skip: skipReason);

  test('按脚本内容认出 Venera 那套源：报错点名 DOM 解析，并给两条出路', () async {
    // 真机那份 venera-configs/merge.json 就是这一类：装完跑起来报
    // 「cannot read property 'querySelectorAll' of null」——脚本靠网页 DOM 解析，
    // 本 App 的沙箱只给 fetch / JSON。
    // 这类脚本**导入能过**（DOM 用法要到运行期才炸），因此定性走运行期那条路：
    // 错误卡在引擎原文后追加一句说明（用户看不懂那句英文 TypeError）。
    final message = SourceRegistry.describeRuntimeFailure(
      "脚本错误: cannot read property 'querySelectorAll' of null",
    );
    expect(message, contains('querySelectorAll'),
        reason: '引擎原文必须保留（排障要看原文）');
    expect(message, contains('DOM 解析'), reason: '要点名它靠网页 DOM 解析');
    expect(message, contains('Venera'), reason: '并点名这是哪一套客户端的写法');
    expect(message, contains('fetch'), reason: '要给出「换接口型脚本」这条出路');
  }, skip: skipReason);

  test('猫源脚本只是顺手 require 了服务端模块、没用到：照常导入（真机订阅源回归）', () async {
    // 真机实测：一份订阅源导入失败，报「猫源沙箱不支持 http2」。脚本只是沿用了
    // 别处的写法、顺手 require 了一堆模块，真正发请求用的是 fetch / LumeSource.http。
    // 载入期抛会把这类脚本整份挡在门外——因此 require 不再当场致命。
    final registry = await openRegistry(Section.cat);
    final outcome = await registry.import('''
// LumeSource: {"id":"cat-dns-unused","name":"猫源（没用到服务端模块）","version":"1.0.0"}
var dns = require('dns');
var http2 = require('http2');
function getList(page) { return { list: [] }; }
''');

    expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '应当照常导入');
    expect(outcome.message, isNull);
    expect(
      registry.sources.map((item) => item.id),
      contains('cat-dns-unused'),
      reason: '成功导入的源要真的落库',
    );
  }, skip: skipReason);

  test('语法错误：提示带上引擎给出的 SyntaxError 原文', () async {
    final registry = await openRegistry(Section.video);
    final outcome = await registry.import('''
// LumeSource: {"id":"broken","name":"有语法错的源","version":"1.0.0"}
async function getList( { return 1 }
''');

    expect(outcome.isSuccess, isFalse);
    expect(outcome.message, contains('SyntaxError'));
    expect(
      outcome.message,
      isNot(contains('自建服务端程序')),
      reason: '语法错误不该带上服务端说明',
    );
  }, skip: skipReason);

  test('连通性测试（真实引擎）：脚本能跑但首屏为空 → 无内容', () async {
    final registry = await openRegistry(Section.video);
    final imported = await registry.import('''
// LumeSource: {"id":"probe-empty","name":"空列表源","version":"1.0.0"}
async function getList(page) {
  return { list: [], hasMore: false };
}
''');
    expect(imported.isSuccess, isTrue, reason: imported.message ?? '');

    final result = await LumeSources.testConnectivity(Section.video, 'probe-empty');
    expect(result.status, SourceTestStatus.empty);
    expect(result.message, contains('没有返回任何条目'));
    expect(result.elapsed, isNotNull);
  }, skip: skipReason);

  test('连通性测试（真实引擎）：有内容 → 可用，且带条目数', () async {
    final registry = await openRegistry(Section.video);
    final imported = await registry.import('''
// LumeSource: {"id":"probe-ok","name":"有内容的源","version":"1.0.0"}
async function getCategories() {
  return [{ id: 'c1', title: '分类一' }];
}
async function getList(page) {
  return { list: [
    { id: 'https://example.com/a.mp4', title: '条目一' },
    { id: 'https://example.com/b.mp4', title: '条目二' }
  ] };
}
''');
    expect(imported.isSuccess, isTrue, reason: imported.message ?? '');

    final result = await LumeSources.testConnectivity(Section.video, 'probe-ok');
    expect(result.status, SourceTestStatus.ok);
    expect(result.itemCount, 2);
    expect(result.categoryCount, 1);
  }, skip: skipReason);

  test('连通性测试（真实引擎）：脚本缺 getList → 不可用并点名缺哪个函数', () async {
    final registry = await openRegistry(Section.video);
    // 注意：脚本要有**至少一个**图源入口才过得去导入守卫（一个都没有的脚本
    // 会在导入阶段被判为非源脚本，见 import_guard_test）。这里只实现 getCategories，
    // 于是导入通过、而「缺 list」由连通性测试点名——正是本用例要覆盖的那条诊断。
    final imported = await registry.import('''
// LumeSource: {"id":"probe-nolist","name":"缺实现的源","version":"1.0.0"}
var LumeSource = { id: 'probe-nolist', name: '缺实现的源' };
async function getCategories() { return [{ id: 'c1', title: '分类一' }]; }
''');
    expect(imported.isSuccess, isTrue, reason: imported.message ?? '');

    final result = await LumeSources.testConnectivity(Section.video, 'probe-nolist');
    expect(result.status, SourceTestStatus.failed);
    expect(result.message, contains('没有实现 list 方法'));
    expect(result.message, contains('getList'));
  }, skip: skipReason);

  test('连通性测试：停用的图源直接给可读提示，不白跑一遍', () async {
    final registry = await openRegistry(Section.video);
    await registry.import('''
// LumeSource: {"id":"probe-off","name":"停用源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'x', title: 'x' }] }; }
''');
    registry.setEnabled('probe-off', false);

    final result = await LumeSources.testConnectivity(Section.video, 'probe-off');
    expect(result.status, SourceTestStatus.failed);
    expect(result.message, contains('已停用'));
  }, skip: skipReason);

  test('订阅更新（真实引擎）：拉到新脚本覆盖，来源地址保留', () async {
    final registry = await openRegistry(Section.video);
    const origin = 'https://example.com/sub.js';
    final imported = await registry.import('''
// LumeSource: {"id":"sub-src","name":"订阅源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'a', title: '旧条目' }] }; }
''', originUrl: origin);
    expect(imported.isSuccess, isTrue, reason: imported.message ?? '');
    expect(registry.source('sub-src')!.originUrl, origin);
    expect(registry.source('sub-src')!.isSubscribed, isTrue);

    // 订阅端给了新脚本：更新后条目变了，来源地址与网络配置不动。
    registry.setSourceNetwork('sub-src', userAgent: 'UA', cookie: 'c', proxy: '');
    final resolver = SourceSubscription(
      fetch: (url) async {
        expect(url, origin);
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode('''
// LumeSource: {"id":"sub-src","name":"订阅源","version":"2.0.0"}
async function getList(page) { return { list: [{ id: 'b', title: '新条目' }] }; }
''')),
          text: '''
// LumeSource: {"id":"sub-src","name":"订阅源","version":"2.0.0"}
async function getList(page) { return { list: [{ id: 'b', title: '新条目' }] }; }
''',
        );
      },
    );

    final result = await LumeSources.updateFromSubscription(
      Section.video,
      'sub-src',
      subscription: resolver,
    );
    expect(result.status, SourceUpdateStatus.updated, reason: result.message);
    expect(result.descriptor!.version, '2.0.0');
    final updated = registry.source('sub-src')!;
    expect(updated.script, contains('新条目'));
    expect(updated.originUrl, origin, reason: '来源地址属于用户配置，更新脚本不该丢');
    expect(updated.network.userAgent, 'UA', reason: '网络覆盖同样不该丢');
  }, skip: skipReason);

  test('清单式订阅：每一份脚本记**自己**的来源地址（不是清单地址）', () async {
    // 新库（用户口径）：小说 / 漫画 / 视频各一个订阅链接，链接正文是「一行一个地址」
    // 的清单。清单里的每一条都必须记自己的地址——旧实现一律记 `urls.first`，
    // 于是「更新订阅源」只能拿到清单第一条，第二个源永远更新不了。
    const listUrl = 'https://example.com/comic/sources.txt';
    const a = 'https://example.com/comic/a.js';
    const b = 'https://example.com/comic/b.js';
    String script(String id, String name) =>
        '// LumeSource: {"id":"$id","name":"$name","version":"1.0.0"}\n'
        'async function getList(page) { return { list: [] }; }';
    final resolver = SourceSubscription(
      fetch: (url) async {
        final text = switch (url) {
          listUrl => '# 漫画源\n$a\n$b\n',
          a => script('src-a', '甲'),
          _ => script('src-b', '乙'),
        };
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );

    final refs = await resolver.resolveRefs(<String>[listUrl]);
    expect(refs.length, 2);
    expect(refs[0].url, a, reason: '第一条的来源地址是它自己那一行');
    expect(refs[1].url, b, reason: '第二条同样记自己那一行');
    expect(refs[1].script, contains('src-b'));
  });

  test('订阅更新：清单里有多个源时按 id 找自己那一份', () async {
    // 用视频板块：本文件的 tearDown 只关猫源 / 视频两个注册表。
    final registry = await openRegistry(Section.video);
    await registry.import('''
// LumeSource: {"id":"mine","name":"我的源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'a', title: '旧' }] }; }
''', originUrl: 'https://example.com/list.txt');

    // 订阅地址是一个清单（正文只有地址）：第一条是别人的源，第二条才是这个源的新版本。
    const listUrl = 'https://example.com/list.txt';
    const otherUrl = 'https://example.com/other.js';
    const mineUrl = 'https://example.com/mine.js';
    const other = '// LumeSource: {"id":"other","name":"别的源","version":"9.0.0"}\n'
        'async function getList(page) { return { list: [] }; }';
    const mine = '// LumeSource: {"id":"mine","name":"我的源","version":"2.0.0"}\n'
        "async function getList(page) { return { list: [{ id: 'a', title: '新' }] }; }";
    final resolver = SourceSubscription(
      fetch: (url) async {
        final text = switch (url) {
          listUrl => '# 清单\n$otherUrl\n$mineUrl\n',
          otherUrl => other,
          _ => mine,
        };
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );

    final result = await LumeSources.updateFromSubscription(
      Section.video,
      'mine',
      subscription: resolver,
    );
    expect(result.status, SourceUpdateStatus.updated, reason: result.message);
    final updated = registry.source('mine')!;
    expect(updated.script, contains('新'), reason: '按 id 命中自己那一份，不是清单第一条');
    expect(updated.script, isNot(contains('别的源')));
  }, skip: skipReason);

  test('订阅更新（真实引擎）：内容一致 → 已是最新', () async {
    final registry = await openRegistry(Section.video);
    const script = '''
// LumeSource: {"id":"sub-same","name":"同源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'a', title: 'A' }] }; }
''';
    await registry.import(script, originUrl: 'https://example.com/same.js');

    final result = await LumeSources.updateFromSubscription(
      Section.video,
      'sub-same',
      subscription: SourceSubscription(
        fetch: (url) async => SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(script)),
          text: script,
        ),
      ),
    );
    expect(result.status, SourceUpdateStatus.unchanged);
  }, skip: skipReason);

  test('订阅更新（真实引擎）：MD5 不符时拒绝，旧脚本保持不变', () async {
    final registry = await openRegistry(Section.video);
    const origin = 'https://example.com/verify.js.md5';
    await registry.import('''
// LumeSource: {"id":"sub-md5","name":"校验源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'old', title: '旧' }] }; }
''', originUrl: origin);

    final result = await LumeSources.updateFromSubscription(
      Section.video,
      'sub-md5',
      subscription: SourceSubscription(
        fetch: (url) async {
          if (url.endsWith('.md5')) {
            // 清单里的 MD5 与实体内容对不上。
            return SourceFetchResult(
              bytes: Uint8List.fromList(utf8.encode('0' * 32)),
              text: '0' * 32,
            );
          }
          return SourceFetchResult(
            bytes: Uint8List.fromList(utf8.encode('// 别的脚本')),
            text: '// 别的脚本',
          );
        },
      ),
    );

    expect(result.status, SourceUpdateStatus.failed);
    expect(result.message, contains('MD5 校验不一致'));
    expect(
      registry.source('sub-md5')!.script,
      contains('旧'),
      reason: '校验不过就不能动旧脚本',
    );
  }, skip: skipReason);

  test('订阅更新：本地导入的图源给「没有订阅地址」的可读提示', () async {
    final registry = await openRegistry(Section.video);
    await registry.import('''
// LumeSource: {"id":"local-src","name":"本地源","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'a', title: 'A' }] }; }
''');

    final result = await LumeSources.updateFromSubscription(
      Section.video,
      'local-src',
      subscription: SourceSubscription(
        fetch: (url) async => fail('不该发请求：$url'),
      ),
    );
    expect(result.status, SourceUpdateStatus.skipped);
    expect(result.message, contains('没有订阅地址'));
  }, skip: skipReason);

  test('没有运行时报错的环境能力：函数式脚本照旧导入成功并落库', () async {
    final registry = await openRegistry(Section.video);
    final outcome = await registry.import('''
// LumeSource: {"id":"demo-video","name":"公开样片测试源","version":"1.0.0"}
async function getList(page) {
  return { list: [{ title: '测试视频', url: 'https://example.com/demo.mp4' }] };
}
''');

    expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '');
    expect(outcome.record!.id, 'demo-video');
    expect(
      registry.sources.map((item) => item.id),
      contains('demo-video'),
    );
  }, skip: skipReason);

  test('读缓存（真实引擎）：生产链路真的写缓存，覆盖导入即作废', () async {
    final registry = await openRegistry(Section.video);
    await registry.import('''
// LumeSource: {"id":"cache-src","name":"缓存源","version":"1.0.0"}
async function getCategories() { return [{ id: 'c1', title: '旧分类' }]; }
async function getList(page) { return { list: [{ id: 'a', title: 'A' }] }; }
''');

    final cache = SectionMemoryCache.instance;
    final source = await LumeSources.open(Section.video, 'cache-src');
    expect((await source!.categories()).single.title, '旧分类');
    expect(
      cache.usageOf(Section.video).entries,
      greaterThan(0),
      reason: '生产链路（LumeSources.open）要把读结果放进本板块的内存缓存',
    );

    // 覆盖导入换了脚本：缓存必须跟着运行时一起作废，否则会读到上一个脚本的输出。
    await registry.import('''
// LumeSource: {"id":"cache-src","name":"缓存源","version":"2.0.0"}
async function getCategories() { return [{ id: 'c1', title: '新分类' }]; }
async function getList(page) { return { list: [] }; }
''');
    final reopened = await LumeSources.open(Section.video, 'cache-src');
    expect((await reopened!.categories()).single.title, '新分类');
  }, skip: skipReason);
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
