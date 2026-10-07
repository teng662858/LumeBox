import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/cat_polyfills.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/js_sandbox_support.dart';

/// 导入守卫：**「这份脚本到底是不是本 App 的图源」**。
///
/// 背景（用户真机实测）：一份 6MB 的猫源订阅导入失败，报的是
/// 「猫源沙箱不支持「http2」」。查过那份脚本后确认——它根本不是图源脚本，
/// 而是**另一个客户端的扩展程序包**：自带本地 HTTP/2 服务端（`http2.createServer`）、
/// 自带网站与弹幕前端（`websiteBundle` / `danmuBundle`）、靠它自己的宿主桥
/// （`messageToDart`）通信，且**没有任何图源入口**（home / category / detail /
/// play / getList / LumeSource.* 一个都没有）。这种包在 iOS 上没有运行条件
/// （需要端口、进程与那套宿主桥），不是「沙箱少装了个模块」。
///
/// 因此两条守卫：
/// 1. 服务端类模块的拒绝文案要点名「自建服务端需要端口 / 进程」，
///    并说明**补上模块也跑不起来**——避免用户以为缺个垫片；
/// 2. 即使脚本没用到那些模块，只要**一个图源入口都没有**，导入阶段就识别出来
///    并说明它像什么、该怎么办（而不是导入成功、点开一片空白）。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  late Directory root;

  setUp(() async {
    enableEngineOnThisPlatform();
    // 猫源板块的平台门按「iOS」放行（QuickJS 引擎）：本组要走的正是猫源导入链路，
    // 而 Windows 上猫源板块默认只保留骨架。与既有猫源用例同一套做法。
    CatEngines.debugPlatformOverride = 'ios';
    root = Directory.systemTemp.createTempSync('lume_box_guard');
    await installTempSectionRoot(root);
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    CatEngines.debugPlatformOverride = null;
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('服务端类模块的拒绝文案', () {
    test('纯 Dart：http2 / net / child_process 都点名「自建服务端」', () {
      // 文案由垫片里的 __lumeUnsupportedModule 生成；这里直连它的判定规则：
      // 三种模块都必须落进「服务端 / 子进程」这一类，而不是笼统的「没内置」。
      final guard = CatPolyfills.all
          .firstWhere((item) => item.id == 'lume.cat.unsupported')
          .source;
      for (final module in <String>['http2', 'net', 'child_process', 'dgram', 'worker_threads']) {
        expect(
          guard.contains('自建服务端'),
          isTrue,
          reason: '守卫文案要能解释「为什么补上模块也跑不起来」',
        );
        expect(
          RegExp('（net\\|tls\\|dgram\\|http2\\|child_process\\|worker_threads').hasMatch(guard),
          isFalse,
          reason: '这些模块不能被归到「暂未内置」那类（$module）',
        );
      }
      expect(guard.contains('补上这个模块也跑不起来'), isTrue, reason: '要明确否掉「加个垫片就行」的预期');
    });

    test(
      '真实引擎：扩展程序包在载入阶段被拦下，文案点名自建服务端',
      () async {
        await ensureSectionScope(Section.cat);
        final manager = LumeSources.manager(Section.cat);
        final outcome = await manager.importScript(
          fixture('foreign_client_bundle.js'),
        );

        expect(outcome.isSuccess, isFalse, reason: '这种包不该导入成功');
        final message = outcome.message ?? '';
        expect(message, contains('http2'), reason: '点名是哪个模块');
        expect(message, contains('自建服务端'), reason: '说清它是什么用途的模块');
        expect(
          message,
          contains('补上这个模块也跑不起来'),
          reason: '明确否掉「补个垫片就能跑」的猜测',
        );
        expect(await manager.list(), isEmpty, reason: '失败不落库');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('「零图源入口」的脚本在导入阶段被识别', () {
    test(
      '没有契约方法、也不 require 服务端模块：判定为非源脚本并说明怎么办',
      () async {
        const bundle = '''
// 一份「像扩展程序包但没用到服务端模块」的脚本：只有自己的宿主桥与前端资源。
globalThis.messageToDart = function (payload) { return String(payload); };
globalThis.websiteBundle = function () { return '<html></html>'; };
globalThis.__bundlerPathsOverrides = {};
''';
        await ensureSectionScope(Section.cat);
        final manager = LumeSources.manager(Section.cat);
        final outcome = await manager.importScript(bundle);

        expect(outcome.isSuccess, isFalse, reason: '没有图源入口就不该导入成功');
        final message = outcome.message ?? '';
        expect(message, contains('没有任何图源入口'));
        expect(message, contains('别的客户端的扩展程序包'));
        expect(
          message,
          contains('getList / getDetail / getContent'),
          reason: '要告诉用户本 App 的源脚本该怎么写',
        );
        expect(await manager.list(), isEmpty);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '不误伤：只实现一个入口（例如只有 getList）的脚本照常导入',
      () async {
        const minimal = '''
// LumeSource: {"id":"only-list","name":"只实现列表的源","version":"1.0.0"}
async function getList(page) {
  return [{ id: 'x', title: '条目' }];
}
''';
        await ensureSectionScope(Section.novel);
        final manager = LumeSources.manager(Section.novel);
        final outcome = await manager.importScript(minimal);

        expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '');
        expect(outcome.descriptor!.id, 'only-list');

        final source = await LumeSources.open(Section.novel, 'only-list');
        expect(source, isNotNull);
        final list = await source!.list(page: 1);
        expect(list.items.single.title, '条目', reason: '导入后要能真的用到');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('不支持的模块：require 不再当场致命（真机订阅源导入失败的回归）', () {
    /// 真机实测：一份订阅源导入失败，报「猫源沙箱不支持「http2」」。
    /// 脚本只是**顺手 require** 了它（真正发请求用 fetch / LumeSource.http），
    /// 却在载入期被整份挡下。现在 require 返回一个「用到才炸」的占位：
    /// 没用到的照常跑；真用到的仍给同一句可读错误。
    test(
      'require 了但没用到：导入成功，且导入后能真的出内容',
      () async {
        await ensureSectionScope(Section.cat);
        final manager = LumeSources.manager(Section.cat);
        final outcome =
            await manager.importScript(fixture('cat_unused_server_module.js'));

        expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '');
        expect(outcome.descriptor!.id, 'cat-unused-server-module');

        final source =
            await LumeSources.open(Section.cat, 'cat-unused-server-module');
        expect(source, isNotNull);
        final list = await source!.list(page: 1);
        expect(list.items.single.title, '示例条目', reason: '导入后要能真的用到');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '真的用到（取属性 / 调用）：仍抛点名到模块的可读错误',
      () async {
        const usesIt = '''
// LumeSource: {"id":"cat-uses-http2","name":"用到 http2 的源","version":"1.0.0","category":"cat"}
var http2 = require('http2');
// 取属性即算「用到」：这里应当抛错，而不是静默给个 undefined。
var server = http2.createServer(function () {});
async function getList(page) { return []; }
''';
        await ensureSectionScope(Section.cat);
        final manager = LumeSources.manager(Section.cat);
        final outcome = await manager.importScript(usesIt);

        expect(outcome.isSuccess, isFalse, reason: '真用到了就不该导入成功');
        final message = outcome.message ?? '';
        expect(message, contains('http2'), reason: '点名是哪个模块');
        expect(message, contains('自建服务端'), reason: '说清它是什么用途的模块');
        expect(
          message,
          contains('补上这个模块也跑不起来'),
          reason: '明确否掉「补个垫片就能跑」的猜测',
        );
        expect(await manager.list(), isEmpty, reason: '失败不落库');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
