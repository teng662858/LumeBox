import 'cat_configuration_backup.dart';
import '../reading/reading_store.dart';
import '../media/media_library.dart';

import 'dart:convert';
import 'dart:io';

import '../security/local_cipher.dart';

import 'package:path_provider/path_provider.dart';

import '../reading/reading_library.dart';
import '../source/source_backup.dart';
import '../source/source_subscription_sync.dart';
import '../cat/cat_service.dart';
import 'section_scope.dart';
import 'section.dart';

class ConfigurationBackup {
  ConfigurationBackup({CatService? catService})
    : _catService = catService ?? CatService.instance;
  final CatService _catService;
  static Future<File>? _automatic;
  final List<String> warnings = [];
  static const files = <String>{
    'app_preferences.json',
    'media_library.json',
    'audio_book_settings.json',
    'media_preload.json',
    'tmdb_settings.json',
    'appearance_settings.json',
    'custom_icons.json',
    'shell_settings.json',
    'source_content_visibility.json',
    'search_settings.json',
    'floating_modules.json',
    'frosted_settings.json',
    'comic_image_tools.json',
    'speech_cloud.json',
    'browse_layout.json',
    'network_settings.json',
  };
  Future<String> export({String? password}) async =>
      BackupCipher.encode(await _exportPlaintext(), password: password);

  Future<String> _exportPlaintext() async {
    final base = await getApplicationSupportDirectory();
    warnings.clear();
    final settings = <String, Object?>{};
    for (final name in files) {
      final file = File('${base.path}/$name');
      if (!await file.exists()) continue;
      try {
        final value = jsonDecode(await file.readAsString());
        _validateFile(name, value);
        settings[name] = value;
      } catch (_) {
        warnings.add('$name 损坏，已跳过；其他数据仍已备份');
      }
    }
    final savedSubscriptions = <String, Object?>{};
    for (final section in [Section.comic, Section.video]) {
      await SourceSubscriptionSync.waitForIdle(section);
      final file = File(
        '${base.path}/sections/${section.id}/subscriptions.json',
      );
      if (!await file.exists()) continue;
      try {
        savedSubscriptions[section.id] =
            SourceSubscriptionSync.validateDocument(
              jsonDecode(await file.readAsString()),
            );
      } catch (_) {
        warnings.add('${section.id} 订阅配置损坏，已跳过');
      }
    }
    List<Map<String, Object?>> cats = [];
    try {
      cats = await _exportCatSubscriptions(base);
    } catch (_) {
      warnings.add('猫源订阅损坏，已跳过');
    }
    final catData = await CatConfigurationBackup.export(base, warnings);
    return jsonEncode({
      'format': 'lumebox-configuration',
      'version': 2,
      'createdAt': DateTime.now().toIso8601String(),
      'files': settings,
      'readingData': {
        for (final section in Section.values)
          section.id: (await ReadingStore.open(section))
              .cloudRecords(includeSettings: false),
      },
      'sections': {
        for (final section in Section.values)
          section.id: (await ReadingLibrary.open(section)).exportSettings(),
      },
      'sources': jsonDecode((await SourceBackupService().export()).encode()),
      'subscriptions': savedSubscriptions,
      'catSubscriptions': cats
          .where((s) => !'${s['url']}'.startsWith('local:'))
          .toList(),
      'catData': catData,
      'warnings': warnings,
    });
  }

  Future<void> restore(String text, {String? password}) async {
    final data = jsonDecode(
      await BackupCipher.decode(text, password: password),
    );
    if (data is! Map ||
        data['format'] != 'lumebox-configuration' ||
        ![1, 2].contains(data['version']) ||
        data['files'] is! Map ||
        data['sections'] is! Map) {
      throw const FormatException('不是支持的 LumeBox 配置备份');
    }
    final incomingFiles = (data['files'] as Map).cast<String, dynamic>();
    if (incomingFiles.keys.any((name) => !files.contains(name))) {
      throw const FormatException('备份包含未知配置文件');
    }
    for (final e in incomingFiles.entries) {
      _validateFile(e.key, e.value);
    }
    final readingData = data['readingData'] ?? {};
    if (readingData is! Map ||
        readingData.keys.any((k) => !Section.values.any((s) => s.id == k))) {
      throw const FormatException('阅读备份板块无效');
    }
    for (final section in Section.values) {
      final rows = readingData[section.id];
      if (rows == null) continue;
      if (rows is! Map) throw const FormatException('阅读数据格式无效');
      (await ReadingStore.open(
        section,
      )).applyCloudRecords(Map<String, Object?>.from(rows), validateOnly: true);
    }
    final sections = <Section, Map<String, String>>{};
    for (final section in Section.values) {
      final raw = data['sections'][section.id];
      if (raw == null) continue;
      if (raw is! Map ||
          raw.keys.any((key) => key is! String) ||
          raw.values.any((value) => value is! String)) {
        throw const FormatException('板块设置格式错误');
      }
      sections[section] = raw.cast<String, String>();
    }
    final sourceBackup = data['sources'] == null
        ? null
        : SourceBackup.decode(jsonEncode(data['sources']));
    final subscriptions = data['subscriptions'] ?? {};
    if (subscriptions is Map) subscriptions.remove('novel');
    if (subscriptions is! Map ||
        subscriptions.keys.any(
          (key) => !Section.values
              .where((s) => s != Section.cat)
              .any((s) => s.id == key),
        ) ||
        subscriptions.values.any(
          (value) => value is! Map || value['subscriptions'] is! List,
        )) {
      throw const FormatException('订阅配置格式错误');
    }
    for (final value in subscriptions.values) {
      SourceSubscriptionSync.validateDocument(value);
    }
    final catData = data['catData'] == null
        ? null
        : CatConfigurationBackup.validate(data['catData']);
    final catSubscriptions = data['catSubscriptions'] ?? [];
    if (catSubscriptions is! List) throw const FormatException('猫源订阅格式错误');
    final cats = <CatSubscription>[];
    for (final raw in catSubscriptions) {
      if (raw is! Map ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch('${raw['id']}') ||
          !['http', 'https'].contains(Uri.tryParse('${raw['url']}')?.scheme)) {
        throw const FormatException('猫源订阅配置无效');
      }
      cats.add(
        CatSubscription(
          id: '${raw['id']}',
          name: '${raw['name'] ?? ''}',
          url: '${raw['url']}',
          enabled: raw['enabled'] != false,
          automatic: raw['automatic'] != false,
        ),
      );
    }
    final base = await getApplicationSupportDirectory();
    // Keep an independently readable recovery snapshot before the first mutation.
    final recovery = File(
      '${base.path}/configuration_backups/before-restore-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await recovery.parent.create(recursive: true);
    await recovery.writeAsString(await export(), flush: true);
    warnings.clear();
    for (final entry in incomingFiles.entries) {
      final temp = File('${base.path}/${entry.key}.restore');
      temp.writeAsStringSync(jsonEncode(entry.value), flush: true);
      temp.renameSync('${base.path}/${entry.key}');
    }
    for (final entry in sections.entries) {
      final library = await ReadingLibrary.open(entry.key);
      for (final setting in entry.value.entries) {
        if (!setting.key.startsWith('waf.') &&
            !setting.key.startsWith('rex.widget.') &&
            setting.key != 'history.lock') {
          library.setSetting(setting.key, setting.value);
        }
      }
    }
    for (final entry in subscriptions.entries) {
      final section = Section.values.firstWhere(
        (section) => section.id == entry.key,
      );
      await SourceSubscriptionSync.maintenance(section, () async {
        final scope = await SectionScope.open(section);
        final file = File(scope.resolve('subscriptions.json'));
        final temporary = File('${file.path}.restore');
        temporary.writeAsStringSync(jsonEncode(entry.value), flush: true);
        temporary.renameSync(file.path);
      });
    }
    if (catData != null) {
      await CatConfigurationBackup.restore(_catService, catData);
    } else if (data.containsKey('catSubscriptions')) {
      final service = _catService;
      await service.boot();
      service.subscriptions
        ..clear()
        ..addAll(cats);
      await service.save();
    }
    for (final section in Section.values) {
      final rows = readingData[section.id];
      if (rows is Map) {
        (await ReadingStore.open(section))
            .applyCloudRecords(Map<String, Object?>.from(rows));
      }
    }
    if (sourceBackup != null) {
      final result = await SourceBackupService().restore(sourceBackup);
      if (result.skipped > 0) warnings.add('${result.skipped} 个源因板块或运行时不支持未恢复');
      if (result.failed > 0) {
        throw StateError('配置已恢复，部分源恢复失败：${result.failed} 项');
      }
    }
  }

  static void _validateFile(String name, Object? value) {
    if (name == 'media_library.json') {
      if (value is! List) throw const FormatException('媒体备份应为数组');
      for (final row in value) {
        if (row is! Map) throw const FormatException('媒体条目无效');
        MediaResource.fromJson(row);
      }
    } else if (name == 'source_content_visibility.json') {
      if (value is! List || value.any((v) => v is! String)) {
        throw const FormatException('内容分类格式错误');
      }
    } else if (value is! Map) {
      throw FormatException('$name 应为配置对象');
    }
  }

  Future<List<Map<String, Object?>>> _exportCatSubscriptions(
    Directory base,
  ) async {
    final file = File('${base.path}/sections/cat/node/subscriptions.json');
    if (!file.existsSync()) return [];
    final data = jsonDecode(file.readAsStringSync()) as Map;
    return [
      for (final raw in (data['subscriptions'] as List? ?? []))
        if (raw is Map)
          {
            'id': raw['id'],
            'name': raw['name'],
            'url': raw['url'],
            'enabled': raw['enabled'],
            'automatic': raw['automatic'],
          },
    ];
  }

  Future<File> automatic() =>
      _automatic ??= _createAutomatic().whenComplete(() => _automatic = null);

  Future<List<File>> snapshots() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/configuration_backups');
    if (!directory.existsSync()) return [];
    await _protectOldSnapshots(directory);
    return directory
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              RegExp(r'LumeBox-\d{4}-\d{2}-\d{2}\.json$').hasMatch(file.path),
        )
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<void> protectExistingSnapshots() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/configuration_backups');
    if (directory.existsSync()) await _protectOldSnapshots(directory);
  }

  Future<File> _createAutomatic() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/configuration_backups')
      ..createSync(recursive: true);
    await _protectOldSnapshots(directory);
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final file = File('${directory.path}/LumeBox-$day.json');
    if (!file.existsSync()) {
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(await export(), flush: true);
      temporary.renameSync(file.path);
    }
    // Keep the most recent seven daily snapshots.
    final backups =
        directory
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  RegExp(r'LumeBox-\d{4}-\d{2}-\d{2}\.json$').hasMatch(f.path),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in backups.skip(7)) {
      old.deleteSync();
    }
    return file;
  }

  Future<void> _protectOldSnapshots(Directory directory) async {
    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final text = await file.readAsString();
      if (BackupCipher.isEncrypted(text)) continue;
      try {
        final value = jsonDecode(text);
        if (value is! Map || value['format'] != 'lumebox-configuration') {
          continue;
        }
      } catch (_) {
        continue;
      }
      final temp = File('${file.path}.encrypting');
      await temp.writeAsString(await BackupCipher.encode(text), flush: true);
      await temp.rename(file.path);
    }
  }
}
