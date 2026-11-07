import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/experience/content_center.dart';
import '../../core/experience/offline_policy.dart';
import '../../core/source/source.dart';
import '../../core/reading/reading.dart';
import '../comic/comic_download_center.dart';

class ReadingOffline {
  static final _busy = <String>{};
  static String cacheId(DataSource source, String item, String chapter) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode([source.section.id, source.id, item, chapter]),
            ),
          )
          .toString();
  static Future<File> file(
    DataSource source,
    String item,
    String chapter,
  ) async {
    final id = sha256.convert(
      utf8.encode(jsonEncode([source.section.id, source.id, item, chapter])),
    );
    return File(
      '${(await getApplicationSupportDirectory()).path}/novel_offline/$id.txt',
    );
  }

  static Future<TextContent?> read(
    DataSource source,
    String item,
    String chapter,
  ) async {
    if (!ContentCenter.instance.enabled(
      'novelCached.${cacheId(source, item, chapter)}',
    )) {
      return null;
    }
    final target = await file(source, item, chapter);
    if (!await target.exists() || await target.length() > 2 * 1024 * 1024) {
      return null;
    }
    return TextContent(await target.readAsString());
  }

  static Future<void> store(
    DataSource source,
    String item,
    String chapter,
    String text,
  ) async {
    if (utf8.encode(text).length > 2 * 1024 * 1024) return;
    final target = await file(source, item, chapter);
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(target.path);
    ContentCenter.instance.put(
      'novelCached.${cacheId(source, item, chapter)}',
      true,
    );
  }

  static Future<void> prefetch({
    required DataSource source,
    required ReadingLibrary library,
    required ReadingTarget target,
    required List<SourceChapter> chapters,
    required int current,
    required bool novel,
    bool Function()? cancelled,
  }) async {
    if (!ContentCenter.instance.enabled('autoReadDownloads')) return;
    final key = jsonEncode([source.section.id, source.id, target.itemId]);
    if (!_busy.add(key)) return;
    try {
      if (await OfflinePolicy.blocked() != null) return;
      final indices = [
        for (
          var i = current + 1;
          i < chapters.length &&
              i <=
                  current +
                      ContentCenter.instance
                          .number('nextDownloads', 2)
                          .clamp(1, 5);
          i++
        )
          i,
      ];
      if (novel) {
        for (final index in indices) {
          if (cancelled?.call() == true ||
              await OfflinePolicy.blocked() != null) {
            return;
          }
          if (await read(source, target.itemId, chapters[index].id) != null) {
            continue;
          }
          final content = await source
              .content(itemId: target.itemId, chapterId: chapters[index].id)
              .timeout(const Duration(seconds: 30));
          if (content is TextContent) {
            await store(
              source,
              target.itemId,
              chapters[index].id,
              content.text,
            );
          }
        }
      } else if (indices.isNotEmpty) {
        final center = ComicDownloadCenter.instance;
        await center.boot();
        final downloader = center.attach(
          source: source,
          library: library,
          itemId: target.itemId,
          title: target.title,
        );
        if (downloader.progress.running) return;
        await center.enqueue(downloader, chapters, indices);
      }
    } catch (_) {
      /* Optional prefetch never interrupts reading. */
    } finally {
      _busy.remove(key);
    }
  }
}
