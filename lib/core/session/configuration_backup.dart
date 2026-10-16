import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../reading/reading_library.dart';
import '../source/source_backup.dart';
import '../source/source_subscription_sync.dart';
import '../cat/cat_service.dart';
import 'section_scope.dart';
import 'section.dart';

class ConfigurationBackup {
  static Future<File>? _automatic;
  static const files = <String>{
    'app_preferences.json',
    'tmdb_settings.json',
    'appearance_settings.json',
    'shell_settings.json',
    'source_content_visibility.json',
    'search_settings.json',
    'floating_modules.json',
    'frosted_settings.json',
    'comic_image_tools.json',
    'speech_cloud.json',
    'audio_book_settings.json',
    'browse_layout.json',
    'network_settings.json',
  };
  Future<String> export() async {
    final base = await getApplicationSupportDirectory();
    return jsonEncode({
      'format': 'lumebox-configuration',
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'files': {
        for (final name in files)
          if (File('${base.path}/$name').existsSync())
            name: jsonDecode(File('${base.path}/$name').readAsStringSync()),
      },
      'sections': {
        for (final section in Section.values)
          section.id: (await ReadingLibrary.open(section)).exportSettings(),
      },
      'sources': jsonDecode((await SourceBackupService().export()).encode()),
      'subscriptions': {
        for (final section in Section.values.where(
          (section) => section != Section.cat,
        ))
          if (File('${base.path}/sections/${section.id}/subscriptions.json')
              .existsSync())
            section.id: jsonDecode(
              File('${base.path}/sections/${section.id}/subscriptions.json')
                  .readAsStringSync(),
            ),
      },
      'catSubscriptions': await _exportCatSubscriptions(base),
    });
  }

  Future<void> restore(String text) async {
    final data = jsonDecode(text);
    if (data is! Map ||
        data['format'] != 'lumebox-configuration' ||
        data['version'] != 1 ||
        data['files'] is! Map ||
        data['sections'] is! Map) {
      throw const FormatException('不是支持的 LumeBox 配置备份');
    }
    final incomingFiles = (data['files'] as Map).cast<String, dynamic>();
    if (incomingFiles.keys.any((name) => !files.contains(name))) {
      throw const FormatException('备份包含未知配置文件');
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
    for (final entry in incomingFiles.entries) {
      final temp = File('${base.path}/${entry.key}.restore');
      temp.writeAsStringSync(jsonEncode(entry.value), flush: true);
      temp.renameSync('${base.path}/${entry.key}');
    }
    for (final entry in sections.entries) {
      final library = await ReadingLibrary.open(entry.key);
      for (final setting in entry.value.entries) {
        if (!setting.key.startsWith('waf.') && setting.key != 'history.lock') {
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
    if (data.containsKey('catSubscriptions')) {
      final service = CatService.instance;
      await service.boot();
      service.subscriptions
        ..clear()
        ..addAll(cats);
      await service.save();
    }
    if (sourceBackup != null) {
      final result = await SourceBackupService().restore(sourceBackup);
      if (result.failed > 0) {
        throw StateError('配置已恢复，部分源恢复失败：${result.failed} 项');
      }
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

  Future<File> _createAutomatic() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/configuration_backups')
      ..createSync(recursive: true);
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
}
