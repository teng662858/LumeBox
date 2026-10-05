import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';

/// 图源批量备份 / 恢复（文档第 4 条最后一项）。
///
/// 验证：导出只含脚本与配置（不含 Cookie）、格式标记与版本、恢复按板块写回、
/// 同 id 覆盖、坏条目跳过不中断、板块隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 恢复走的是与导入相同的校验路径（真实引擎），因此本组用例需要原生桥可用。
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  late Directory root;

  setUp(() async {
    // 猫源在 Android 上就有引擎，配合引擎覆盖，这套用例在非 iOS 平台也能跑真实沙箱。
    CatEngines.debugPlatformOverride = 'android';
    LumeJsEngine.debugSupportedOverride = true;
    root = Directory.systemTemp.createTempSync('lume_box_backup');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    CatEngines.debugPlatformOverride = null;
    LumeJsEngine.debugSupportedOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 只有视频与小说板块「有运行时」，其余跳过（模拟平台边界）。
  SourceBackupService service() => SourceBackupService(
        runtimeAvailableFor: (section) =>
            section == Section.video || section == Section.novel,
      );

  Future<SourceRegistry> seed(Section section, String id, String title) async {
    await SectionScope.open(section);
    final registry = await SourceRegistry.open(section);
    await registry.import('''
// LumeSource: {"id":"$id","name":"$title","version":"1.0.0"}
async function getList(page) { return { list: [{ id: 'a', title: '$title' }] }; }
''');
    return registry;
  }

  group('导出备份', () {
    test('只含脚本与配置：Cookie 绝不进备份', () async {
      final registry = await seed(Section.video, 'v1', '视频源');
      registry.setSourceNetwork(
        'v1',
        userAgent: 'UA-1',
        cookie: 'session=secret-token',
        proxy: 'http://127.0.0.1:7890',
      );

      final backup = await service().export();
      final text = backup.encode();

      expect(text, contains('UA-1'), reason: 'UA 属于用户配置，随备份走');
      expect(text, contains('http://127.0.0.1:7890'));
      expect(
        text,
        isNot(contains('secret-token')),
        reason: 'Cookie 是登录凭据，导出文件可能被分享，绝不能写进去',
      );
      expect(text, contains('"format": "lume.sources"'));
    });

    test('板块归属正确：四个板块各归各的', () async {
      await seed(Section.video, 'v1', '视频源');
      await seed(Section.novel, 'n1', '小说源');

      final backup = await service().export();
      expect(backup.sections[Section.video.id]!.single.id, 'v1');
      expect(backup.sections[Section.novel.id]!.single.id, 'n1');
      // 没有运行时的板块留空，而不是把别的板块塞进去。
      expect(backup.sections[Section.comic.id], isEmpty);
      expect(backup.totalCount, 2);
    });

    test('启停状态与订阅来源都带上', () async {
      final registry = await seed(Section.video, 'v2', '订阅源');
      // 订阅来源通过 import 的 originUrl 记录（与导入链路同一路径）。
      await registry.import(
        '''
// LumeSource: {"id":"v2","name":"订阅源","version":"1.0.0"}
async function getList(page) { return { list: [] }; }
''',
        originUrl: 'https://example.com/sub.js',
      );
      registry.setEnabled('v2', false);

      final backup = await service().export();
      final entry = backup.sections[Section.video.id]!.single;
      expect(entry.enabled, isFalse);
      expect(entry.originUrl, 'https://example.com/sub.js');
    });
  }, skip: skipReason);

  group('备份格式', () {
    test('往返：编码后解码得到同样的条目', () async {
      await seed(Section.video, 'v1', '视频源');
      final backup = await service().export();

      final restored = SourceBackup.decode(backup.encode());
      expect(restored.version, SourceBackup.currentVersion);
      expect(restored.totalCount, backup.totalCount);
      final entry = restored.sections[Section.video.id]!.single;
      expect(entry.id, 'v1');
      expect(entry.script, contains('getList'));
    });

    test('拒绝不是备份的文本（带可读原因）', () {
      expect(
        () => SourceBackup.decode('{"foo": 1}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('不是 Lume Box 图源备份'),
          ),
        ),
      );
      expect(
        () => SourceBackup.decode('不是 JSON'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SourceBackup.decode('{"format":"lume.sources","version":999}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('版本不支持'),
          ),
        ),
      );
    });

    test('坏条目跳过，其余照常解析', () {
      final text = jsonEncode(<String, Object?>{
        'format': 'lume.sources',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'sections': <String, Object?>{
          'video': <Object?>[
            <String, Object?>{'id': 'ok', 'name': '好条目', 'script': 'x'},
            <String, Object?>{'id': 'no-script'}, // 缺脚本：跳过
            'not-a-map', // 根本不是对象：跳过
          ],
        },
      });
      final backup = SourceBackup.decode(text);
      expect(backup.sections['video']!.length, 1);
      expect(backup.sections['video']!.single.id, 'ok');
    });
  }, skip: skipReason);

  group('恢复备份', () {
    test('新导入与覆盖分别计数', () async {
      // 空库恢复：算「新增」。
      final backup = SourceBackup(
        version: SourceBackup.currentVersion,
        createdAt: DateTime.now(),
        sections: <String, List<SourceBackupEntry>>{
          Section.video.id: <SourceBackupEntry>[
            const SourceBackupEntry(
              id: 'fresh-1',
              name: '新源',
              version: '1.0.0',
              script: '// LumeSource: {"id":"fresh-1","name":"新源"}\n'
                  'async function getList(page) { return { list: [] }; }',
              enabled: true,
            ),
          ],
        },
      );
      final fresh = service();
      var result = await fresh.restore(backup);
      expect(result.imported, 1, reason: '库里原本没有它，应算新增');
      expect(result.updated, 0);
      expect(result.failed, 0);

      // 再恢复一次：同 id 已存在，应算「覆盖」。
      result = await fresh.restore(backup);
      expect(result.imported, 0);
      expect(result.updated, 1, reason: '同 id 已存在，应算覆盖');
    });

    test('恢复写回启停状态与网络配置（Cookie 本就为空）', () async {
      final registry = await seed(Section.video, 'v1', '视频源');
      registry.setSourceNetwork(
        'v1',
        userAgent: 'UA-X',
        cookie: 'c',
        proxy: 'http://p:1',
      );
      registry.setEnabled('v1', false);
      final backup = await service().export();

      SourceRegistry.close(Section.video);
      await SectionScope.closeAll();
      await service().restore(backup);

      await SectionScope.open(Section.video);
      final reopened = await SourceRegistry.open(Section.video);
      final record = reopened.source('v1')!;
      expect(record.enabled, isFalse, reason: '启停状态要还原');
      expect(record.network.userAgent, 'UA-X');
      expect(record.network.proxy, 'http://p:1');
      expect(record.network.cookie, isEmpty, reason: 'Cookie 本就不进备份');
    });

    test('板块归属非法或平台无运行时的条目跳过，不写错板块', () async {
      final text = jsonEncode(<String, Object?>{
        'format': 'lume.sources',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'sections': <String, Object?>{
          'video': <Object?>[
            <String, Object?>{
              'id': 'v1',
              'name': '视频源',
              // 恢复走真实导入校验：脚本必须有可识别的 LumeSource 元信息。
              'script': '// LumeSource: {"id":"v1","name":"视频源"}\n'
                  'async function getList(page) { return { list: [] }; }',
            },
          ],
          'not-a-section': <Object?>[
            <String, Object?>{'id': 'x', 'name': 'X', 'script': 'var b=1;'},
          ],
          'comic': <Object?>[
            // comic 在本测试的服务里「没有运行时」：应跳过而不是硬写。
            <String, Object?>{'id': 'c1', 'name': '漫画源', 'script': 'var c=1;'},
          ],
        },
      });

      final result = await service().restore(SourceBackup.decode(text));
      expect(result.skipped, 2, reason: '非法板块 + 无运行时板块都跳过');
      expect(
        result.imported,
        1,
        reason: 'imported=${result.imported} failed=${result.failed} '
            '（video 那条应成功）',
      );

      // 漫画板块的库没被写过。
      await SectionScope.open(Section.comic);
      final comic = await SourceRegistry.open(Section.comic);
      expect(comic.sources, isEmpty);
    });

    test('空备份：恢复是空操作', () async {
      final backup = SourceBackup(
        version: SourceBackup.currentVersion,
        createdAt: DateTime.now(),
        sections: const <String, List<SourceBackupEntry>>{},
      );
      final result = await service().restore(backup);
      expect(result.total, 0);
      expect(result.describe(), contains('恢复完成'));
    });
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
