import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/reading/reading_store.dart';
import 'package:lume_box/core/security/local_cipher.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_site_config.dart';
import 'package:lume_box/core/session/configuration_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('private_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (c) async => root.path,
        );
  });
  tearDown(() async {
    SectionDatabase.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  test('Source account, password, Cookie, proxy and runtime tokens are ciphertext on disk', () async {
    final scope = await SectionScope.open(Section.video);
    final db = await SectionDatabase.open(scope);
    db.upsertSource(
      id: 'private',
      name: 'private',
      version: '1',
      section: 'video',
      script: '// test',
    );
    db.setSourceSiteConfig(
      'private',
      SourceSiteConfig.fromJson({
        'account': 'account-secret',
        'password': 'password-secret',
      }),
    );
    db.setSourceNetwork(
      'private',
      userAgent: '',
      cookie: 'cookie-secret',
      proxy: 'http://user:proxy-secret@localhost',
    );
    final store = await ReadingStore.open(Section.video);
    store.setSetting('source.runtime.storage.private', 'token-secret');
    expect(db.source('private')!.siteConfig.password, 'password-secret');
    expect(store.setting('source.runtime.storage.private'), 'token-secret');
    final raw = sqlite3.open(scope.dbPath);
    final row = raw
        .select('SELECT cookie,site_config,proxy FROM source')
        .single;
    for (final key in ['cookie', 'site_config', 'proxy']) {
      expect(row[key], startsWith(LocalCipher.prefix));
    }
    raw.close();
    final reading = sqlite3.open(scope.resolve('reading.db'));
    expect(
      reading
          .select(
            "SELECT value FROM reading_setting WHERE key='source.runtime.storage.private'",
          )
          .single['value'],
      startsWith(LocalCipher.prefix),
    );
    reading.close();
    SectionDatabase.disposeAll();
    ReadingStore.disposeAll();
    expect(
      (await SectionDatabase.open(scope)).source('private')!.network.cookie,
      'cookie-secret',
    );
    expect(
      (await ReadingStore.open(Section.video))
          .setting('source.runtime.storage.private'),
      'token-secret',
    );
  });
  test(
    'Existing plaintext source and settings migrate and survive reopening',
    () async {
      final scope = await SectionScope.open(Section.video);
      final db = await SectionDatabase.open(scope);
      db.upsertSource(
        id: 'legacy',
        name: 'legacy',
        version: '1',
        section: 'video',
        script: '// test',
      );
      SectionDatabase.disposeAll();
      final raw = sqlite3.open(scope.dbPath);
      raw.execute('UPDATE source SET cookie=?,site_config=? WHERE id=?', [
        'legacy-cookie',
        jsonEncode({
          'account': 'legacy-account',
          'password': 'legacy-password',
        }),
        'legacy',
      ]);
      raw.close();
      var store = await ReadingStore.open(Section.video);
      store.setSetting('source.preferences.legacy', 'legacy-token');
      ReadingStore.disposeAll();
      final reading = sqlite3.open(scope.resolve('reading.db'));
      reading.execute('UPDATE reading_setting SET value=? WHERE key=?', [
        'legacy-token',
        'source.preferences.legacy',
      ]);
      reading.close();
      final migrated = await SectionDatabase.open(scope);
      store = await ReadingStore.open(Section.video);
      expect(migrated.source('legacy')!.siteConfig.password, 'legacy-password');
      expect(store.setting('source.preferences.legacy'), 'legacy-token');
      SectionDatabase.disposeAll();
      ReadingStore.disposeAll();
      for (final file in scope.root.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.db') || f.path.endsWith('-wal'),
      )) {
        final bytes = latin1.decode(file.readAsBytesSync());
        for (final secret in [
          'legacy-cookie',
          'legacy-account',
          'legacy-password',
          'legacy-token',
        ]) {
          expect(bytes, isNot(contains(secret)), reason: file.path);
        }
      }
    },
  );
  test('Old daily and recovery snapshots are encrypted in place', () async {
    final dir = Directory('${root.path}/configuration_backups')..createSync();
    const raw =
        '{"format":"lumebox-configuration","version":2,"private":"legacy-backup-secret"}';
    final daily = File('${dir.path}/LumeBox-2026-11-01.json')
      ..writeAsStringSync(raw);
    final recovery = File('${dir.path}/before-restore-123.json')
      ..writeAsStringSync(raw);
    final snapshots = await ConfigurationBackup().snapshots();
    expect(snapshots, hasLength(1));
    for (final f in [daily, recovery]) {
      final text = f.readAsStringSync();
      expect(text, isNot(contains('legacy-backup-secret')));
      expect(await BackupCipher.decode(text), raw);
    }
  });
}
