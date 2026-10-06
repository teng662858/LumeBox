import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

import 'support/js_sandbox_support.dart';

/// 安全测试第 2 条：多图源上下文隔离。
///
/// 两份独立的测试脚本各自设置全局变量与沙盒文件，要求：
/// - 每一个图源拥有独立 JSContext；
/// - 脚本之间全局变量互相不可见，完全不会交叉污染。
///
/// 隔离有三层，逐层验证：
/// 1. **上下文层**：不同图源各自一个 JSRuntime + JSContext；
/// 2. **全局层**：`globalThis` 上的标记互不可见（含同名不同值）；
/// 3. **沙盒存储层**：`LumeSource.fs` 各有一份，同名路径互不覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  late Directory root;

  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('lume_box_iso');
    await installTempSectionRoot(root);
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('2) 多图源上下文隔离', () {
    test(
      '2a 两份脚本的全局变量互不可见（含同名不同值）',
      () async {
        final alpha = await openEngine(
          sourceId: 'iso-alpha',
          script: fixture('isolation_alpha.js'),
        );
        final beta = await openEngine(
          sourceId: 'iso-beta',
          script: fixture('isolation_beta.js'),
        );
        addTearDown(alpha.dispose);
        addTearDown(beta.dispose);

        final alphaProbe =
            (await alpha.callResult('probe')).value! as Map;
        final betaProbe = (await beta.callResult('probe')).value! as Map;

        // 各自看得见自己的标记。
        expect(alphaProbe['self'], 'alpha-value');
        expect(betaProbe['self'], 'beta-value');

        // 看不见对方的全局变量——这是隔离的核心断言。
        expect(
          alphaProbe['foreignBeta'],
          'undefined',
          reason: '甲的上下文里不该存在乙的全局标记',
        );
        expect(
          betaProbe['foreignAlpha'],
          'undefined',
          reason: '乙的上下文里不该存在甲的全局标记',
        );

        // 同名对象字段也各是各的（不是「恰好名字不同」才不冲突）。
        expect(alphaProbe['selfOwnField'], 'alpha');
        expect(betaProbe['selfOwnField'], 'beta');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '2b 沙盒文件 IO 按图源隔离：同名路径互不覆盖',
      () async {
        final alpha = await openEngine(
          sourceId: 'iso-store-alpha',
          script: fixture('isolation_alpha.js'),
        );
        final beta = await openEngine(
          sourceId: 'iso-store-beta',
          script: fixture('isolation_beta.js'),
        );
        addTearDown(alpha.dispose);
        addTearDown(beta.dispose);

        final alphaProbe = (await alpha.callResult('probe')).value! as Map;
        final betaProbe = (await beta.callResult('probe')).value! as Map;

        // 两个源都写了 `probe/owner.txt`：各自读回自己的值。
        expect(alphaProbe['storeOwner'], 'alpha');
        expect(betaProbe['storeOwner'], 'beta');

        // 文件清单也各是各的：看得见自己写的私有文件，看不见对方那份。
        final alphaKeys = (alphaProbe['storeKeys']! as List).cast<String>();
        final betaKeys = (betaProbe['storeKeys']! as List).cast<String>();
        expect(alphaKeys, contains('probe/alpha-only.txt'));
        expect(alphaKeys, isNot(contains('probe/beta-only.txt')));
        expect(betaKeys, contains('probe/beta-only.txt'));
        expect(betaKeys, isNot(contains('probe/alpha-only.txt')));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '2c 释放一个源不影响另一个源的运行态',
      () async {
        final alpha = await openEngine(
          sourceId: 'iso-release-alpha',
          script: fixture('isolation_alpha.js'),
        );
        final beta = await openEngine(
          sourceId: 'iso-release-beta',
          script: fixture('isolation_beta.js'),
        );
        addTearDown(beta.dispose);

        await alpha.callResult('probe');
        await beta.callResult('probe');

        // 甲的引擎整个释放掉。
        alpha.dispose();

        // 乙的上下文与状态不受影响。
        final betaProbe = (await beta.callResult('probe')).value! as Map;
        expect(betaProbe['self'], 'beta-value');
        expect(betaProbe['storeOwner'], 'beta');

        // 释放后的甲不再接受调用（拿到 disposed 而不是崩溃）。
        final afterDispose = await alpha.callResult('probe');
        expect(afterDispose.isOk, isFalse);
        expect(afterDispose.error!.kind, SandboxErrorKind.disposed);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '2d 板块级注册表：两个板块的图源记录与引擎互不串线',
      () async {
        // 同一份「无板块声明」的脚本，分别导入两个板块，各落各的库。
        const script = '''
// LumeSource: {"id":"iso-board","name":"板块隔离源","version":"1.0.0"}
var LumeSource = {
  id: 'iso-board',
  name: '板块隔离源',
  version: '1.0.0',
  async categories() { return [{ id: 'c1', title: '分类一' }]; },
  async list(argument) { return { items: [{ id: 'x', title: '条目' }] }; },
  async detail(argument) { return { id: 'x', title: '详情' }; },
  async chapters(argument) { return [{ id: 'ch', title: '章' }]; },
  async content(argument) { return { kind: 'text', text: '正文' }; }
};
''';
        final novel = await openRegistryFor(Section.novel);
        final video = await openRegistryFor(Section.video);

        final novelOutcome = await novel.import(script);
        final videoOutcome = await video.import(script);
        expect(novelOutcome.isSuccess, isTrue, reason: novelOutcome.message ?? '');
        expect(videoOutcome.isSuccess, isTrue, reason: videoOutcome.message ?? '');

        // 两个板块各自持有一份记录与一个独立引擎。
        expect(novel.source('iso-board'), isNotNull);
        expect(video.source('iso-board'), isNotNull);
        final novelEngine = await novel.engineFor('iso-board');
        final videoEngine = await video.engineFor('iso-board');
        expect(novelEngine, isNotNull);
        expect(videoEngine, isNotNull);
        expect(
          identical(novelEngine, videoEngine),
          isFalse,
          reason: '两个板块的同一 id 源必须是各自独立的引擎实例',
        );

        // 释放一个板块不影响另一个。
        novel.release('iso-board');
        final afterRelease = await videoEngine!.callResult('detail', <String, Object?>{'id': 'x'});
        expect(afterRelease.isOk, isTrue);
        expect((afterRelease.value! as Map)['title'], '详情');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}

/// 打开一个板块的图源注册表（板块目录与库落到 setUp 建的临时目录）。
Future<SourceRegistry> openRegistryFor(Section section) async {
  await ensureSectionScope(section);
  return SourceRegistry.open(section);
}
