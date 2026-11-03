import 'package:crypto/crypto.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'dart:convert';

import 'package:lume_box/core/security/local_cipher.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/favorite_folders.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/reading/reading_identity.dart';
import 'package:lume_box/core/session/configuration_backup.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/js/source_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final directories = <Directory>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> close() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    for (final s in Section.values) {
      SourceRegistry.close(s);
    }
    await SectionScope.closeAll();
  }

  void newDevice() {
    root = Directory.systemTemp.createTempSync('lumebox-new-device-');
    directories.add(root);
  }

  setUp(() {
    newDevice();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
  });
  tearDown(() async {
    await close();
    for (final dir in directories) {
      await dir.delete(recursive: true);
    }
    directories.clear();
  });
  VideoProgress progress(String source, String chapter, int seconds) =>
      VideoProgress(
        section: Section.video,
        sourceId: source,
        itemId: 'same-id',
        chapterIndex: chapter == 'e1' ? 0 : 1,
        chapterId: chapter,
        chapterTitle: chapter,
        updatedAt: DateTime.now(),
        position: Duration(seconds: seconds),
        duration: const Duration(minutes: 20),
      );
  test('real v4 database migrates atomically with favorites, historical episodes and item preferences intact', () async {
    final scope = await SectionScope.open(Section.video);
    final db = sqlite3.open(scope.resolve('reading.db'));
    db.execute("""
CREATE TABLE reading_setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE library_item (item_id TEXT PRIMARY KEY, section TEXT NOT NULL, source_id TEXT NOT NULL, title TEXT NOT NULL, cover TEXT, subtitle TEXT, chapter_count INTEGER NOT NULL DEFAULT 0, read_chapter_index INTEGER NOT NULL DEFAULT -1, added_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, favorite INTEGER NOT NULL DEFAULT 1);
CREATE TABLE reading_progress (item_id TEXT PRIMARY KEY, section TEXT NOT NULL, chapter_index INTEGER NOT NULL, chapter_id TEXT NOT NULL, chapter_title TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, fraction REAL NOT NULL DEFAULT 0, chapter_length INTEGER NOT NULL DEFAULT 0, progress_kind TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL);
CREATE TABLE video_episode_progress AS SELECT * FROM reading_progress WHERE 0;
CREATE UNIQUE INDEX video_episode_identity ON video_episode_progress(item_id,chapter_id,section);
INSERT INTO library_item VALUES ('same-id','video','legacy','old',NULL,NULL,2,1,100,200,1);
INSERT INTO reading_progress VALUES ('same-id','video',1,'e2','e2',20000,1200000,0,'video',200);
INSERT INTO video_episode_progress SELECT * FROM reading_progress;
INSERT INTO video_episode_progress VALUES ('same-id','video',0,'e1','e1',10000,1200000,0,'video',100);
INSERT INTO reading_setting VALUES ('favorites.folders','{"watch":["same-id"]}');
INSERT INTO reading_setting VALUES ('bangumi.binding.same-id','legacy-binding');
PRAGMA user_version = 4;
""");
    db.close();
    final library = await ReadingLibrary.open(Section.video);
    expect(library.favorites().single.sourceId, 'legacy');
    expect(
      library.videoEpisodeProgresses('same-id', sourceId: 'legacy'),
      hasLength(2),
    );
    expect(
      library.videoProgress('same-id', sourceId: 'legacy')!.position.inSeconds,
      20,
    );
    expect(FavoriteFolders(library).load()['watch'], [
      ReadingIdentity.key('legacy', 'same-id'),
    ]);
    expect(
      library.setting(
        'bangumi.binding.${ReadingIdentity.key('legacy', 'same-id')}',
      ),
      'legacy-binding',
    );
    expect(
      await File('${scope.resolve('reading.db')}.before-identity-v5').exists(),
      true,
    );
    library.shelve(sourceId: 'new', itemId: 'same-id', title: 'new');
    library.saveProgress(progress('new', 'e1', 80));
    expect(
      library
          .videoEpisodeProgress('same-id', 'e1', sourceId: 'legacy')!
          .position
          .inSeconds,
      10,
    );
  });

  test('same raw ID from different sources isolates favorites, history, episode progress and folders across reopen', () async {
    var library = await ReadingLibrary.open(Section.video);
    for (final s in ['a', 'b']) {
      library.shelve(sourceId: s, itemId: 'same-id', title: 'title-$s');
      library.saveProgress(progress(s, 'e1', s == 'a' ? 10 : 80));
    }
    final folders = FavoriteFolders(library)..create('watch');
    folders.move(ReadingIdentity.key('a', 'same-id'), 'watch');
    library.removeFavorite('same-id', sourceId: 'a');
    expect(library.onShelf('same-id', sourceId: 'b'), true);
    expect(library.history(), hasLength(2));
    expect(
      library.item('same-id'),
      isNull,
      reason: 'ambiguous raw ID must never select an arbitrary source',
    );
    await close();
    library = await ReadingLibrary.open(Section.video);
    expect(
      library.videoProgress('same-id', sourceId: 'a')!.position.inSeconds,
      10,
    );
    expect(
      library.videoProgress('same-id', sourceId: 'b')!.position.inSeconds,
      80,
    );
    expect(FavoriteFolders(library).load()['watch'], [
      ReadingIdentity.key('a', 'same-id'),
    ]);
    library.removeHistory('same-id', sourceId: 'a');
    expect(library.history().single.sourceId, 'b');
    expect(
      library.videoEpisodeProgress('same-id', 'e1', sourceId: 'b'),
      isNotNull,
    );
  });
  test('configuration restores to a genuinely empty device with all sections and episodes', () async {
    final library = await ReadingLibrary.open(Section.video);
    library.shelve(sourceId: 'a', itemId: 'same-id', title: 'favorite');
    library.recordHistoryItem(
      sourceId: 'b',
      itemId: 'same-id',
      title: 'history only',
    );
    library.saveProgress(progress('a', 'e1', 10));
    library.saveProgress(progress('a', 'e2', 20));
    library.saveProgress(progress('b', 'e1', 80));
    library.setSetting('reader.fontSize', '22');
    library.setSetting('history.lock', 'never-export-lock');
    final folders = FavoriteFolders(library)..create('watch');
    folders.move(ReadingIdentity.key('a', 'same-id'), 'watch');
    final comic = await ReadingLibrary.open(Section.comic);
    comic.shelve(sourceId: 'c', itemId: 'same-id', title: 'comic');
    comic.saveProgress(
      ComicProgress(
        section: Section.comic,
        sourceId: 'c',
        itemId: 'same-id',
        chapterIndex: 3,
        chapterId: 'c3',
        chapterTitle: 'chapter3',
        updatedAt: DateTime.now(),
        page: 7,
        pageFraction: .25,
      ),
    );
    final cat = await ReadingLibrary.open(Section.cat);
    cat.recordHistoryItem(
      sourceId: 'cat-site',
      itemId: 'same-id',
      title: 'cat history',
    );
    await File('${root.path}/appearance_settings.json')
        .writeAsString('{"theme":"dark"}');
    final media = [
      {
        'id': 'manual-1',
        'title': 'media',
        'kind': 'video',
        'destination': 'video',
        'episodes': [
          {
            'id': 'ep',
            'title': 'ep',
            'url': 'https://example.com/media.mp4',
            'headers': {},
          },
        ],
        'manual': true,
      },
    ];
    await File('${root.path}/media_library.json')
        .writeAsString(jsonEncode(media));
    final sub = {
      'subscriptions': [
        {
          'url': 'https://example.com/sub.json',
          'enabled': false,
          'excludedIds': ['off'],
          'members': {'member': 'https://example.com/member.js'},
        },
      ],
      'migrationVersion': 3,
    };
    await File('${root.path}/sections/video/subscriptions.json')
        .writeAsString(jsonEncode(sub));
    final expected = {
      for (final s in Section.values)
        s.id: (await ReadingStore.open(s)).cloudRecords(includeSettings: false),
    };
    final backup = ConfigurationBackup(catService: CatService.testing());
    final encoded = await backup.export(password: 'portable-backup-test');
    expect(encoded, isNot(contains('never-export-lock')));
    await close();
    newDevice();
    expect(await root.list().isEmpty, true);
    await backup.restore(encoded, password: 'portable-backup-test');
    for (final s in Section.values) {
      expect(
        (await ReadingStore.open(s)).cloudRecords(includeSettings: false),
        expected[s.id],
      );
    }
    final restored = await ReadingLibrary.open(Section.video);
    expect(restored.favorites().single.sourceId, 'a');
    expect(restored.history(), hasLength(2));
    expect(
      restored.videoEpisodeProgresses('same-id', sourceId: 'a'),
      hasLength(2),
    );
    expect(
      restored
          .videoEpisodeProgress('same-id', 'e1', sourceId: 'b')!
          .position
          .inSeconds,
      80,
    );
    expect(restored.setting('reader.fontSize'), '22');
    expect(restored.setting('history.lock'), isNull);
    expect(
      jsonDecode(await File('${root.path}/media_library.json').readAsString()),
      media,
    );
    expect(
      jsonDecode(
        await File('${root.path}/sections/video/subscriptions.json')
            .readAsString(),
      ),
      sub,
    );
    expect(
      jsonDecode(
        await File('${root.path}/appearance_settings.json').readAsString(),
      ),
      {'theme': 'dark'},
    );
    expect(
      await Directory('${root.path}/configuration_backups').list().length,
      1,
    );
  });
  test('empty-device restore also preserves Node cat source programs and native collections', () async {
    final index = utf8.encode('module.exports = {};'),
        config = utf8.encode('module.exports = {sites:[]};');
    final hash = md5.convert(index).toString(),
        configHash = md5.convert(config).toString();
    final bundlePath =
        '${root.path}/sections/cat/node/bundles/local-cat/$hash-$configHash';
    await Directory(bundlePath).create(recursive: true);
    await File('$bundlePath/index.js').writeAsBytes(index);
    await File('$bundlePath/index.config.js').writeAsBytes(config);
    const item = {
      'site': 'local-cat|video|site',
      'id': 'same-id',
      'title': 'Node favorite',
      'time': 12345,
    };
    final raw = {
      'subscriptions': [
        {
          'id': 'local-cat',
          'name': 'local source',
          'url': 'local:local-cat',
          'hash': hash,
          'configHash': configHash,
          'sites': [
            {
              'key': 'site',
              'name': 'site',
              'kind': 'video',
              'api': '/spider/site/3',
            },
          ],
        },
      ],
      'favorites': ['local-cat|video|site|same-id'],
      'bookmarks': [item],
      'history': [item],
      'siteColumns': 2,
    };
    await File('${root.path}/sections/cat/node/subscriptions.json')
        .writeAsString(jsonEncode(raw));
    final service = CatService.testing();
    addTearDown(service.closeForTesting);
    final backup = ConfigurationBackup(catService: service);
    final text = await backup.export(password: 'portable-backup-test');
    expect(backup.warnings, isEmpty);
    await close();
    newDevice();
    await backup.restore(text, password: 'portable-backup-test');
    expect(service.subscriptions.single.id, 'local-cat');
    expect(service.favoriteItems.single['title'], 'Node favorite');
    expect(service.history.single['site'], 'local-cat|video|site');
    expect(service.siteColumns, 2);
    expect(service.needsSiteSelection, true);
    expect(await service.hasBundle(service.subscriptions.single), true);
    final restored = File(
      '${root.path}/sections/cat/node/bundles/local-cat/$hash-$configHash/index.js',
    );
    expect(await restored.readAsBytes(), index);
    final bad = jsonDecode(
      await BackupCipher.decode(text, password: 'portable-backup-test'),
    ) as Map;
    bad['catData']['bundles']['local-cat']['index'] = base64Encode([1, 2, 3]);
    await expectLater(backup.restore(jsonEncode(bad)), throwsFormatException);
    expect(await restored.readAsBytes(), index);
  });

  test(
    'damaged JSON is skipped with an explicit warning while valid data exports',
    () async {
      await File('${root.path}/appearance_settings.json')
          .writeAsString('{broken');
      await File('${root.path}/app_preferences.json')
          .writeAsString('{"autoBackup":true}');
      final backup = ConfigurationBackup(catService: CatService.testing());
      final data =
          jsonDecode(await BackupCipher.decode(await backup.export())) as Map;
      expect(data['files']['app_preferences.json'], {'autoBackup': true});
      expect(
        (data['files'] as Map).containsKey('appearance_settings.json'),
        false,
      );
      expect(backup.warnings.single, contains('appearance_settings.json'));
    },
  );
  test('选择恢复设置时保留未选中的订阅，并可预览备份内容', () async {
    final backup = ConfigurationBackup(catService: CatService.testing());
    final subscriptionFile = File(
      '${root.path}/sections/video/subscriptions.json',
    );
    await subscriptionFile.parent.create(recursive: true);
    final original = jsonEncode({
      'subscriptions': [
        {'url': 'https://keep.example/list', 'enabled': false},
      ],
    });
    await subscriptionFile.writeAsString(original);
    final text = jsonEncode({
      'format': 'lumebox-configuration',
      'version': 2,
      'createdAt': '2026-11-03',
      'files': {
        'app_preferences.json': {'autoBackup': false},
      },
      'sections': {},
      'subscriptions': {
        'video': {'subscriptions': []},
      },
    });
    expect((await backup.preview(text))['createdAt'], '2026-11-03');
    await backup.restore(text, parts: {ConfigurationRestorePart.settings});
    expect(await subscriptionFile.readAsString(), original);
    expect(
      jsonDecode(
        await File('${root.path}/app_preferences.json').readAsString(),
      ),
      {'autoBackup': false},
    );
    await expectLater(backup.restore(text, parts: {}), throwsFormatException);
  });

  test('malformed subscriptions and mismatched identities fail before any settings mutation', () async {
    final backup = ConfigurationBackup(catService: CatService.testing());
    final data =
        jsonDecode(await BackupCipher.decode(await backup.export())) as Map;
    data['files'] = {
      'app_preferences.json': {'autoBackup': false},
    };
    data['subscriptions'] = {
      'video': {
        'subscriptions': [
          {'url': 'https://example.com/sub', 'excludedIds': 42},
        ],
      },
    };
    await expectLater(backup.restore(jsonEncode(data)), throwsFormatException);
    expect(await File('${root.path}/app_preferences.json').exists(), false);
    final store = await ReadingStore.open(Section.video);
    final library = await ReadingLibrary.open(Section.video);
    library.shelve(sourceId: 'a', itemId: 'same-id', title: 'keep');
    final rows = store.cloudRecords(includeSettings: false);
    final row = rows.values.single;
    expect(
      () => store.applyCloudRecords({
        jsonEncode([
          'video',
          'library_item',
          ReadingIdentity.key('b', 'same-id'),
        ]): row,
      }),
      throwsFormatException,
    );
    expect(library.item('same-id', sourceId: 'a')!.title, 'keep');
    expect(
      () => SourceSubscriptionSync.validateDocument({
        'subscriptions': [
          {'url': 'https://example.com', 'members': []},
        ],
      }),
      throwsFormatException,
    );
  });
}
