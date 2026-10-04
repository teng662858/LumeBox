import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 板块库与注册表的归属校验。
///
/// 全部在 Windows 上可跑：sqlite3 走原生库，path_provider 用方法通道打桩，
/// 因此「归属板块标记必须保存」与「禁止跨板块加载脚本」是对着真实数据库断言的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_sections');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    SectionDatabase.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SectionDatabase> openDatabase(Section section) async =>
      SectionDatabase.open(await SectionScope.open(section));

  group('板块库：归属标记', () {
    test('标记随图源落库，读取时回得到', () async {
      final database = await openDatabase(Section.novel);
      database.upsertSource(
        id: 'demo',
        name: '示例源',
        version: '1.0.0',
        section: Section.novel.id,
        script: 'var LumeSource = {};',
      );

      expect(database.source('demo')!.section, Section.novel.id);
      expect(database.sources().single.section, Section.novel.id);
    });

    test('跨板块写入被拒绝，库里不留痕迹', () async {
      final database = await openDatabase(Section.novel);
      expect(
        () => database.upsertSource(
          id: 'demo',
          name: '示例源',
          version: '',
          section: Section.comic.id,
          script: 'var LumeSource = {};',
        ),
        throwsArgumentError,
      );
      expect(database.sources(), isEmpty);
    });

    test('旧库（schema v1）迁移：按所在板块回填标记并升级版本号', () async {
      final scope = await SectionScope.open(Section.comic);
      // 手工构造 v1 库：source 表没有 section 列，也没有自证标记。
      final legacy = sqlite3.open(scope.dbPath);
      legacy.execute('''
CREATE TABLE source (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  version    TEXT NOT NULL DEFAULT '',
  script     TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL
);
CREATE TABLE section_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
      legacy.execute(
        'INSERT INTO source (id, name, version, script, enabled, updated_at) '
        'VALUES (?, ?, ?, ?, 1, ?)',
        ['old', '老图源', '0.9.0', 'var LumeSource = {};', 1],
      );
      legacy.execute('PRAGMA user_version = 1');
      legacy.close();

      final database = await SectionDatabase.open(scope);
      final record = database.source('old')!;
      expect(record.section, Section.comic.id, reason: '归属＝原始所在的板块');
      expect(record.name, '老图源');
      expect(record.enabled, isTrue);
      expect(database.setting('owner_section'), Section.comic.id);
    });

    test('库文件被挪到别的板块目录：归属不符即拒绝打开', () async {
      final novel = await openDatabase(Section.novel);
      novel.upsertSource(
        id: 'demo',
        name: '示例源',
        version: '',
        section: Section.novel.id,
        script: 'var LumeSource = {};',
      );
      novel.dispose();

      final novelScope = await SectionScope.open(Section.novel);
      final comicScope = await SectionScope.open(Section.comic);
      File(novelScope.dbPath).copySync(comicScope.dbPath);

      await expectLater(
        SectionDatabase.open(comicScope),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('注册表：禁止跨板块访问', () {
    /// 模拟库文件被外部改动：把一条记录的归属标记改成别的板块。
    void forgeSection(SectionScope scope, String id, String section) {
      final raw = sqlite3.open(scope.dbPath);
      raw.execute('UPDATE source SET section = ? WHERE id = ?', [section, id]);
      raw.close();
    }

    test('本板块记录：列出、启停、删除都正常', () async {
      final scope = await SectionScope.open(Section.cat);
      final database = await SectionDatabase.open(scope);
      database.upsertSource(
        id: 'demo',
        name: '示例源',
        version: '1.0.0',
        section: Section.cat.id,
        script: 'var LumeSource = {};',
      );

      final registry = await SourceRegistry.open(Section.cat);
      expect(registry.sources.single.id, 'demo');

      registry.setEnabled('demo', false);
      expect(registry.sources.single.enabled, isFalse);

      registry.remove('demo');
      expect(registry.sources, isEmpty);
      SourceRegistry.close(Section.cat);
    });

    test('错配记录：不被列出、不可加载、不可启停与删除', () async {
      final scope = await SectionScope.open(Section.novel);
      final database = await SectionDatabase.open(scope);
      for (final id in <String>['demo', 'alien']) {
        database.upsertSource(
          id: id,
          name: id == 'demo' ? '示例源' : '外来图源',
          version: '',
          section: Section.novel.id,
          script: 'var LumeSource = {};',
        );
      }
      forgeSection(scope, 'alien', Section.comic.id);

      final registry = await SourceRegistry.open(Section.novel);
      expect(registry.sources.map((record) => record.id), <String>['demo']);
      expect(await registry.engineFor('alien'), isNull);

      registry.setEnabled('alien', false);
      registry.remove('alien');

      final check = sqlite3.open(scope.dbPath);
      final rows = check.select('SELECT * FROM source WHERE id = ?', ['alien']);
      expect(rows.length, 1, reason: '外来记录不应被删除');
      expect(rows.single['enabled'], 1, reason: '外来记录不应被停用');
      check.close();
      SourceRegistry.close(Section.novel);
    });
  });

  group('注册表：当前图源', () {
    /// 往板块库里塞两条启用图源：名称排序为「A源」在「B源」之前。
    Future<SourceRegistry> seed(Section section) async {
      final scope = await SectionScope.open(section);
      final database = await SectionDatabase.open(scope);
      for (final (id, name) in <(String, String)>[
        ('a', 'A源'),
        ('b', 'B源'),
      ]) {
        database.upsertSource(
          id: id,
          name: name,
          version: '1.0.0',
          section: section.id,
          script: 'var LumeSource = {};',
        );
      }
      return SourceRegistry.open(section);
    }

    test('未显式选择时回退到排序后的第一个启用图源', () async {
      final registry = await seed(Section.novel);
      expect(registry.currentSource()!.id, 'a');
      SourceRegistry.close(Section.novel);
    });

    test('选择落库，重开板块后仍然生效', () async {
      final registry = await seed(Section.novel);
      expect(registry.selectSource('b')!.id, 'b');
      expect(registry.currentSource()!.id, 'b');

      // 模拟重启：关掉板块再打开，选择应还在。
      SourceRegistry.close(Section.novel);
      final reopened = await SourceRegistry.open(Section.novel);
      expect(reopened.currentSource()!.id, 'b');
      SourceRegistry.close(Section.novel);
    });

    test('不存在的图源不能被选中，且不改变现状', () async {
      final registry = await seed(Section.novel);
      expect(registry.selectSource('missing'), isNull);
      expect(registry.currentSource()!.id, 'a', reason: '失败不应写入脏值');
      SourceRegistry.close(Section.novel);
    });

    test('跨板块的图源不能被选为当前', () async {
      final novel = await seed(Section.novel);
      final comic = await seed(Section.comic);
      final comicDatabase = await SectionDatabase.open(
        await SectionScope.open(Section.comic),
      );
      comicDatabase.upsertSource(
        id: 'comic-only',
        name: 'C源',
        version: '',
        section: Section.comic.id,
        script: 'var LumeSource = {};',
      );

      expect(novel.currentSource()!.id, 'a');
      expect(
        novel.selectSource('comic-only'),
        isNull,
        reason: '漫画板块的记录不能成为小说板块的当前图源',
      );
      expect(comic.selectSource('comic-only')!.id, 'comic-only');

      SourceRegistry.close(Section.novel);
      SourceRegistry.close(Section.comic);
    });

    test('已停用的图源不能被选为当前', () async {
      final registry = await seed(Section.novel);
      registry.setEnabled('b', false);
      expect(registry.selectSource('b'), isNull);
      expect(registry.currentSource()!.id, 'a');
      SourceRegistry.close(Section.novel);
    });

    test('当前图源被停用或删除后自动回退，无可用图源则为空', () async {
      final registry = await seed(Section.novel);
      registry.selectSource('b');

      registry.setEnabled('b', false);
      expect(registry.currentSource()!.id, 'a', reason: '停用后回退到下一个启用图源');

      registry.selectSource('a');
      registry.remove('a');
      expect(registry.currentSource(), isNull, reason: '没有启用图源时为 null');

      registry.setEnabled('b', true);
      expect(registry.currentSource()!.id, 'b', reason: '重新启用后重新可用');
      SourceRegistry.close(Section.novel);
    });
  });
}
