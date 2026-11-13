import 'tracking_resume.dart';
import 'reading_offline.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../core/experience/content_center.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../video/video_download_center.dart';
import '../video/video_episode_catalog.dart';

class TrackingReport {
  const TrackingReport(
    this.success,
    this.failed,
    this.newChapters,
    this.cancelled,
  );
  final int success, failed, newChapters;
  final bool cancelled;
  String get summary =>
      '${cancelled ? '已停止 · ' : ''}成功 $success 部，失败 $failed 部，新增 $newChapters 章；首次检查建立基线';
}

class TrackingService with WidgetsBindingObserver {
  TrackingService({this.managerFor, this.wait});
  final SourceManager Function(Section)? managerFor;
  final Future<void> Function()? wait;
  static final instance = TrackingService();
  bool busy = false;
  DateTime? foregroundCheck;
  void boot() {
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ContentCenter.instance.enabled('autoChecks') &&
        (foregroundCheck == null ||
            DateTime.now().difference(foregroundCheck!) >
                const Duration(hours: 6))) {
      foregroundCheck = DateTime.now();
      unawaited(check());
    }
  }

  Future<TrackingReport> check({
    List<ReadingLibrary>? libraries,
    void Function(String)? onStatus,
    bool Function()? cancelled,
  }) async {
    if (busy) return const TrackingReport(0, 0, 0, true);
    busy = true;
    int success = 0, failed = 0, fresh = 0;
    final center = ContentCenter.instance;
    try {
      final libs =
          libraries ??
          [
            for (final section in Section.values)
              await ReadingLibrary.open(section),
          ];
      for (final lib in libs) {
        final manager =
            managerFor?.call(lib.section) ?? LumeSources.manager(lib.section);
        final excludedSources = <String>{};
        if (center.enabled('skipUnhealthy')) {
          try {
            for (final source in await manager.list()) {
              if (!source.enabled || source.failureCount >= 3) {
                excludedSources.add(source.id);
              }
            }
          } catch (_) {}
        }
        for (final item in lib.favorites()) {
          if (cancelled?.call() == true) {
            return TrackingReport(success, failed, fresh, true);
          }
          final ref = ContentRef.of(item);
          if (center.trackingState(ref) != 'active' ||
              excludedSources.contains(item.sourceId)) {
            continue;
          }
          final checked = DateTime.tryParse(
            '${center.data['checked.${ref.key}'] ?? ''}',
          );
          if (checked != null &&
              DateTime.now().difference(checked) <
                  const Duration(minutes: 15)) {
            continue;
          }
          onStatus?.call('正在检查：${item.title}');
          try {
            final manager =
                managerFor?.call(lib.section) ??
                LumeSources.manager(lib.section);
            if (!manager.runtimeAvailable) continue;
            final source = await manager
                .open(item.sourceId)
                .timeout(const Duration(seconds: 20));
            if (source == null) throw StateError('源不可用');
            final chapters = await source
                .chapters(item.itemId)
                .timeout(const Duration(seconds: 40));
            if (chapters.isEmpty) throw StateError('目录为空');
            if (cancelled?.call() == true) {
              return TrackingReport(success, failed, fresh, true);
            }
            if (lib.section == Section.video) {
              // Older baselines used route IDs or one key for all parts of an episode.
              final baselines = Map<String, dynamic>.from(
                center.data['baselines'] as Map? ?? {},
              );
              final old = baselines[ref.key];
              if (old is List) {
                final aliases = {
                  for (final c in chapters)
                    jsonEncode([c.line, c.id]): TrackingResume.chapterKey(c),
                };
                final migrated = old
                    .map((key) => aliases[key] ?? key)
                    .toSet();
                if (center.data['episodeParts.${ref.key}'] != true) {
                  final previous = old.toSet();
                  for (final key in aliases.values) {
                    final separator = key.lastIndexOf(':');
                    if (separator > 0 && previous.contains(key.substring(0, separator))) {
                      migrated.add(key);
                    }
                  }
                }
                baselines[ref.key] = migrated.toList();
                center.data['baselines'] = baselines;
              }
              center.data['episodeParts.${ref.key}'] = true;
            }
            final added = center.compare(
              ref,
              lib.section == Section.video
                  ? TrackingResume.facts(chapters)
                  : chapters
                        .map(
                          (c) => SourceChapterFact(
                            jsonEncode([c.line, c.id]),
                            c.title,
                          ),
                        )
                        .toList(),
            );
            lib.syncChapters(
              item.itemId,
              lib.section == Section.video
                  ? TrackingResume.facts(chapters).length
                  : chapters.length,
              sourceId: item.sourceId,
            );
            if (added.isNotEmpty &&
                center.enabled('downloadUpdates') &&
                lib.section == Section.video) {
              final ids = added.map((c) => c.key).toSet();
              final indices = {
                for (final line in VideoEpisodeCatalog.group(chapters).values)
                  for (var i = 0; i < line.length; i++) line[i].id: i,
              };
              await VideoDownloadCenter.instance.enqueue(
                sourceId: item.sourceId,
                itemId: item.itemId,
                title: item.title,
                chapterIndices: indices,
                chapters: chapters
                    .where((c) => ids.remove(TrackingResume.chapterKey(c)))
                    .take(center.number('nextDownloads', 2).clamp(1, 5))
                    .toList(),
              );
            }
            if (added.isNotEmpty &&
                center.enabled('downloadUpdates') &&
                center.enabled('autoReadDownloads') &&
                lib.section != Section.video) {
              final progress = lib.progress(
                item.itemId,
                sourceId: item.sourceId,
              );
              final descriptors = await manager.list();
              final novel =
                  progress is NovelProgress ||
                  descriptors
                          .where((s) => s.id == item.sourceId)
                          .firstOrNull
                          ?.mediaKind ==
                      'novel';
              await ReadingOffline.prefetch(
                source: source,
                library: lib,
                target: ReadingTarget(
                  sourceId: item.sourceId,
                  itemId: item.itemId,
                  title: item.title,
                ),
                chapters: chapters,
                current: item.readChapterIndex,
                novel: novel,
                cancelled: cancelled,
              );
            }
            success++;
            fresh += added.length;
          } catch (_) {
            failed++;
          }
          await (wait?.call() ??
              Future<void>.delayed(const Duration(milliseconds: 350)));
        }
      }
      return TrackingReport(success, failed, fresh, false);
    } finally {
      busy = false;
    }
  }
}
