import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/util/lume_log.dart';

/// 图源分组与失效标记的**存储层**验证（文档「图源导入/导出模块规范」）。
///
/// 界面层的行为在 `source_manager_test.dart` 里验；这里验的是底下的不变式：
/// 分组落库可读回、失败计数按阈值触发失效、恢复清零、跨板块改不动，
/// 以及**旧库（schema v4）能平滑升到 v5**（加列不丢数据）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_group');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    LumeLog.clear();
  });

  tearDown(() async {
    // 顺序要紧：先关注册表（它持有库句柄），再关库与作用域。
    // 只关库不清注册表，下一个用例会从注册表拿到「已被释放的库」。
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    SectionDatabase.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SectionDatabase> openDatabase(Section section) async =>
      SectionDatabase.open(await SectionScope.open(section));

  Future<SourceRegistry> seed(Section section, {List<String> ids = const <String>['a']}) async {
    final scope = await SectionScope.open(section);
    final database = await SectionDatabase.open(scope);
    for (final id in ids) {
      database.upsertSource(
        id: id,
        name: '源$id',
        version: '1.0.0',
        section: section.id,
        script: 'var LumeSource = {};',
      );
    }
    return SourceRegistry.open(section);
  }

  group('分组：落库与隔离', () {
    test('设置分组后读回，取消分组也生效', () async {
      final database = await openDatabase(Section.novel);
      database.upsertSource(
        id: 'a',
        name: '示例源',
        version: '1.0.0',
        section: Section.novel.id,
        script: 'var LumeSource = {};',
      );

      expect(database.source('a')!.group, isEmpty);
      database.setSourceGroup('a', '  主力  ');
      expect(database.source('a')!.group, '主力', reason: '分组名两侧空白要去掉');
      expect(database.source('a')!.group, '主力');

      database.setSourceGroup('a', '');
      expect(database.source('a')!.group, isEmpty);
      expect(database.source('a')!.group, isEmpty);
    });

    test('分组不跨板块：小说板块设的分组，漫画板块看不到也改不到', () async {
      final novel = await seed(Section.novel);
      novel.setGroup('a', '主力');
      expect(novel.source('a')!.group, '主力');

      final comic = await seed(Section.comic, ids: <String>['a']);
      expect(
        comic.source('a')!.group,
        isEmpty,
        reason: '同名 id 在不同板块是两条独立记录，分组不该串线',
      );
      // 跨板块改分组：无操作（_owns 拦下）。
      comic.setGroup('novel-only-id', '主力');
      expect(novel.source('a')!.group, '主力');
    });

    test('分组不改变归属板块：源仍在原板块、脚本与启停状态不动', () async {
      final novel = await seed(Section.novel);
      novel.setEnabled('a', false);
      final before = novel.source('a')!;

      novel.setGroup('a', '主力');
      final after = novel.source('a')!;
      expect(after.section, Section.novel.id);
      expect(after.script, before.script);
      expect(after.enabled, isFalse, reason: '分组是展示归类，不该动启停');
      expect(after.version, before.version);
    });
  });

  group('失效标记：阈值、恢复与不再重试', () {
    test('失败计数累加，达到阈值（3 次）才标记失效', () async {
      final registry = await seed(Section.novel);

      registry.recordFailure('a');
      expect(registry.source('a')!.failureCount, 1);
      expect(registry.source('a')!.isBroken, isFalse, reason: '一次失败可能是网络抖动');

      registry.recordFailure('a');
      expect(registry.source('a')!.failureCount, 2);
      expect(registry.source('a')!.isBroken, isFalse);

      registry.recordFailure('a');
      expect(registry.source('a')!.failureCount, 3);
      expect(registry.source('a')!.isBroken, isTrue, reason: '连错 3 次判定失效');
      expect(registry.source('a')!.brokenAt, greaterThan(0));
    });

    test('已失效后继续失败：计数继续加，但失效时间不反复刷新', () async {
      final registry = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        registry.recordFailure('a');
      }
      final brokenAt = registry.source('a')!.brokenAt;

      registry.recordFailure('a');
      expect(registry.source('a')!.failureCount, 4);
      expect(
        registry.source('a')!.brokenAt,
        brokenAt,
        reason: '失效时间记的是「首次判定失效」的时刻，不该每次失败都刷',
      );
    });

    test('恢复：清零计数并解除标记，可重新参与自动流程', () async {
      final registry = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        registry.recordFailure('a');
      }
      expect(registry.source('a')!.isBroken, isTrue);

      registry.clearFailure('a');
      final recovered = registry.source('a')!;
      expect(recovered.failureCount, 0);
      expect(recovered.isBroken, isFalse);
      expect(recovered.brokenAt, 0);
    });

    test('失效标记在重开板块后仍在（落库，不是内存态）', () async {
      final registry = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        registry.recordFailure('a');
      }
      SourceRegistry.close(Section.novel);

      final reopened = await SourceRegistry.open(Section.novel);
      expect(reopened.source('a')!.isBroken, isTrue);
      expect(reopened.source('a')!.failureCount, 3);
    });

    test('跨板块改不动失效状态', () async {
      final novel = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        novel.recordFailure('a');
      }
      expect(novel.source('a')!.isBroken, isTrue);

      final comic = await seed(Section.comic, ids: <String>['a']);
      // 漫画板块对同名 id 调恢复：无操作（它自己的记录本来就没失效）。
      comic.clearFailure('a');
      expect(
        novel.source('a')!.isBroken,
        isTrue,
        reason: '漫画板块的操作不该影响小说板块的记录',
      );
      expect(comic.source('a')!.isBroken, isFalse);
    });

    test('失效的源不再参与自动重试（连通性测试直接拒绝并说明）', () async {
      // 这条走的是 LumeSources.testConnectivity 的入口判定；这里只验存储层的
      // 前提条件成立（isBroken 可读），入口行为由 source_connectivity_test 覆盖。
      final registry = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        registry.recordFailure('a');
      }
      expect(registry.source('a')!.isBroken, isTrue);
      // 失效不影响手动浏览能力（用户可能想亲眼看看）——只是不自动重试。
      expect(registry.source('a')!.enabled, isTrue);
    });

    test('失效在日志里留痕（真机排障要看）', () async {
      final registry = await seed(Section.novel);
      for (var i = 0; i < 3; i++) {
        registry.recordFailure('a');
      }
      final lines = LumeLog.snapshot
          .map((entry) => entry.message)
          .where((line) => line.contains('已标记为失效'))
          .toList(growable: false);
      expect(lines, isNotEmpty, reason: '判定失效必须可审计');
      expect(lines.first, contains('不再自动重试'));
    });
  });

  group('schema 迁移：v4 旧库平滑升到 v5', () {
    test('旧库（无分组/失败列）升级后数据保留、新列可用', () async {
      final scope = await SectionScope.open(Section.video);
      // 手工造一个 v4 库：有 section / UA / Cookie / 代理 / origin_url，
      // 但没有 source_group / failure_count / broken_at。
      final legacy = sqlite3.open(scope.dbPath);
      legacy.execute('''
CREATE TABLE source (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  version    TEXT NOT NULL DEFAULT '',
  section    TEXT NOT NULL DEFAULT '',
  script     TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  user_agent TEXT NOT NULL DEFAULT '',
  cookie     TEXT NOT NULL DEFAULT '',
  proxy      TEXT NOT NULL DEFAULT '',
  origin_url TEXT NOT NULL DEFAULT ''
);
CREATE TABLE section_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
      legacy.execute(
        'INSERT INTO source (id, name, version, section, script, enabled, '
        'updated_at, origin_url) VALUES (?, ?, ?, ?, ?, 1, ?, ?)',
        ['old', '老源', '0.9.0', Section.video.id, 'var LumeSource = {};',
            DateTime.now().millisecondsSinceEpoch, 'https://example.com/x.js'],
      );
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();

      final database = await SectionDatabase.open(scope);
      final record = database.source('old')!;
      // 旧数据全在。
      expect(record.name, '老源');
      expect(record.version, '0.9.0');
      expect(record.originUrl, 'https://example.com/x.js');
      expect(record.section, Section.video.id);
      // 新列有默认值。
      expect(record.group, isEmpty);
      expect(record.failureCount, 0);
      expect(record.isBroken, isFalse);
      // 新列可写。
      database.setSourceGroup('old', '备用');
      database.recordSourceFailure('old', threshold: 3);
      expect(database.source('old')!.group, '备用');
      expect(database.source('old')!.failureCount, 1);
    });

    test('v4 旧库升级不产生迁移告警（列是新增的，不该撞 duplicate）', () async {
      final scope = await SectionScope.open(Section.cat);
      final legacy = sqlite3.open(scope.dbPath);
      legacy.execute('''
CREATE TABLE source (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  version    TEXT NOT NULL DEFAULT '',
  section    TEXT NOT NULL DEFAULT '',
  script     TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  user_agent TEXT NOT NULL DEFAULT '',
  cookie     TEXT NOT NULL DEFAULT '',
  proxy      TEXT NOT NULL DEFAULT '',
  origin_url TEXT NOT NULL DEFAULT ''
);
CREATE TABLE section_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();

      await SectionDatabase.open(scope);
      final warnings = LumeLog.snapshot
          .map((entry) => entry.message)
          .where((line) => line.contains('迁移'))
          .toList(growable: false);
      expect(warnings, isEmpty, reason: 'v4→v5 是加列，不该有任何跳过告警：$warnings');
    });
  });
}
