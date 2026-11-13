import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_site_config.dart';
import 'package:lume_box/core/source/source_extension_settings.dart';
import 'package:lume_box/core/source/source_settings_policy.dart';

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

  test('concurrent opens share a single live database connection', () async {
    final scope = await SectionScope.open(Section.video);
    final databases = await Future.wait(
      List.generate(8, (_) => SectionDatabase.open(scope)),
    );
    expect(databases.toSet(), hasLength(1));
    SectionDatabase.disposeAll();
    await File(scope.dbPath).delete();
    expect(await File(scope.dbPath).exists(), isFalse);
  });

  test('更新声明与重命名均保留线路选择、自定义地址、账号和扩展参数', () async {
    final db = await openDatabase(Section.video);
    final fields = SourceSetting.parseAll([
      {'key': 'quality', 'type': 'text', 'title': '画质', 'default': 'hd'},
    ]);
    void put(List<String> mirrors, SourceRoute images, String script) =>
        db.upsertSource(
          id: 'routes',
          name: '源',
          version: '1',
          section: Section.video.id,
          script: script,
          mirrors: mirrors,
          images: images,
          settings: fields,
          commonSettings: SourceSettingsPolicy.parseCommon([
            {'key': 'pageSize', 'default': 20},
          ]),
        );
    put(
      ['https://main.example', 'https://mirror.example'],
      SourceRoute.parse(['https://a.example', 'https://b.example']),
      'old',
    );
    db.setSourceSiteConfig(
      'routes',
      db
          .source('routes')!
          .siteConfig
          .copyWith(
            mirrorIndex: 1,
            domainOverride: 'custom.example',
            account: 'account',
            images: db
                .source('routes')!
                .siteConfig
                .images
                .copyWith(
                  selected: 'https://b.example',
                  custom: 'https://images-custom.example',
                ),
            settingValues: {'quality': 'sd'},
            appSettingValues: {'pageSize': 42},
          ),
    );
    put(
      ['https://mirror.example', 'https://main.example'],
      SourceRoute.parse(['https://b.example', 'https://a.example']),
      'new',
    );
    var stored = db.source('routes')!.siteConfig;
    expect(stored.selectedMirror, 'https://mirror.example');
    expect(stored.safeMirrorIndex, 0);
    expect(stored.images.selectedUrl, 'https://b.example');
    expect(stored.images.resolved, 'https://images-custom.example');
    expect(stored.resolvedDomain, 'https://custom.example');
    expect(stored.account, 'account');
    expect(stored.resolvedSettings['quality'], 'sd');
    expect(stored.resolvedCommonSettings['pageSize'], 42);
    db.upsertSource(
      id: 'routes',
      name: '新名字',
      version: '1',
      section: Section.video.id,
      script: 'new',
      mirrors: stored.mirrors,
    );
    stored = db.source('routes')!.siteConfig;
    expect(stored.images.urls, hasLength(2));
    expect(stored.resolvedSettings['quality'], 'sd');
    final other = await openDatabase(Section.comic);
    expect(other.source('routes'), isNull);
    SectionDatabase.disposeAll();
    await SectionScope.closeAll();
    final reopened = await openDatabase(Section.video);
    expect(
      reopened.source('routes')!.siteConfig.resolvedCommonSettings['pageSize'],
      42,
    );
    expect(
      reopened.source('routes')!.siteConfig.images.resolved,
      'https://images-custom.example',
    );
  });

  group('源版本恢复', () {
    test('同版本脚本更新也保存上一版，同脚本刷新不覆盖备份', () async {
      final db = await openDatabase(Section.video);
      void write(String script, {bool remember = true, String? rejected}) =>
          db.upsertSource(
            id: 'demo',
            name: '自定义名',
            version: '1',
            section: Section.video.id,
            script: script,
            rememberPrevious: remember,
            rejectedScript: rejected,
          );
      write('old');
      expect(db.previousSource('demo'), isNull);
      db.setSourceSiteConfig(
        'demo',
        const SourceSiteConfig(
          account: 'user',
          password: 'pass',
          domainOverride: 'https://custom.example',
        ),
      );
      db.setSourceGroup('demo', '我的分组');
      db.setSourceEnabled('demo', false);
      db.setSourceOrigin('demo', 'https://subscription.example/source.js');
      db.setSetting('reading-progress', 'chapter-8');
      write('bad');
      expect(db.previousSource('demo')!['script'], 'old');
      write('bad');
      expect(db.previousSource('demo')!['script'], 'old');
      write('old', remember: false, rejected: 'bad');
      expect(db.previousSource('demo'), isNull);
      expect(db.isRejectedSource('demo', 'bad'), true);
      expect(db.isRejectedSource('demo', 'fixed'), false);
      final restored = db.source('demo')!;
      expect(restored.script, 'old');
      expect(restored.enabled, false);
      expect(restored.siteConfig.account, 'user');
      expect(restored.siteConfig.password, 'pass');
      expect(restored.siteConfig.domainOverride, 'https://custom.example');
      expect(restored.group, '我的分组');
      expect(restored.originUrl, 'https://subscription.example/source.js');
      expect(db.setting('reading-progress'), 'chapter-8');
      write('fixed');
      expect(db.previousSource('demo')!['script'], 'old');
      expect(db.isRejectedSource('demo', 'bad'), false);
    });
    test('删除源清理备份，板块之间不共享源版本', () async {
      final video = await openDatabase(Section.video);
      final comic = await openDatabase(Section.comic);
      for (final text in ['one', 'two']) {
        video.upsertSource(
          id: 'demo',
          name: '源',
          version: text,
          section: Section.video.id,
          script: text,
        );
      }
      expect(video.previousSource('demo'), isNotNull);
      expect(comic.previousSource('demo'), isNull);
      video.deleteSource('demo');
      expect(video.previousSource('demo'), isNull);
      video.upsertSource(
        id: 'demo',
        name: '源',
        version: '3',
        section: Section.video.id,
        script: 'three',
      );
      expect(video.previousSource('demo'), isNull);
    });
    test('旧库升级与重启后仍能读取备份', () async {
      final scope = await SectionScope.open(Section.video);
      final db = await SectionDatabase.open(scope);
      for (final text in ['old', 'new']) {
        db.upsertSource(
          id: 'demo',
          name: '源',
          version: text,
          section: Section.video.id,
          script: text,
        );
      }
      SectionDatabase.disposeAll();
      final raw = sqlite3.open(scope.dbPath);
      raw.execute('PRAGMA user_version=8');
      raw.close();
      final migrated = await SectionDatabase.open(scope);
      expect(migrated.source('demo')!.script, 'new');
      expect(migrated.previousSource('demo')!['script'], 'old');
    });
  });

  group('板块库：归属标记', () {
    test('标记随图源落库，读取时回得到', () async {
      final database = await openDatabase(Section.video);
      database.upsertSource(
        id: 'demo',
        name: '示例源',
        version: '1.0.0',
        section: Section.video.id,
        script: 'var LumeSource = {};',
      );

      expect(database.source('demo')!.section, Section.video.id);
      expect(database.sources().single.section, Section.video.id);
    });

    test('跨板块写入被拒绝，库里不留痕迹', () async {
      final database = await openDatabase(Section.video);
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
      final novel = await openDatabase(Section.video);
      novel.upsertSource(
        id: 'demo',
        name: '示例源',
        version: '',
        section: Section.video.id,
        script: 'var LumeSource = {};',
      );
      novel.dispose();

      final novelScope = await SectionScope.open(Section.video);
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
      final scope = await SectionScope.open(Section.video);
      final database = await SectionDatabase.open(scope);
      for (final id in <String>['demo', 'alien']) {
        database.upsertSource(
          id: id,
          name: id == 'demo' ? '示例源' : '外来图源',
          version: '',
          section: Section.video.id,
          script: 'var LumeSource = {};',
        );
      }
      forgeSection(scope, 'alien', Section.comic.id);

      final registry = await SourceRegistry.open(Section.video);
      expect(registry.sources.map((record) => record.id), <String>['demo']);
      expect(await registry.engineFor('alien'), isNull);

      registry.setEnabled('alien', false);
      registry.remove('alien');

      final check = sqlite3.open(scope.dbPath);
      final rows = check.select('SELECT * FROM source WHERE id = ?', ['alien']);
      expect(rows.length, 1, reason: '外来记录不应被删除');
      expect(rows.single['enabled'], 1, reason: '外来记录不应被停用');
      check.close();
      SourceRegistry.close(Section.video);
    });
  });

  group('注册表：当前图源', () {
    /// 往板块库里塞两条启用图源：名称排序为「A源」在「B源」之前。
    Future<SourceRegistry> seed(Section section) async {
      final scope = await SectionScope.open(section);
      final database = await SectionDatabase.open(scope);
      for (final (id, name) in <(String, String)>[('a', 'A源'), ('b', 'B源')]) {
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
      final registry = await seed(Section.video);
      expect(registry.currentSource()!.id, 'a');
      SourceRegistry.close(Section.video);
    });

    test('选择落库，重开板块后仍然生效', () async {
      final registry = await seed(Section.video);
      expect(registry.selectSource('b')!.id, 'b');
      expect(registry.currentSource()!.id, 'b');

      // 模拟重启：关掉板块再打开，选择应还在。
      SourceRegistry.close(Section.video);
      final reopened = await SourceRegistry.open(Section.video);
      expect(reopened.currentSource()!.id, 'b');
      SourceRegistry.close(Section.video);
    });

    test('不存在的图源不能被选中，且不改变现状', () async {
      final registry = await seed(Section.video);
      expect(registry.selectSource('missing'), isNull);
      expect(registry.currentSource()!.id, 'a', reason: '失败不应写入脏值');
      SourceRegistry.close(Section.video);
    });

    test('跨板块的图源不能被选为当前', () async {
      final novel = await seed(Section.video);
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
        reason: '漫画板块的记录不能成为小说板块的当前源',
      );
      expect(comic.selectSource('comic-only')!.id, 'comic-only');

      SourceRegistry.close(Section.video);
      SourceRegistry.close(Section.comic);
    });

    test('已停用的图源不能被选为当前', () async {
      final registry = await seed(Section.video);
      registry.setEnabled('b', false);
      expect(registry.selectSource('b'), isNull);
      expect(registry.currentSource()!.id, 'a');
      SourceRegistry.close(Section.video);
    });

    test('当前图源被停用或删除后自动回退，无可用图源则为空', () async {
      final registry = await seed(Section.video);
      registry.selectSource('b');

      registry.setEnabled('b', false);
      expect(registry.currentSource()!.id, 'a', reason: '停用后回退到下一个启用源');

      registry.selectSource('a');
      registry.remove('a');
      expect(registry.currentSource(), isNull, reason: '没有启用源时为 null');

      registry.setEnabled('b', true);
      expect(registry.currentSource()!.id, 'b', reason: '重新启用后重新可用');
      SourceRegistry.close(Section.video);
    });
  });

  group('板块库：换网址 / 账号登入', () {
    Future<SourceRegistry> seeded(Section section, List<String> mirrors) async {
      final scope = await SectionScope.open(section);
      final database = await SectionDatabase.open(scope);
      database.upsertSource(
        id: 'mirror',
        name: '镜像源',
        version: '1.0.0',
        section: section.id,
        script: 'var LumeSource = {};',
        mirrors: mirrors,
      );
      return SourceRegistry.open(section);
    }

    test('脚本声明的镜像随导入落库', () async {
      final registry = await seeded(Section.video, <String>[
        'https://main.example',
        'https://m1.example',
      ]);
      expect(registry.source('mirror')!.siteConfig.mirrors, <String>[
        'https://main.example',
        'https://m1.example',
      ]);
      SourceRegistry.close(Section.video);
    });

    test('保存后的配置读得回来，且只影响本源', () async {
      final registry = await seeded(Section.video, <String>[
        'https://main.example',
      ]);
      registry.setSourceSiteConfig(
        'mirror',
        const SourceSiteConfig(
          mirrors: <String>['https://main.example'],
          domainOverride: 'custom.example',
          account: 'reader',
          password: 'secret',
        ),
      );
      final record = registry.source('mirror')!;
      expect(record.siteConfig.resolvedDomain, 'https://custom.example');
      expect(record.siteConfig.account, 'reader');
      expect(record.siteConfig.password, 'secret');

      // 跨板块的同名源看不到这份配置（配置按源存在各自的板块库里）。
      final other = await seeded(Section.comic, <String>[
        'https://comic.example',
      ]);
      expect(other.source('mirror')!.siteConfig.domainOverride, '');
      expect(other.source('mirror')!.siteConfig.mirrors, <String>[
        'https://comic.example',
      ]);
      SourceRegistry.close(Section.comic);
      SourceRegistry.close(Section.video);
    });

    test('重新导入：镜像整体替换，用户自己的选择与账号保留', () async {
      final registry = await seeded(Section.video, <String>[
        'https://main.example',
        'https://m1.example',
      ]);
      registry.setSourceSiteConfig(
        'mirror',
        const SourceSiteConfig(
          mirrors: <String>['https://main.example', 'https://m1.example'],
          mirrorIndex: 1,
          account: 'reader',
          password: 'secret',
        ),
      );

      // 覆盖导入一份把镜像换成别的站的脚本。
      final scope = await SectionScope.open(Section.video);
      final database = await SectionDatabase.open(scope);
      database.upsertSource(
        id: 'mirror',
        name: '镜像源',
        version: '2.0.0',
        section: Section.video.id,
        script: 'var LumeSource = {version: "2.0.0"};',
        mirrors: <String>['https://new.example'],
      );

      final record = registry.source('mirror')!;
      expect(record.version, '2.0.0');
      expect(record.siteConfig.mirrors, <String>[
        'https://new.example',
      ], reason: '镜像由脚本声明，整体替换');
      expect(record.siteConfig.mirrorIndex, 0, reason: '旧下标 1 越界，收敛到新列表的主站');
      expect(record.siteConfig.account, 'reader', reason: '账号属于用户配置，不动');
      expect(record.siteConfig.password, 'secret');
      SourceRegistry.close(Section.video);
    });

    test('老库（没有 site_config 列）打开后读默认值，写入也正常', () async {
      final scope = await SectionScope.open(Section.video);
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
      expect(database.source('old')!.siteConfig.mirrors, isEmpty);
      expect(database.source('old')!.siteConfig.resolvedDomain, '');

      database.setSourceSiteConfig(
        'old',
        const SourceSiteConfig(
          mirrors: <String>['https://main.example'],
          account: 'reader',
        ),
      );
      final updated = database.source('old')!;
      expect(updated.siteConfig.mirrors, <String>['https://main.example']);
      expect(updated.siteConfig.resolvedDomain, 'https://main.example');
      expect(updated.siteConfig.account, 'reader');
    });
  });
}
