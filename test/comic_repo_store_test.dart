import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/comic/repo/comic_repo_models.dart';
import 'package:lume_box/features/comic/repo/comic_repo_store.dart';

/// 漫画扩展仓库存储的验证：仓库与扩展行的读写、安装记录、刷新覆盖规则，
/// 以及隔离——库文件落在漫画板块自己的目录下、库内自证归属、非漫画标记拒绝打开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_repo');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    ComicRepoStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ComicRepo repo({
    String id = 'https://repo.example/index.json',
    String name = '示例仓库',
    RepoKind kind = RepoKind.venera,
    int extensionCount = 0,
  }) =>
      ComicRepo(
        id: id,
        name: name,
        url: Uri.parse(id),
        kind: kind,
        extensionCount: extensionCount,
        refreshedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  RepoExtension extension({
    String id = 'copy_manga.js',
    String name = '拷贝漫画',
    String version = '1.4.2',
    ExtensionArtifact artifact = ExtensionArtifact.js,
  }) =>
      RepoExtension(
        id: id,
        name: name,
        version: version,
        artifact: artifact,
        url: Uri.parse('https://repo.example/$id'),
        sourceNames: const <String>['来源 A'],
      );

  test('仓库读写：upsert 覆盖同 id、按名称排序、删除连扩展行一起清', () async {
    final store = await ComicRepoStore.open();

    // 名称排序这里用 ASCII 名做断言（SQLite 的 NOCASE 只折叠 ASCII 大小写；
    // 中文按码点排序，不做拼音排序）。
    store.upsertRepo(repo(id: 'r-b', name: 'zeta repo'));
    store.upsertRepo(repo(id: 'r-a', name: 'Alpha repo', extensionCount: 2));
    store.upsertRepo(repo(id: 'r-a', name: 'Alpha repo', extensionCount: 5));

    final repos = store.repos();
    expect(repos.map((item) => item.id), <String>['r-a', 'r-b']);
    expect(repos.first.extensionCount, 5, reason: '同 id 覆盖写');
    expect(store.repo('r-a')?.name, 'Alpha repo');

    store.replaceExtensions('r-a', <RepoExtension>[extension()]);
    expect(store.extensionsOf('r-a'), hasLength(1));

    store.removeRepo('r-a');
    expect(store.repo('r-a'), isNull);
    expect(store.extensionsOf('r-a'), isEmpty);
    expect(store.repos(), hasLength(1));
  });

  test('扩展行：解析字段完整落库，刷新覆盖时未安装的消失、已安装的保留', () async {
    final store = await ComicRepoStore.open();
    store.upsertRepo(repo());

    store.replaceExtensions('https://repo.example/index.json', <RepoExtension>[
      extension(),
      extension(id: 'other.js', name: '另一个来源', artifact: ExtensionArtifact.apk),
    ]);
    final loaded = store.extensionsOf('https://repo.example/index.json');
    expect(loaded, hasLength(2));
    expect(loaded.first.name, '另一个来源', reason: '按名称排序');
    expect(loaded.first.artifact, ExtensionArtifact.apk);
    expect(loaded.last.sourceNames, <String>['来源 A']);

    // 安装其中一个，然后刷新成只含新扩展的索引。
    store.markInstalled(
      repoId: 'https://repo.example/index.json',
      extensionId: 'copy_manga.js',
      sourceId: 'lume.copy',
      version: '1.4.2',
    );
    store.replaceExtensions('https://repo.example/index.json', <RepoExtension>[
      extension(id: 'fresh.js', name: '新上架'),
    ]);

    final afterRefresh = store.extensionsOf('https://repo.example/index.json');
    expect(
      afterRefresh.map((item) => item.id).toSet(),
      <String>{'copy_manga.js', 'fresh.js'},
      reason: '已安装的行保留，未安装且消失的行清掉',
    );
    final installed = store.installedOf('https://repo.example/index.json');
    expect(installed.keys, <String>['copy_manga.js']);
    expect(installed['copy_manga.js']!.sourceId, 'lume.copy');
    expect(installed['copy_manga.js']!.version, '1.4.2');

    store.clearInstalled(
      repoId: 'https://repo.example/index.json',
      extensionId: 'copy_manga.js',
    );
    expect(store.installedOf('https://repo.example/index.json'), isEmpty);
  });

  test('隔离：库文件在漫画板块目录下、库内自证归属、其他板块目录没有它', () async {
    final store = await ComicRepoStore.open();
    store.upsertRepo(repo());

    final dbFile = File('${root.path}/sections/comic/repo.db');
    expect(dbFile.existsSync(), isTrue);
    expect(
      File('${root.path}/sections/novel/repo.db').existsSync(),
      isFalse,
      reason: '其他板块目录下不应出现仓库库',
    );

    // 库内自证：owner_section = comic。
    final db = sqlite3.open(dbFile.path);
    final rows = db.select(
      "SELECT value FROM repo_meta WHERE key = 'owner_section'",
    );
    db.close();
    expect(rows.single['value'], 'comic');
  });

  test('拒绝打开非漫画的仓库库（归属标记不符）', () async {
    final dir = Directory('${root.path}/sections/comic')
      ..createSync(recursive: true);
    final db = sqlite3.open('${dir.path}/repo.db');
    db.execute('CREATE TABLE repo_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    db.execute(
      "INSERT INTO repo_meta (key, value) VALUES ('owner_section', 'novel')",
    );
    db.close();

    await expectLater(ComicRepoStore.open(), throwsA(isA<StateError>()));
  });

  test('板块枚举顺序不受影响：仓库库只服务漫画', () async {
    final store = await ComicRepoStore.open();
    expect(store.repos(), isEmpty);
    // 打开仓库库不会在别的板块落任何文件。
    final sections = Directory('${root.path}/sections');
    final names = sections
        .listSync()
        .whereType<Directory>()
        .map((dir) => dir.path.split(RegExp(r'[\\/]')).last)
        .toSet();
    expect(names, <String>{Section.comic.id});
  });
}
