import '../../core/source/source_runtime_pins.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import 'comic_download.dart';

class ComicDownloadTask {
  ComicDownloadTask({
    required this.id,
    required this.section,
    required this.sourceId,
    required this.itemId,
    required this.title,
    this.chapters = const [],
    this.indices = const [],
    this.state = 'paused',
    this.error,
  });
  final String id, sourceId, itemId, title;
  final Section section;
  List<SourceChapter> chapters;
  List<int> indices;
  String state;
  String? error;
  int completed = 0;
  ComicDownloader? downloader;
  SectionImagePipeline? pipeline;
  bool get running => state == 'running';
  Map<String, Object?> toJson() => {
    'id': id,
    'section': section.id,
    'sourceId': sourceId,
    'itemId': itemId,
    'title': title,
    'indices': indices,
    'state': state,
    'completed': completed,
    'chapters': [
      for (final c in chapters) {'id': c.id, 'title': c.title, 'line': c.line},
    ],
    'failed': downloader?.failedChapterIndices ?? restoredFailures,
  };
  List<int> restoredFailures = [];
}

/// Owns pipelines and task manifests independently of detail-page lifetimes.
class ComicDownloadCenter extends ChangeNotifier {
  ComicDownloadCenter({this.directory, this.openSource, this.pipelineFactory});
  static final instance = ComicDownloadCenter();
  final Future<Directory> Function()? directory;
  final Future<DataSource?> Function(Section, String)? openSource;
  final SectionImagePipeline Function(DataSource, ReadingLibrary)?
  pipelineFactory;
  final tasks = <ComicDownloadTask>[];
  Future<void>? _boot;
  Future<void> _writes = Future.value();
  String? storageError;
  Future<File> _file() async => File(
    '${(await (directory?.call() ?? getApplicationSupportDirectory())).path}/comic_download_tasks.json',
  );
  Future<void> boot() => _boot ??= _restore();
  Future<void> _restore() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final data = await compute(jsonDecode, await file.readAsString()) as List;
      for (final row in data.whereType<Map>()) {
        final section = sectionFromId('${row['section']}');
        if (section == null ||
            row['id'] is! String ||
            row['sourceId'] is! String ||
            row['itemId'] is! String) {
          continue;
        }
        final task = ComicDownloadTask(
          id: row['id'],
          section: section,
          sourceId: row['sourceId'],
          itemId: row['itemId'],
          title: '${row['title'] ?? row['itemId']}',
          chapters: [
            for (final raw in (row['chapters'] as List? ?? []))
              ?SourceChapter.parse(raw),
          ],
          indices: (row['indices'] as List? ?? []).whereType<int>().toList(),
          state: row['state'] == 'done'
              ? 'done'
              : row['state'] == 'failed'
              ? 'failed'
              : 'paused',
        );
        task.restoredFailures = (row['failed'] as List? ?? [])
            .whereType<int>()
            .toList();
        task.completed = row['completed'] is int ? row['completed'] : 0;
        task.indices = task.indices
            .where((i) => i >= 0 && i < task.chapters.length)
            .toSet()
            .toList();
        if (task.indices.isEmpty) {
          continue;
        }
        final attached = tasks.where((t) => t.id == task.id).firstOrNull;
        if (attached == null) {
          tasks.add(task);
        } else if (!attached.running) {
          attached.chapters = task.chapters;
          attached.indices = task.indices;
          attached.state = task.state;
          attached.completed = task.completed;
          attached.restoredFailures = task.restoredFailures;
        }
      }
    } catch (_) {
      storageError = '下载任务记录读取失败，已有下载文件仍保留';
    }
    notifyListeners();
  }

  String key(Section section, String sourceId, String itemId) =>
      jsonEncode([section.id, sourceId, itemId]);
  ComicDownloader attach({
    required DataSource source,
    required ReadingLibrary library,
    required String itemId,
    required String title,
  }) {
    final id = key(library.section, source.id, itemId);
    final task =
        tasks.where((t) => t.id == id).firstOrNull ??
        ComicDownloadTask(
          id: id,
          section: library.section,
          sourceId: source.id,
          itemId: itemId,
          title: title,
        );
    if (!tasks.contains(task)) tasks.add(task);
    if (task.downloader != null &&
        !task.running &&
        task.downloader!.library != library) {
      task.downloader!.dispose();
      task.pipeline?.dispose();
      task.downloader = null;
    }
    return task.downloader ??= _create(task, source, library);
  }

  ComicDownloader _create(
    ComicDownloadTask task,
    DataSource source,
    ReadingLibrary library,
  ) {
    final pipeline =
        (pipelineFactory?.call(source, library) ??
              SectionImagePipeline(
                cacheDir: library.imageCacheDir,
                diskCache: false,
              ))
          ..bindSource(source)
          ..bindSession(source.section, source.id);
    task.pipeline = pipeline;
    final downloader = ComicDownloader(
      dataSource: source,
      itemId: task.itemId,
      works: task.title,
      folderKey:
          '${ReadingStore.safeFolderName(task.title)}-${sha256.convert(utf8.encode(task.id)).toString().substring(0, 10)}',
      library: library,
      fetch: pipeline.fetch,
      configureImageHeaders: pipeline.configureImageHeaders,
    );
    downloader.addListener(notifyListeners);
    return downloader;
  }

  Future<void> enqueue(
    ComicDownloader downloader,
    List<SourceChapter> chapters,
    List<int> indices,
  ) async {
    await boot();
    final task = tasks.firstWhere((t) => identical(t.downloader, downloader));
    if (task.running) return;
    task.chapters = List.of(chapters);
    task.indices = List.of(indices);
    await resume(task);
  }

  Future<void> resume(ComicDownloadTask task, {bool failedOnly = false}) async {
    if (task.running || task.downloader?.progress.running == true) return;
    task.error = null;
    task.state = 'running';
    notifyListeners();
    await _save();
    final releaseRuntime = SourceRuntimePins.retain(
      task.section,
      task.sourceId,
    );
    try {
      if (task.downloader == null) {
        final source =
            await (openSource?.call(task.section, task.sourceId) ??
                LumeSources.manager(task.section).open(task.sourceId));
        if (source == null) throw StateError('源不可用，请先恢复对应源');
        task.downloader = _create(
          task,
          source,
          await ReadingLibrary.open(task.section),
        );
      }
      final downloader = task.downloader!;
      if (task.state != 'running') return;
      final failures = List<int>.of(
        downloader.failedChapterIndices.isEmpty
            ? task.restoredFailures
            : downloader.failedChapterIndices,
      );
      await downloader.start(
        chapters: task.chapters,
        indices: failedOnly && failures.isNotEmpty ? failures : task.indices,
      );
      if (task.state == 'running') {
        task.state = downloader.progress.chapterFailed > 0 ? 'failed' : 'done';
      }
      task.completed = task.state == 'done'
          ? task.indices.length
          : downloader.progress.chapterDone;
      task.restoredFailures = List.of(downloader.failedChapterIndices);
    } catch (error) {
      task.state = 'failed';
      task.error = '$error';
    } finally {
      releaseRuntime();
      await _save();
      notifyListeners();
    }
  }

  Future<void> pause(ComicDownloadTask task) async {
    task.state = 'paused';
    task.downloader?.cancel();
    await _save();
    notifyListeners();
  }

  Future<void> remove(ComicDownloadTask task) async {
    await pause(task);
    // Existing image files are deliberately retained.
    if (task.downloader?.progress.running == true) return;
    task.downloader?.dispose();
    task.pipeline?.dispose();
    tasks.remove(task);
    await _save();
    notifyListeners();
  }

  Future<void> _save() {
    final snapshot = jsonEncode(
      tasks.where((t) => t.indices.isNotEmpty).map((t) => t.toJson()).toList(),
    );
    _writes = _writes.catchError((Object _) {}).then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(snapshot, flush: true);
        await temp.rename(file.path);
        storageError = null;
      } catch (_) {
        storageError = '下载任务未能保存，请检查可用空间';
        notifyListeners();
      }
    });
    return _writes;
  }

  Future<void> flush() => _writes;
}
