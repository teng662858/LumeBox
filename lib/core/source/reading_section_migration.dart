import 'dart:convert';
import 'dart:io';

import '../util/lume_log.dart';
import '../db/section_database.dart';
import '../reading/reading_store.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import 'source_media_hints.dart';

/// Runs before pages, registries and subscription jobs are created. Each source
/// is removed only after both copies commit. Interrupted copies can be retried.
class ReadingSectionMigration {
  static Future<void> run() async {
    final videoScope = await SectionScope.open(Section.video);
    final comicScope = await SectionScope.open(Section.comic);
    final video = await SectionDatabase.open(videoScope);
    final comic = await SectionDatabase.open(comicScope);
    final candidates = video
        .sources()
        .where(
          (source) =>
              source.id.startsWith('kazumi_') ||
              SourceMediaHints.fromScript(source.script) == 'audio' ||
              SourceMediaHints.fromScript(source.script) == 'novel' ||
              (!source.id.startsWith('tvbox_') &&
                  SourceMediaHints.fromScript(source.script) != 'video' &&
                  SourceMediaHints.audioLabel(
                    '${source.name} ${source.id} ${source.group}',
                  )),
        )
        .toList();
    if (candidates.isEmpty) return;
    final oldReading = await ReadingStore.open(Section.video);
    final newReading = await ReadingStore.open(Section.comic);
    final moved = <String>{};
    for (final source in candidates) {
      if (comic.source(source.id) != null &&
          comic.source(source.id)!.script != source.script) {
        LumeLog.warn('阅读源迁移保留同 ID 冲突源：${source.id}');
        continue;
      }
      video.copySourceTo(source.id, comic);
      oldReading.copySourceTo(source.id, newReading);
      moved.add(source.id);
    }
    // Keep dedicated subscription ownership with the sources it updates. Mixed
    // subscriptions remain in video; relocated members retain their script URL.
    final oldFile = File(videoScope.resolve('subscriptions.json'));
    if (moved.isNotEmpty && oldFile.existsSync()) {
      final oldData = Map<String, dynamic>.from(
        jsonDecode(oldFile.readAsStringSync()) as Map,
      );
      final newFile = File(comicScope.resolve('subscriptions.json'));
      final newData = newFile.existsSync()
          ? Map<String, dynamic>.from(
              jsonDecode(newFile.readAsStringSync()) as Map,
            )
          : <String, dynamic>{'migrationVersion': 3, 'subscriptions': []};
      final targetRows = List<dynamic>.of(
        newData['subscriptions'] as List? ?? [],
      );
      final keep = <dynamic>[];
      for (final raw in oldData['subscriptions'] as List? ?? []) {
        final row = Map<String, dynamic>.from(raw as Map);
        final members = Map<String, dynamic>.from(row['members'] as Map? ?? {});
        final ids = members.keys.where(moved.contains).toSet();
        final dedicated = ids.isNotEmpty && ids.length == members.length;
        if (dedicated) {
          if (!targetRows.any(
            (entry) => entry is Map && entry['url'] == row['url'],
          )) {
            targetRows.add(row);
          }
        } else {
          keep.add(row);
          for (final source in candidates.where(
            (source) => ids.contains(source.id) && source.originUrl.isNotEmpty,
          )) {
            if (!targetRows.any(
              (entry) => entry is Map && entry['url'] == source.originUrl,
            )) {
              targetRows.add({
                'url': source.originUrl,
                'enabled': row['enabled'] != false,
                'members': {source.id: members[source.id]},
              });
            }
          }
        }
      }
      newData['subscriptions'] = targetRows;
      oldData['subscriptions'] = keep;
      // Destination first: a crash can leave a duplicate, never lose the record.
      for (final (file, data) in [(newFile, newData), (oldFile, oldData)]) {
        final temp = File('${file.path}.reading-move.tmp');
        temp.writeAsStringSync(jsonEncode(data), flush: true);
        temp.renameSync(file.path);
      }
    }
    // Remove originals only after destination data and subscriptions are durable.
    for (final id in moved) {
      oldReading.removeRelocatedSource(id);
      video.deleteSource(id);
    }
    final current = video.setting('current_source');
    if (current != null && moved.contains(current)) {
      if (comic.setting('current_source') == null) {
        comic.setSetting('current_source', current);
      }
      video.setSetting('current_source', '');
    }
  }
}
