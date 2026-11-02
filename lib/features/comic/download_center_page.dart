import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/player/abstract_player.dart';
import '../../core/reading/reading.dart';
import '../../shared/widgets/glass_card.dart';
import '../download/local_download_export.dart';
import '../video/offline_video_server.dart';
import '../video/video_download_center.dart';
import '../video/video_player_page.dart';
import 'comic_download_center.dart';
import 'comic_reader_page.dart';
import 'offline_comic_source.dart';

class DownloadCenterPage extends StatefulWidget {
  const DownloadCenterPage({super.key, this.center, this.videoCenter});
  final ComicDownloadCenter? center;
  final VideoDownloadCenter? videoCenter;
  @override
  State<DownloadCenterPage> createState() => _DownloadCenterPageState();
}

class _DownloadCenterPageState extends State<DownloadCenterPage> {
  late final center = widget.center ?? ComicDownloadCenter.instance;
  late final videos = widget.videoCenter ?? VideoDownloadCenter.instance;
  late final signals = Listenable.merge([center, videos]);
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    center.boot();
    videos.boot();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmDelete(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除本地下载？'),
          content: Text('删除「$title」的任务和 App 内下载文件。已导出到“文件”的副本不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
  static String _size(num bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  Future<void> _storage(Directory directory) async {
    var bytes = 0;
    if (await directory.exists()) {
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File) bytes += await entry.length();
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('本地占用 ${_size(bytes)}')));
    }
  }

  Future<void> _play(VideoDownloadTask task) async {
    final file = videos.localFile(task);
    if (!await file.exists()) throw StateError('本地文件不存在，请重新下载');
    OfflineVideoServer? server;
    try {
      final uri = task.fileName.endsWith('.m3u8')
          ? (server = await OfflineVideoServer.open(
              Directory(videos.folder(task)),
            )).uri
          : file.uri;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => VideoPlayerPage(
            media: PlayerMedia(
              uri: uri,
              title: '${task.title} · ${task.chapterTitle}',
            ),
          ),
        ),
      );
    } finally {
      await server?.close();
    }
  }

  Future<void> _exportVideo(VideoDownloadTask task) async {
    final saved = task.fileName.endsWith('.m3u8')
        ? await LocalDownloadExport.directory(
            Directory(videos.folder(task)),
            entryPoint: task.fileName,
          )
        : await LocalDownloadExport.file(videos.localFile(task));
    if (saved && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存到本地文件')));
    }
  }

  Future<void> _read(ComicDownloadTask task) async {
    final library = await ReadingLibrary.open(task.section);
    final source = await OfflineComicSource.open(task, library);
    final chapters = await source.chapters(task.itemId);
    if (chapters.isEmpty) throw StateError('还没有可阅读的下载图片');
    if (!mounted) return;
    var index = 0;
    if (chapters.length > 1) {
      final picked = await showModalBottomSheet<int>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView.builder(
            itemCount: chapters.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(chapters[i].title),
              onTap: () => Navigator.pop(context, i),
            ),
          ),
        ),
      );
      if (picked == null) return;
      index = picked;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderPage(
          library: library,
          dataSource: source,
          target: ReadingTarget(
            sourceId: task.sourceId,
            itemId: task.itemId,
            title: task.title,
          ),
          chapters: chapters,
          initialChapterIndex: index,
          runtimeAvailable: true,
          pageBytes: (url) => File.fromUri(Uri.parse(url)).readAsBytes(),
        ),
      ),
    );
  }

  Future<void> _exportComic(ComicDownloadTask task) async {
    final library = await ReadingLibrary.open(task.section);
    final dir = await comicDownloadDirectory(task, library);
    if (!await dir.exists()) throw StateError('还没有下载文件');
    if (!mounted) return;
    final chapters =
        (await dir
              .list(followLinks: false)
              .where((e) => e is Directory)
              .cast<Directory>()
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    if (chapters.isEmpty) throw StateError('还没有下载章节');
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            ListTile(
              title: const Text('整部导出 ZIP'),
              onTap: () => Navigator.pop(context, dir.path),
            ),
            for (final chapter in chapters)
              ListTile(
                title: Text(p.basename(chapter.path)),
                subtitle: const Text('本章图片压缩包'),
                onTap: () => Navigator.pop(context, chapter.path),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    final saved = await LocalDownloadExport.directory(Directory(selected));
    if (saved && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存到本地文件')));
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '下载中心',
    child: ListenableBuilder(
      listenable: signals,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('下载保存在本机，可离线打开或保存到“文件”。退出详情页后任务继续；系统挂起时传输可能暂停。'),
          if (_busy) const LinearProgressIndicator(),
          if (center.storageError != null) Text(center.storageError!),
          if (videos.storageError != null) Text(videos.storageError!),
          if (videos.tasks.isEmpty &&
              !center.tasks.any((t) => t.indices.isNotEmpty))
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('暂无下载任务，请在视频或漫画详情页添加'),
            ),
          if (videos.tasks.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('视频'),
            ),
          for (final task in videos.tasks.reversed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${task.title} · ${task.chapterTitle}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${switch (task.state) {
                        'running' => '下载中',
                        'queued' => '等待中',
                        'done' => '已完成',
                        'failed' => '下载失败',
                        _ => '已暂停',
                      }} · ${_size(task.bytes)}${task.totalBytes > 0 ? ' / ${_size(task.totalBytes)}' : ''}${task.total > 0 ? ' · ${task.completed}/${task.total} 分片' : ''}',
                    ),
                    if (task.running) ...[
                      LinearProgressIndicator(value: task.progress),
                      Text('${_size(task.bytesPerSecond)}/s'),
                    ],
                    if (task.error != null) Text(task.error!),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (task.running || task.state == 'queued')
                          TextButton(
                            onPressed: () => videos.pause(task),
                            child: const Text('暂停'),
                          )
                        else if (task.state != 'done')
                          TextButton(
                            onPressed: () => videos.resume(task),
                            child: Text(task.state == 'failed' ? '重试' : '继续'),
                          ),
                        if (task.state == 'done') ...[
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() => _play(task)),
                            child: const Text('离线播放'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() => _exportVideo(task)),
                            child: const Text('保存到本地文件'),
                          ),
                        ],
                        if (!task.running)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(
                                    () => _storage(
                                      Directory(videos.folder(task)),
                                    ),
                                  ),
                            child: const Text('占用空间'),
                          ),
                        if (!task.running)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() async {
                                    if (await _confirmDelete(
                                      '${task.title} · ${task.chapterTitle}',
                                    )) {
                                      await videos.remove(
                                        task,
                                        deleteFiles: true,
                                      );
                                    }
                                  }),
                            child: const Text('删除下载'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (center.tasks.any((t) => t.indices.isNotEmpty))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('漫画 / 图片'),
            ),
          for (final task in center.tasks.reversed.where(
            (t) => t.indices.isNotEmpty,
          ))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${switch (task.state) {
                        'running' => '下载中',
                        'done' => '已完成',
                        'failed' => '有失败，可重试',
                        _ => '已暂停',
                      }} · ${task.running ? task.downloader?.progress.chapterDone ?? 0 : task.completed}/${task.indices.length} 章',
                    ),
                    if (task.running)
                      LinearProgressIndicator(
                        value: task.downloader?.progress.fraction,
                      ),
                    if (task.running)
                      Text(
                        '${_size(task.downloader?.progress.downloadedBytes ?? 0)} · ${_size(task.downloader?.progress.bytesPerSecond ?? 0)}/s',
                      ),
                    if (task.error != null) Text(task.error!),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (task.running)
                          TextButton(
                            onPressed: () => center.pause(task),
                            child: const Text('暂停'),
                          )
                        else
                          TextButton(
                            onPressed: task.downloader?.progress.running == true
                                ? null
                                : () => center.resume(task),
                            child: Text(task.state == 'done' ? '检查补下' : '继续'),
                          ),
                        if (task.state == 'failed')
                          TextButton(
                            onPressed: () =>
                                center.resume(task, failedOnly: true),
                            child: const Text('重试失败章节'),
                          ),
                        if (!task.running &&
                            task.downloader?.progress.running != true) ...[
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() => _read(task)),
                            child: const Text('离线阅读'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() => _exportComic(task)),
                            child: const Text('保存到本地文件'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : () => center.remove(task),
                            child: const Text('移除任务'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _perform(() async {
                                    if (!await _confirmDelete(task.title)) {
                                      return;
                                    }
                                    final library = await ReadingLibrary.open(
                                      task.section,
                                    );
                                    final dir = await comicDownloadDirectory(
                                      task,
                                      library,
                                    );
                                    if (!p.isWithin(
                                      library.exportDir,
                                      dir.absolute.path,
                                    )) {
                                      throw StateError('下载目录无效');
                                    }
                                    await center.remove(task);
                                    if (await dir.exists()) {
                                      await dir.delete(recursive: true);
                                    }
                                  }),
                            child: const Text('删除下载'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
