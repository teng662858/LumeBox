import '../../core/experience/content_center.dart';
import '../../core/cat/cat_data_source.dart';
import '../../core/cat/cat_service.dart';
import '../../core/reading/reading.dart';
import '../../core/experience/offline_policy.dart';
import '../../core/source/source_runtime_pins.dart';
import '../../core/media/playback_focus.dart';
import '../../core/net/lume_net.dart';
import '../../core/net/lume_http.dart';
import '../../core/net/http_header_scope.dart';
import '../../core/net/media_range_response.dart' show mediaContentRange;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/session/section.dart';
import '../../core/security/local_cipher.dart';
import '../../core/source/source.dart';
import '../../core/util/sensitive_data.dart';
import 'source_playback.dart';
import 'direct_video_source.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/playback_diagnostics.dart';
import '../../core/player/apple_hls_fragments.dart';
import '../../core/player/hls_ad_filter.dart';
import '../../core/player/hls_attributes.dart';
import '../../core/player/hls_variants.dart';
import '../../core/player/video_disk_cache.dart';
import 'video_download_merger.dart';
import 'offline_video_server.dart';

class DownloadedVideoPlayback {
  DownloadedVideoPlayback(this.uri, [this.server, this._onClose]);
  final Uri uri;
  final OfflineVideoServer? server;
  final Future<void> Function()? _onClose;
  Future<void>? _closing;
  PlayerMedia media(String title) =>
      PlayerMedia(uri: uri, title: title, isDownloaded: true);
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await server?.close();
    } finally {
      await _onClose?.call();
    }
  }
}

class VideoDownloadTask {
  VideoDownloadTask({
    required this.id,
    required this.sourceId,
    required this.itemId,
    required this.chapterId,
    required this.title,
    required this.chapterTitle,
    this.section = Section.video,
    this.state = 'paused',
    this.bytes = 0,
    this.totalBytes = 0,
    this.completed = 0,
    this.total = 0,
    this.fileName = '',
    this.chapterIndex = 0,
    this.line = '',
    this.error,
    this.encryptedCapture,
  });
  final String id, sourceId, itemId, chapterId, title, chapterTitle;
  final Section section;
  SourceManager get sourceManager => section == Section.cat
      ? CatAggregateSourceManager(CatService.instance)
      : LumeSources.manager(section);
  int chapterIndex;
  final String line;
  String state, fileName;
  String? error;
  String? encryptedCapture;
  int bytes, totalBytes, completed, total;
  double bytesPerSecond = 0;
  bool get running => state == 'running' || state == 'merging';
  bool get hasLocalPlaylist => fileName.endsWith('.m3u8');
  bool get canPlayOffline =>
      fileName.isNotEmpty &&
      (state == 'done' ||
          hasLocalPlaylist && (state == 'paused' || state == 'merge_failed'));
  double? get progress => total > 0
      ? completed / total
      : totalBytes > 0
      ? bytes / totalBytes
      : null;
  Map<String, Object?> toJson() => {
    'id': id,
    'section': section.id,
    'sourceId': sourceId,
    'itemId': itemId,
    'chapterId': chapterId,
    'title': title,
    'chapterTitle': chapterTitle,
    'chapterIndex': chapterIndex,
    if (line.isNotEmpty) 'line': line,
    'state': state,
    'bytes': bytes,
    'totalBytes': totalBytes,
    'completed': completed,
    'total': total,
    'fileName': fileName,
    if (encryptedCapture != null) 'capture': encryptedCapture,
  };
}

/// Page-independent VOD downloads. Web captures use device-bound encryption.
class VideoDownloadCenter extends ChangeNotifier {
  VideoDownloadCenter({
    this.directory,
    this.resolve,
    this.merge,
    this.cancelMerge,
    this.playbackActive,
  });
  static final instance = VideoDownloadCenter();
  final Future<Directory> Function()? directory;
  final Future<VideoContent> Function(VideoDownloadTask)? resolve;
  final Future<void> Function(Directory, File, String)? merge;
  final Future<void> Function(String)? cancelMerge;
  final bool Function()? playbackActive;
  bool get _yieldToPlayback =>
      playbackActive?.call() ?? PlaybackFocus.isPlaying;
  final _progressWatch = Stopwatch()..start();
  void _notifyProgress() {
    if (_progressWatch.elapsedMilliseconds < 250) return;
    _progressWatch.reset();
    notifyListeners();
  }

  final _merger = VideoDownloadMerger();
  final tasks = <VideoDownloadTask>[];
  final _playlistReaders = <VideoDownloadTask, int>{};
  final _pendingCleanup = <VideoDownloadTask>{};
  Future<void>? _boot;
  Future<void> _writes = Future.value();
  bool _draining = false;
  HttpClient? _client;
  VideoDownloadTask? _active;
  Completer<void>? _activeFinished;
  String? storageError;
  String _proxy = '';
  final _speedWatch = Stopwatch();
  int _speedBytes = 0;
  late Directory root;
  static String identity(String source, String item, String chapter,
      {Section section = Section.video}) => sha256
      .convert(utf8.encode(jsonEncode([if (section != Section.video) section.id, source, item, chapter])))
      .toString();
  bool get needsRestore => _boot == null && storageError != null;
  Future<void> boot() => _boot ??= _restore().onError((Object error, StackTrace stack) {
    _boot = null;
    storageError = '下载任务记录读取失败，已下载文件仍保留';
    notifyListeners();
    Error.throwWithStackTrace(error, stack);
  });
  Future<void> _restore() async {
    root = Directory(
      p.join(
        (await (directory?.call() ?? getApplicationSupportDirectory())).path,
        'video_downloads',
      ),
    );
    await root.create(recursive: true);
    final manifest = File(p.join(root.path, 'tasks.json'));
    String? contents;
    try {
      contents = await manifest.readAsString();
    } on PathNotFoundException {
      // A new download library has no manifest yet.
    }
    final restored = <VideoDownloadTask>[];
    var migrated = false;
    if (contents != null) {
      final rows = jsonDecode(contents);
      if (rows is! List) throw const FormatException('下载任务清单格式无效');
      for (final m in rows.whereType<Map>()) {
        final source = m['sourceId'];
        var item = m['itemId'];
        var chapter = m['chapterId'];
        if (source is! String || item is! String || chapter is! String) {
          continue;
        }
        // Older queues stored Cat site IDs but used the video folder hash.
        final legacyCat = CatSite.legacyMediaSection(source) != null;
        final section = m['section'] == null
            ? (legacyCat ? Section.cat : Section.video)
            : sectionFromId('${m['section']}');
        if (section == null) continue;
        var id = m['id'];
        final legacyFolder = section == Section.cat && legacyCat &&
            id == identity(source, item, chapter);
        if (id is! String ||
            (!legacyFolder && id != identity(source, item, chapter, section: section))) {
          continue;
        }
        final fileName = m['fileName'] is String ? m['fileName'] as String : '';
        if (fileName.isNotEmpty &&
            (fileName.contains('\u0000') ||
                p.isAbsolute(fileName) ||
                p.split(fileName).contains('..'))) {
          continue;
        }
        int counter(String key) {
          final value = m[key];
          return value is num && value.isFinite && value >= 0
              ? value.toInt()
              : 0;
        }

        var capture = m['capture'] is String ? m['capture'] as String : null;
        if (section == Section.video && source.startsWith('web-') &&
            item == 'captured-video' && fileName.isEmpty && capture == null) {
          final uri = Uri.tryParse(chapter);
          if (uri != null && ['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty) {
            final newItem = DirectVideoSource.captureItemId('', uri);
            const newChapter = 'web-episode-0';
            final newId = identity(source, newItem, newChapter);
            try {
              final cipher = await LocalCipher.open();
              capture = cipher.seal(
                jsonEncode({'url': chapter, 'headers': {}}),
                context: 'video-download:$newId',
              );
              item = newItem;
              chapter = newChapter;
              id = newId;
              migrated = true;
            } catch (_) {
              // Keep the existing entry if the device key is unavailable.
            }
          }
        }
        final task = VideoDownloadTask(
          id: id,
          section: section,
          sourceId: source,
          itemId: item,
          chapterId: chapter,
          title: '${m['title'] ?? item}',
          chapterTitle: '${m['chapterTitle'] ?? chapter}',
          chapterIndex: counter('chapterIndex'),
          line: m['line'] is String ? m['line'] as String : '',
          state: ['done', 'merge_failed'].contains(m['state'])
              ? '${m['state']}'
              : 'paused',
          bytes: counter('bytes'),
          totalBytes: counter('totalBytes'),
          completed: counter('completed'),
          total: counter('total'),
          fileName: fileName,
          encryptedCapture: capture,
        );
        if ((fileName.isNotEmpty || task.state != 'paused') &&
            await checkedLocalFile(task, inspectLegacy: true) == null) {
          task.fileName = '';
          task.state = 'paused';
          task.bytes = task.totalBytes = task.completed = task.total = 0;
          task.error = '本地视频文件缺失或不完整，可重新下载';
        }
        restored.add(task);
      }
    }
    tasks.addAll(restored);
    storageError = null;
    if (migrated) await _save();
    notifyListeners();
  }

  String folder(VideoDownloadTask task) => p.join(root.path, task.id);
  File localFile(VideoDownloadTask task) =>
      File(p.join(folder(task), task.fileName));

  Future<File?> checkedLocalFile(VideoDownloadTask task, {bool inspectLegacy = false}) async {
    if (task.fileName.isEmpty) return null;
    final file = localFile(task);
    // HLS counts bytes across the package, not just the entry playlist.
    final expected = task.state == 'done' && !task.hasLocalPlaylist ? task.bytes : 0;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size == 0 ||
        expected > 0 && stat.size != expected) {
      return null;
    }
    // Older downloads could publish a DASH manifest as a progressive movie.
    if (inspectLegacy && task.fileName.startsWith('media.')) {
      try {
        if (await VideoDiskCache.detectFileFormat(file) == '.mpd') return null;
      } on FileSystemException {
        return null;
      }
    }
    return file;
  }

  Future<bool> _hasMergeInputs(VideoDownloadTask task) {
    final playlist = localFile(task);
    return OfflineVideoServer.isCompletePlaylist(playlist.parent, p.basename(playlist.path));
  }

  VideoDownloadTask? _find(Section section, String source, String item, String chapter) =>
      tasks.where((t) => t.section == section && t.sourceId == source &&
          t.itemId == item && t.chapterId == chapter).firstOrNull;

  Future<File?> completedFile(
    String sourceId,
    String itemId,
    String chapterId, {
    Section section = Section.video,
  }) async {
    await boot();
    final task = _find(section, sourceId, itemId, chapterId);
    if (task == null || !task.canPlayOffline) return null;
    return checkedLocalFile(task);
  }

  Future<DownloadedVideoPlayback?> completedPlayback(
    String sourceId,
    String itemId,
    String chapterId, {
    Section section = Section.video,
  }) async {
    await boot();
    final task = _find(section, sourceId, itemId, chapterId);
    if (task == null ||
        !(task.canPlayOffline || task.hasLocalPlaylist && task.state == 'merging')) {
      return null;
    }
    if (!task.hasLocalPlaylist) {
      final file = await checkedLocalFile(task);
      return file == null ? null : DownloadedVideoPlayback(file.uri);
    }
    // Retain the input before awaiting I/O: the merger can publish its MP4
    // and start cleaning the old playlist while the loopback server binds.
    _playlistReaders.update(task, (n) => n + 1, ifAbsent: () => 1);
    var opened = false;
    try {
      final file = await checkedLocalFile(task);
      if (file == null) return null;
      final server = await OfflineVideoServer.open(file.parent);
      opened = true;
      return DownloadedVideoPlayback(
        server.uri.resolve(Uri.encodeComponent(p.basename(file.path))),
        server,
        () => _releasePlaylist(task),
      );
    } finally {
      if (!opened) await _releasePlaylist(task);
    }
  }

  Future<void> _releasePlaylist(VideoDownloadTask task) async {
    final remaining = _playlistReaders[task]! - 1;
    if (remaining > 0) {
      _playlistReaders[task] = remaining;
      return;
    }
    _playlistReaders.remove(task);
    if (_pendingCleanup.remove(task) && tasks.contains(task) && task.fileName == 'merged.mp4') {
      await _cleanMergedInputs(task);
    }
  }

  /// Online-capable entry points may continue with the source on storage errors.
  Future<DownloadedVideoPlayback?> playbackIfAvailable(
    String sourceId,
    String itemId,
    String chapterId, {
    Section section = Section.video,
  }) async {
    try {
      return await completedPlayback(sourceId, itemId, chapterId, section: section);
    } catch (_) {
      PlaybackDiagnostics.record('offline-lookup-failed', source: sourceId);
      return null;
    }
  }

  Future<void> enqueue({
    Section section = Section.video,
    required String sourceId,
    required String itemId,
    required String title,
    required List<SourceChapter> chapters,
    Map<String, int> chapterIndices = const {},
    Map<String, VideoContent> captures = const {},
  }) async {
    await boot();
    final cipher = captures.isEmpty ? null : await LocalCipher.open();
    for (final chapter in chapters) {
      final id = identity(sourceId, itemId, chapter.id, section: section);
      final capture = captures[chapter.id];
      final encrypted = capture == null ? null : cipher!.seal(
        jsonEncode({'url': capture.url.toString(), 'headers': capture.headers}),
        context: 'video-download:$id',
      );
      final existing = _find(section, sourceId, itemId, chapter.id);
      if (existing != null) {
        if (encrypted != null) existing.encryptedCapture = encrypted;
        existing.chapterIndex = chapterIndices[chapter.id] ?? existing.chapterIndex;
        final needsDownload = existing.state != 'done' ||
            (existing.hasLocalPlaylist
                ? !await _hasMergeInputs(existing)
                : await checkedLocalFile(existing) == null);
        if (!existing.running && needsDownload && tasks.contains(existing)) {
          existing.state = 'queued';
        }
        continue;
      }
      tasks.add(
        VideoDownloadTask(
          id: id,
          encryptedCapture: encrypted,
          section: section,
          sourceId: sourceId,
          itemId: itemId,
          chapterId: chapter.id,
          title: title,
          chapterTitle: chapter.title,
          chapterIndex: chapterIndices[chapter.id] ?? 0,
          line: chapter.line,
          state: 'queued',
        ),
      );
    }
    await _save();
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> resume(VideoDownloadTask task) async {
    await boot();
    if (task.running || task.state == 'queued') return;
    // A cancelled writer must finish before a retry can reuse its files.
    while (identical(_active, task)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    task.state = 'queued';
    task.error = null;
    await _save();
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> pause(VideoDownloadTask task) async {
    final merging = task.state == 'merging';
    task.state = 'paused';
    if (identical(_active, task)) _client?.close(force: true);
    if (merging) await (cancelMerge ?? _merger.cancel)(task.id);
    await _save();
    notifyListeners();
  }

  Future<void> remove(
    VideoDownloadTask task, {
    bool deleteFiles = false,
  }) async {
    await pause(task);
    // Wait for the stream writer before deleting its private directory.
    while (identical(_active, task)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (deleteFiles) {
      final target = Directory(folder(task));
      if (!p.isWithin(root.absolute.path, target.absolute.path)) {
        throw StateError('下载目录无效');
      }
      if (await target.exists()) await target.delete(recursive: true);
    }
    tasks.remove(task);
    await _save();
    notifyListeners();
  }

  Future<int> pruneWatched() async {
    await boot();
    if (!ContentCenter.instance.enabled('cleanupWatched')) return 0;
    var removed = 0;
    for (final task in List<VideoDownloadTask>.of(tasks)) {
      if (task.state != 'done' || identical(_active, task)) continue;
      final library = await ReadingLibrary.open(task.section);
      final progress = library.videoEpisodeProgress(
        task.itemId,
        task.chapterId,
        sourceId: task.sourceId,
      );
      if (progress?.isFinished != true) continue;
      final file = localFile(task);
      if (!await file.exists() ||
          DateTime.now().difference(await file.lastModified()) <
              const Duration(days: 7)) {
        continue;
      }
      await remove(task, deleteFiles: true);
      removed++;
    }
    return removed;
  }

  Future<void> _policyCheckpoint(VideoDownloadTask task) async {
    _check(task);
    final reason = await OfflinePolicy.blocked();
    _check(task);
    if (reason != null) throw OfflinePolicyPaused(reason);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      await pruneWatched();
      while (true) {
        final task = tasks.where((t) => t.state == 'queued').firstOrNull;
        if (task == null) break;
        final localMerge = task.hasLocalPlaylist &&
            (await _hasMergeInputs(task) || await _isMp4(File(p.join(folder(task), 'merged.mp4'))));
        final blocked = await OfflinePolicy.blocked(needsNetwork: !localMerge);
        if (task.state != 'queued') continue;
        if (!localMerge) task.fileName = '';
        if (blocked != null) {
          task.state = 'paused';
          task.error = blocked;
          await _save();
          notifyListeners();
          continue;
        }
        _active = task;
        final finished = _activeFinished = Completer<void>();
        task.state = 'running';
        task.error = null;
        task.completed = 0;
        task.total = 0;
        _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 25)
          ..autoUncompress = false;
        await _save();
        notifyListeners();
        final releaseRuntime = SourceRuntimePins.retain(
          task.section,
          task.sourceId,
        );
        try {
          _check(task);
          if (localMerge) {
            await _mergeDownloaded(task);
            continue;
          }
          _check(task);
          _proxy = LumeNet.settings.proxy;
          final content = await (resolve?.call(task) ?? _resolve(task)).timeout(
            const Duration(seconds: 45),
          );
          _check(task);
          final uri = SourcePlayback.contentAddress(content);
          if (uri == null || !['http', 'https'].contains(uri.scheme)) {
            throw StateError('该内容没有可下载的网络视频地址');
          }
          final dir = Directory(folder(task));
          await dir.create(recursive: true);
          if (_proxy.trim().isNotEmpty) {
            final proxy = Uri.tryParse(_proxy);
            if (proxy == null ||
                !['http', 'https'].contains(proxy.scheme) ||
                proxy.host.isEmpty) {
              throw StateError('下载仅支持 HTTP 代理；SOCKS 请通过系统 VPN 使用');
            }
            final port = proxy.hasPort
                ? proxy.port
                : proxy.scheme == 'https'
                ? 443
                : 80;
            _client!.findProxy = (_) => 'PROXY ${proxy.host}:$port';
            if (proxy.userInfo.isNotEmpty) {
              final parts = proxy.userInfo.split(':');
              _client!.authenticateProxy =
                  (host, targetPort, scheme, realm) async {
                    if (host != proxy.host || targetPort != port) return false;
                    _client!.addProxyCredentials(
                      host,
                      targetPort,
                      realm ?? '',
                      HttpClientBasicCredentials(
                        Uri.decodeComponent(parts.first),
                        Uri.decodeComponent(parts.skip(1).join(':')),
                      ),
                    );
                    return true;
                  };
            }
          }
          _speedWatch
            ..reset()
            ..start();
          _speedBytes = 0;
          await _policyCheckpoint(task);
          await _download(task, uri, _requestHeaders(content.headers));
          _check(task);
          if (task.hasLocalPlaylist) {
            await _save();
            await _mergeDownloaded(task);
          }
          task.state = 'done';
        } catch (error) {
          if (task.running) {
            task.state = error is OfflinePolicyPaused
                ? 'paused'
                : task.hasLocalPlaylist
                ? 'merge_failed'
                : 'failed';
            task.error = SensitiveData.redact('$error')
                .replaceAll(RegExp(r'https?://[^\s]+'), '[地址]');
          }
        } finally {
          releaseRuntime();
          _client?.close(force: true);
          _client = null;
          _active = null;
          _activeFinished = null;
          task.bytesPerSecond = 0;
          await _save();
          finished.complete();
          notifyListeners();
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<VideoContent> _resolve(VideoDownloadTask task) async {
    final capture = task.encryptedCapture;
    if (capture != null) {
      if (!capture.startsWith(LocalCipher.prefix)) {
        throw const FormatException('网页下载信息损坏，请回到网页重新添加');
      }
      final cipher = await LocalCipher.open();
      final data = jsonDecode(cipher.reveal(capture, context: 'video-download:${task.id}')) as Map;
      return VideoContent(
        url: Uri.parse(data['url'] as String),
        headers: Map<String, String>.from(data['headers'] as Map),
      );
    }
    final manager = task.sourceManager;
    final source = await manager.open(task.sourceId);
    if (source == null) throw StateError('源不可用，请恢复对应源后继续');
    final descriptor = (await manager.list()).where((d) => d.id == task.sourceId).firstOrNull;
    if (descriptor != null) {
      _proxy = descriptor.network.mergedWith(LumeNet.settings).proxy;
    }
    final result = await source.content(
      itemId: task.itemId,
      chapterId: task.chapterId,
    );
    if (result is! VideoContent) throw StateError('该内容仅支持网页播放，无法下载');
    return VideoContent(
      url: SourcePlayback.contentAddress(result) ?? result.url,
      headers: SourcePlayback.contentHeaders(result, source: source),
    );
  }

  void _check(VideoDownloadTask task) {
    if (!task.running) throw const _Paused();
  }

  Future<void> _mergeDownloaded(VideoDownloadTask task) async {
    _check(task);
    task.state = 'merging';
    task.bytesPerSecond = 0;
    await _save();
    notifyListeners();
    final dir = Directory(folder(task));
    final part = File(p.join(dir.path, 'merged.mp4.part'));
    final output = File(p.join(dir.path, 'merged.mp4'));
    try {
      // A crash after atomic rename but before manifest update can reuse the result.
      if (!await _isMp4(output)) {
        if (await part.exists()) await part.delete();
        _check(task);
        await (merge ?? _merger.merge)(dir, part, task.id);
        _check(task);
        if (!await _isMp4(part)) throw StateError('合并未生成有效的 MP4 文件');
        await part.rename(output.path);
      }
      final length = await output.length();
      _check(task);
      task.fileName = 'merged.mp4';
      task.bytes = task.totalBytes = length;
      task.completed = task.total = 0;
      task.state = 'done';
      await _save();
      // Persist the committed MP4 before removing any original media.
      if (storageError == null) {
        if (_playlistReaders.containsKey(task)) {
          _pendingCleanup.add(task);
        } else {
          await _cleanMergedInputs(task);
        }
      }
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> _cleanMergedInputs(VideoDownloadTask task) async {
    final output = File(p.join(folder(task), 'merged.mp4'));
    try {
      if (!await output.exists()) return;
      await for (final entry in output.parent.list(followLinks: false)) {
        if (p.equals(entry.path, output.path)) continue;
        try {
          await entry.delete(recursive: true);
        } on FileSystemException {
          task.error = 'MP4 已合并，部分临时文件未能清理';
        }
      }
    } on FileSystemException {
      task.error = 'MP4 已合并，部分临时文件未能清理';
    }
  }

  static Future<bool> _isMp4(File file) async {
    RandomAccessFile? input;
    try {
      input = await file.open();
      // Check the remuxer's top-level boxes before deleting the source HLS.
      // Seek over payloads so a large movie never needs to be read into memory.
      final length = await input.length();
      var offset = 0, hasMovie = false, hasMedia = false;
      while (offset < length) {
        await input.setPosition(offset);
        final bytes = await input.read(8);
        if (bytes.length != 8) return false;
        final type = String.fromCharCodes(bytes, 4, 8);
        if (offset == 0 && type != 'ftyp') return false;
        var size = ByteData.sublistView(bytes).getUint32(0);
        var headerSize = 8;
        if (size == 1) {
          final extended = await input.read(8);
          if (extended.length != 8) return false;
          size = ByteData.sublistView(extended).getUint64(0);
          headerSize = 16;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < headerSize || size > length - offset) return false;
        if (type == 'moov' && size > headerSize) hasMovie = true;
        if (type == 'mdat' && size > headerSize) hasMedia = true;
        offset += size;
      }
      return hasMovie && hasMedia;
    } on FileSystemException {
      return false;
    } finally {
      await input?.close();
    }
  }

  Map<String, String> _requestHeaders(Map<String, String> headers) {
    final result = {
      for (final e in headers.entries)
        if (!isMediaTransportHeader(e.key)) e.key.toLowerCase(): e.value,
    };
    result.putIfAbsent('user-agent', () => LumeNet.settings.userAgent.isNotEmpty
        ? LumeNet.settings.userAgent : LumeHttp.defaultUserAgent);
    result['accept-encoding'] = 'identity';
    return result;
  }

  String _headerHash(Map<String, String> headers) {
    final entries = headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256.convert(utf8.encode(jsonEncode(Map.fromEntries(entries)))).toString();
  }

  Future<(HttpClientResponse, Uri)> _open(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> scopedHeaders, {
    Map<String, String> extra = const {},
  }) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      _check(task);
      if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
        throw StateError('下载地址协议无效');
      }
      final req = await _client!.getUrl(uri);
      req.followRedirects = false;
      // Each fetch owns its headers. Range continuations and child manifests
      // inherit any restrictions introduced by a redirect in this branch.
      if (uri.origin != origin.origin) {
        scopedHeaders.removeWhere((name, _) => isOriginBoundHttpHeader(name));
      }
      for (final e in scopedHeaders.entries) {
        req.headers.set(e.key, e.value);
      }
      for (final e in extra.entries) {
        req.headers.set(e.key, e.value);
      }
      final response = await req.close().timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.listen(null).cancel();
        if (location == null) throw StateError('下载重定向缺少地址');
        uri = uri.resolve(location);
        continue;
      }
      return (response, uri);
    }
    throw StateError('下载重定向过多');
  }

  Future<(HttpClientResponse, Uri)> _openFromStart(
    VideoDownloadTask task, Uri uri, Uri origin, Map<String, String> headers,
  ) async {
    final (response, finalUri) = await _open(task, uri, origin, headers);
    if (!const [400, 403, 405, 416].contains(response.statusCode)) return (response, finalUri);
    await response.listen(null).cancel();
    return _open(task, finalUri, origin, headers, extra: const {'Range': 'bytes=0-'});
  }

  Stream<List<int>> _downloadBody(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    HttpClientResponse response,
    int offset, {
    int? expectedLength,
    String? expectedValidator,
    String? expectedDate,
    void Function(String, String?)? onValidator,
    void Function(int)? onLength,
  }) {
    final encoding = _encoding(response);
    final wire = _wireBody(
      task,
      uri,
      origin,
      headers,
      response,
      offset,
      expectedLength: expectedLength,
      expectedValidator: expectedValidator,
      expectedDate: expectedDate,
      onValidator: onValidator,
      onLength: encoding == 'identity' ? onLength : null,
    );
    if (encoding == 'identity') return wire;
    if (offset != 0) throw StateError('压缩响应无法从中间解码');
    onLength?.call(0);
    return switch (encoding) {
      'gzip' => wire.transform(gzip.decoder),
      'deflate' => wire.transform(zlib.decoder),
      _ => throw StateError('不支持的下载内容编码：$encoding'),
    };
  }

  String _encoding(HttpClientResponse response) =>
      response.headers.value('content-encoding')?.trim().toLowerCase() ??
      'identity';

  String? _validator(HttpClientResponse response) =>
      response.headers.value('etag') ?? response.headers.value('last-modified');

  // Weak ETags can identify byte-different encodings of the same content.
  // Compare them for changes, but never use them as an If-Range precondition.
  String? _strongTag(Object? validator) =>
      validator is String && validator.startsWith('"') && validator.endsWith('"')
          ? validator
          : null;

  String? _ifRange(Object? validator, Object? responseDate) {
    final tag = _strongTag(validator);
    if (tag != null) return tag;
    if (validator is! String || validator.startsWith('W/') || responseDate is! String) {
      return null;
    }
    try {
      // Allow clock skew when deciding whether the last-modified second is
      // distinguishable from the response time (RFC 9110 section 8.8.2.2).
      final age = HttpDate.parse(responseDate).difference(HttpDate.parse(validator));
      return age >= const Duration(minutes: 1) ? validator : null;
    } on HttpException {
      return null;
    }
  }

  String _addressHash(Uri uri) =>
      sha256.convert(utf8.encode(uri.removeFragment().toString())).toString();

  bool _sameStrongTag(Object? previous, HttpClientResponse response) =>
      _strongTag(previous) != null &&
      previous == response.headers.value('etag');

  // Byte ranges and validators refer to the encoded HTTP representation.
  Stream<List<int>> _wireBody(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    HttpClientResponse response,
    int offset, {
    int? expectedLength,
    String? expectedValidator,
    String? expectedDate,
    void Function(String, String?)? onValidator,
    void Function(int)? onLength,
  }) async* {
    if (response.statusCode == 200) {
      onLength?.call(response.contentLength < 0 ? 0 : response.contentLength);
      yield* response.timeout(const Duration(seconds: 45));
      return;
    }
    var validator = expectedValidator ?? _validator(response);
    var validatorDate = expectedValidator == null
        ? response.headers.value('date')
        : expectedDate;
    final encoding = _encoding(response);
    var total = expectedLength;
    while (true) {
      final nextValidator = _validator(response);
      if (validator != null &&
          nextValidator != null &&
          nextValidator != validator) {
        await response.listen(null).cancel();
        throw StateError('下载中途文件已更换，请重试');
      }
      if (response.statusCode == 416 &&
          response.headers.value('content-range') == 'bytes */$offset' &&
          (total == null || total == offset)) {
        await response.listen(null).cancel();
        onLength?.call(offset);
        return;
      }
      if (response.statusCode != 206) throw StateError('服务器未继续返回分段内容，请重试');
      if (_encoding(response) != encoding) throw StateError('下载中途内容编码发生变化');
      final range = mediaContentRange.firstMatch(response.headers.value('content-range') ?? '');
      final start = int.tryParse(range?[1] ?? '');
      final end = int.tryParse(range?[2] ?? '');
      final length = int.tryParse(range?[3] ?? '');
      if (start != offset ||
          end == null ||
          end < offset ||
          (range?[3] != '*' && length == null) ||
          (length != null && total != null && total != length)) {
        throw StateError('服务器续传范围不匹配，请重试');
      }
      total ??= length;
      if ((total != null && end >= total) ||
          (response.contentLength >= 0 &&
              response.contentLength != end - offset + 1)) {
        throw StateError('服务器返回了无效的分段长度');
      }
      if (validator == null && nextValidator != null) {
        validator = nextValidator;
        validatorDate = response.headers.value('date');
        onValidator?.call(nextValidator, validatorDate);
      }
      onLength?.call(total ?? 0);
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        _check(task);
        if (chunk.length > end - offset + 1) throw StateError('分段响应超过声明长度');
        offset += chunk.length;
        yield chunk;
      }
      if (offset - 1 != end) throw StateError('文件分段尚未下载完整');
      if (offset == total) return;
      await _policyCheckpoint(task);
      final next = await _open(
        task,
        uri,
        origin,
        headers,
        extra: {'Range': 'bytes=$offset-', 'If-Range': ?_ifRange(validator, validatorDate)},
      );
      final previousUri = uri;
      (response, uri) = next;
      if (uri.removeFragment() != previousUri.removeFragment()) {
        await response.listen(null).cancel();
        throw StateError('下载中途文件地址发生变化，请重试');
      }
    }
  }

  Future<void> _publishMedia(
    VideoDownloadTask task,
    File partial,
    Uri uri,
    Uri resolved,
  ) async {
    const known = {'.mp4', '.mkv', '.webm', '.m4v', '.mov', '.ts', '.avi', '.flv', '.asf', '.wmv'};
    final extension = [resolved, uri]
        .map((u) => p.extension(u.path).toLowerCase())
        .where(known.contains)
        .firstOrNull;
    var suffix = extension ?? '.mp4';
    final format = await VideoDiskCache.detectFileFormat(partial);
    if (format == '.mpd') {
      await partial.delete();
      throw StateError('DASH 清单暂不支持离线下载');
    }
    if (VideoDiskCache.mpvFormats.contains(format) &&
        !(format == '.mkv' && suffix == '.webm') &&
        !(format == '.asf' && suffix == '.wmv')) {
      suffix = format;
    }
    _check(task);
    final name = 'media$suffix';
    await partial.rename(p.join(folder(task), name));
    task.fileName = name;
  }

  Future<void> _download(
    VideoDownloadTask task,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final partial = File(p.join(folder(task), 'media.mp4.part'));
    final validator = File(p.join(folder(task), 'resume.json'));
    final signature = sha256
        .convert(utf8.encode(uri.replace(query: '', fragment: '').toString()))
        .toString();
    Map old = {};
    try {
      old = jsonDecode(await validator.readAsString()) as Map;
    } catch (_) {}
    final previousValidator = old['validator'];
    final previousIfRange = _ifRange(previousValidator, old['validatorDate']);
    // A stable URL and file length cannot identify the version that was
    // interrupted. Keep the old bytes until a fresh response can replace them.
    final canResume = old['signature'] == signature &&
        old['encoded'] != true && previousIfRange != null;
    var offset = canResume && await partial.exists() ? await partial.length() : 0;
    final extra = <String, String>{
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0) 'If-Range': ?previousIfRange,
    };
    var scopedHeaders = Map.of(headers);
    var (response, finalUri) = offset == 0
        ? await _openFromStart(task, uri, uri, scopedHeaders)
        : await _open(task, uri, uri, scopedHeaders, extra: extra);
    final responseValidator = _validator(response);
    final changed =
        previousValidator != null &&
        responseValidator != null &&
        previousValidator != responseValidator;
    // An ETag is scoped to its target resource. Another CDN path or query can
    // serve different bytes with the same tag and length.
    final headerHash = _headerHash(headers);
    final sameResource = old['responseHash'] == _addressHash(finalUri);
    final sameRequest =
        old['requestHash'] == _addressHash(uri) &&
        old['headerHash'] == headerHash;
    final previousLength = old['length'] is int ? old['length'] as int : null;
    final range = response.headers.value('content-range');
    final responseTotal = int.tryParse(range?.split('/').last ?? '');
    final returnedStart = int.tryParse(mediaContentRange.firstMatch(range ?? '')?[1] ?? '');
    final restart =
        changed ||
        !sameResource ||
        (!sameRequest && !_sameStrongTag(previousValidator, response)) ||
        (previousLength != null &&
            responseTotal != null &&
            previousLength != responseTotal);
    if (offset > 0 &&
        (const [400, 403, 405, 412].contains(response.statusCode) ||
            response.statusCode == 206 &&
                (returnedStart != offset || _encoding(response) != 'identity' || restart) ||
            response.statusCode == 416 &&
                (restart ||
                    response.headers.value('content-range') !=
                        'bytes */$offset'))) {
      await response.listen(null).cancel();
      offset = 0;
      scopedHeaders = Map.of(headers);
      (response, finalUri) = await _openFromStart(task, uri, uri, scopedHeaders);
    }
    if (response.statusCode == 416 &&
        offset > 0 &&
        response.headers.value('content-range') == 'bytes */$offset') {
      await response.listen(null).cancel();
      await _publishMedia(task, partial, uri, finalUri);
      task.bytes = task.totalBytes = offset;
      return;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.listen(null).cancel();
      throw StateError('下载请求失败：HTTP ${response.statusCode}');
    }
    if (response.headers.contentType?.mimeType == 'application/dash+xml') {
      await response.listen(null).cancel();
      throw StateError('DASH 清单暂不支持离线下载');
    }
    if (response.statusCode == 200) offset = 0;
    var etag =
        _validator(response) ??
        (offset > 0 ? old['validator'] as String? : null);
    var validatorDate = _validator(response) == null && offset > 0
        ? old['validatorDate'] as String?
        : response.headers.value('date');
    final iterator = StreamIterator(
      _downloadBody(
        task,
        finalUri,
        uri,
        scopedHeaders,
        response,
        offset,
        expectedLength: offset > 0 ? previousLength : null,
        expectedValidator: etag,
        expectedDate: validatorDate,
        onValidator: (value, date) {
          etag = value;
          validatorDate = date;
        },
        onLength: (length) => task.totalBytes = length,
      ),
    );
    try {
      if (!await iterator.moveNext()) throw StateError('视频响应为空');
      final first = <int>[...iterator.current];
      var ended = false;
      while (first.length < 16) {
        if (!await iterator.moveNext()) {
          ended = true;
          break;
        }
        first.addAll(iterator.current);
      }
      Stream<List<int>> stream() async* {
        yield first;
        while (!ended && await iterator.moveNext()) {
          _check(task);
          yield iterator.current;
        }
      }

      final prefix = utf8
          .decode(first.take(80).toList(), allowMalformed: true)
          .trimLeft();
      if (offset == 0 && prefix.startsWith('#EXTM3U')) {
        final playlist = await _text(stream());
        task.bytes = 0;
        task.totalBytes = 0;
        await _playlist(task, finalUri, uri, scopedHeaders, playlist, 'index', 0);
        task.fileName = 'index.m3u8';
        return;
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (type == 'application/json' || type == 'text/html') {
        throw StateError('站点返回的不是视频文件');
      }
      if (offset == 0 && _isHtml(prefix)) {
        throw StateError('站点返回网页而非视频文件');
      }
      if (offset == 0 && await partial.exists()) await partial.delete();
      final resumeInfo = <String, Object?>{
        'signature': signature,
        'requestHash': _addressHash(uri),
        'responseHash': _addressHash(finalUri),
        'headerHash': headerHash,
        if (task.totalBytes > 0) 'length': task.totalBytes,
        'validator': ?etag,
        if (etag != null && validatorDate != null) 'validatorDate': validatorDate,
        if (_encoding(response) != 'identity') 'encoded': true,
      };
      await validator.writeAsString(jsonEncode(resumeInfo), flush: true);
      task.bytes = offset;
      final sink = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      final watch = Stopwatch()..start();
      var interval = 0;
      var policyBytes = 0;
      try {
        await for (final bytes in stream()) {
          _check(task);
          // Some origins first disclose the validator or length on a later
          // range. Persist it before appending bytes from that response.
          if (resumeInfo['validator'] != etag ||
              task.totalBytes > 0 && resumeInfo['length'] != task.totalBytes) {
            if (etag != null) resumeInfo['validator'] = etag;
            if (validatorDate != null) resumeInfo['validatorDate'] = validatorDate;
            if (task.totalBytes > 0) resumeInfo['length'] = task.totalBytes;
            await validator.writeAsString(jsonEncode(resumeInfo), flush: true);
          }
          sink.add(bytes);
          task.bytes += bytes.length;
          interval += bytes.length;
          policyBytes += bytes.length;
          if (policyBytes >= 8 * 1024 * 1024) {
            await _policyCheckpoint(task);
            policyBytes = 0;
          }
          if (watch.elapsedMilliseconds >= 300) {
            task.bytesPerSecond = interval * 1000 / watch.elapsedMilliseconds;
            interval = 0;
            watch.reset();
            _notifyProgress();
          }
          if (_yieldToPlayback) {
            await Future<void>.delayed(const Duration(milliseconds: 8));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (task.bytes == 0 ||
          task.totalBytes > 0 && task.bytes != task.totalBytes) {
        throw StateError('文件尚未下载完整');
      }
      await _publishMedia(task, partial, uri, finalUri);
    } finally {
      await iterator.cancel();
    }
  }

  Future<String> _text(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final part in stream) {
      bytes.addAll(part);
      if (bytes.length > 4 * 1024 * 1024) throw StateError('播放清单过大');
    }
    return utf8.decode(bytes);
  }

  Future<(String, Uri, Map<String, String>)> _fetchText(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
  ) async {
    await _policyCheckpoint(task);
    final scopedHeaders = Map.of(headers);
    final (r, finalUri) = await _openFromStart(task, uri, origin, scopedHeaders);
    if (r.statusCode != 200 && r.statusCode != 206) {
      await r.listen(null).cancel();
      throw StateError('播放清单不可用：HTTP ${r.statusCode}');
    }
    return (
      await _text(_downloadBody(task, finalUri, origin, scopedHeaders, r, 0)),
      finalUri,
      scopedHeaders,
    );
  }

  Future<void> _playlist(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    String body,
    String name,
    int depth,
  ) async {
    if (depth > 3 || !body.trimLeft().startsWith('#EXTM3U')) {
      throw StateError('播放清单格式无效');
    }
    if (VideoDiskCache.instance.skipHlsAds) body = HlsAdFilter.filter(body);
    final lines = const LineSplitter().convert(body).map((line) => line.trim()).toList();
    final variants =
        <({Map<String, String> attributes, String url, int bandwidth, bool? hasVideo})>[];
    for (final pair in hlsVariants(lines)) {
      final attributes = hlsRawAttributes(lines[pair.tag]);
      variants.add((
        attributes: attributes,
        url: lines[pair.uri].trim(),
        bandwidth: int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0,
        hasVideo: hlsVariantHasVideo(attributes),
      ));
    }
    if (variants.isEmpty &&
        lines.any((line) => line.trimLeft().startsWith('#EXT-X-STREAM-INF:'))) {
      throw StateError('播放清单缺少画质线路地址');
    }
    if (variants.isNotEmpty) {
      if (variants.any((v) => v.hasVideo == true)) {
        variants.removeWhere((v) => v.hasVideo == false);
      }
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      final best = variants.first;
      final attributes = best.attributes..remove('SUBTITLES');
      final master = <String>['#EXTM3U'];
      final audioFiles = <Uri, String>{};
      final retained = <String>{};
      for (final line in lines.where((l) => l.startsWith('#EXT-X-MEDIA:'))) {
        final media = hlsRawAttributes(line);
        final type = media['TYPE'];
        if (type != 'AUDIO' && type != 'CLOSED-CAPTIONS') continue;
        if (media['GROUP-ID'] == null ||
            media['GROUP-ID'] != attributes[type]) {
          continue;
        }
        final rawUri = media['URI'];
        if (type == 'AUDIO' && rawUri != null) {
          final url = uri.resolve(hlsAttributeValue(rawUri));
          var local = audioFiles[url];
          if (local == null) {
            local = audioFiles.isEmpty
                ? '$name-audio'
                : '$name-audio-${audioFiles.length + 1}';
            final (text, finalUri, audioHeaders) = await _fetchText(
              task,
              url,
              origin,
              headers,
            );
            await _playlist(
              task,
              finalUri,
              origin,
              audioHeaders,
              text,
              local,
              depth + 1,
            );
            audioFiles[url] = local;
          }
          media['URI'] = '"$local.m3u8"';
        }
        retained.add(type!);
        master.add(hlsTag('#EXT-X-MEDIA', media));
      }
      if (!retained.contains('AUDIO')) attributes.remove('AUDIO');
      if (!retained.contains('CLOSED-CAPTIONS') &&
          attributes['CLOSED-CAPTIONS'] != 'NONE') {
        attributes.remove('CLOSED-CAPTIONS');
      }
      final url = uri.resolve(best.url);
      final (text, finalUri, videoHeaders) = await _fetchText(task, url, origin, headers);
      await _playlist(
        task,
        finalUri,
        origin,
        videoHeaders,
        text,
        '$name-video',
        depth + 1,
      );
      master.addAll([
        hlsTag('#EXT-X-STREAM-INF', attributes),
        '$name-video.m3u8',
      ]);
      await File(p.join(folder(task), '$name.m3u8'))
          .writeAsString('${master.join('\n')}\n', flush: true);
      return;
    }
    final unsupported = unsupportedPlaylistReason(body);
    if (unsupported != null) throw StateError(unsupported);
    // Identical relative names can resolve to different keys and media after
    // a resolver changes CDN or directory between attempts.
    final plan = sha256
        .convert(utf8.encode(jsonEncode(['ts-v3', origin.origin, uri.toString(), _headerHash(headers), body])))
        .toString()
        .substring(0, 16);
    final resourceDir = Directory(p.join(folder(task), '$name-$plan'));
    await resourceDir.create(recursive: true);
    final output = <String>[];
    var encrypted = false;
    var keySuffix = '';
    var mappedMp4 = false;
    var index = 0;
    task.total += lines.where((l) => l.isNotEmpty && !l.startsWith('#')).length;
    final pending = <Future<void> Function()>[];
    Future<void> flushSegments() async {
      if (pending.isEmpty) return;
      await _policyCheckpoint(task);
      await Future.wait(pending.map((download) => download()));
      pending.clear();
    }

    for (final line in lines) {
      _check(task);
      if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
        await flushSegments();
        final key = line.startsWith('#EXT-X-KEY:');
        final attributes = hlsRawAttributes(line);
        if (key) {
          encrypted = attributes['METHOD'] != 'NONE';
          keySuffix = '';
        }
        final rawUri = attributes['URI'];
        if (rawUri != null) {
          final url = uri.resolve(hlsAttributeValue(rawUri));
          final relative =
              '$name-$plan/${key ? 'key' : 'map'}-${index++}$keySuffix.${key ? 'key' : 'mp4'}';
          final file = File(p.join(folder(task), relative));
          await _policyCheckpoint(task);
          await _resource(
            task,
            url,
            origin,
            headers,
            file,
            key: key,
          );
          if (key) {
            // Key URLs can stay the same while the encrypted segments rotate.
            keySuffix = '-${sha256.convert(await file.readAsBytes()).toString().substring(0, 16)}';
          } else {
            mappedMp4 = encrypted
                ? const {'.mp4', '.m4s', '.m4a'}.contains(p.extension(url.path).toLowerCase())
                : await hasMp4BoxHeader(file);
          }
          attributes['URI'] = '"$relative"';
          output.add(hlsTag(key ? '#EXT-X-KEY' : '#EXT-X-MAP', attributes));
          continue;
        }
      }
      if (line.isNotEmpty && !line.startsWith('#')) {
        final url = uri.resolve(line);
        final suffix = p.extension(url.path).toLowerCase();
        final extension =
            const {'.ts', '.m4s', '.mp4', '.aac', '.mp3', '.ac3', '.ec3', '.eac3'}.contains(suffix)
            ? suffix
            : mappedMp4 ? '.m4s' : '.ts';
        final relative = '$name-$plan/segment-${index++}$keySuffix$extension';
        final unwrap = !encrypted && extension == '.ts';
        pending.add(() async {
          if (_yieldToPlayback) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await _resource(
            task,
            url,
            origin,
            headers,
            File(p.join(folder(task), relative)),
            unwrap: unwrap,
          );
          task.completed++;
          _notifyProgress();
        });
        output.add(relative);
        if (pending.length >= (_yieldToPlayback ? 1 : 3)) {
          await flushSegments();
        }
      } else {
        output.add(line);
      }
    }
    await flushSegments();
    await File(p.join(folder(task), '$name.m3u8'))
        .writeAsString('${output.join('\n')}\n', flush: true);
  }

  static String? unsupportedPlaylistReason(String body) {
    final lines = const LineSplitter()
        .convert(body)
        .map((line) => line.trim())
        .toList();
    if (lines.any((line) => line.startsWith('#EXT-X-STREAM-INF:'))) return null;
    if (!lines.contains('#EXT-X-ENDLIST')) return '直播流不支持离线下载';
    if (lines.any((line) => line.startsWith('#EXT-X-BYTERANGE'))) {
      return '该线路使用字节范围 HLS，暂不支持下载';
    }
    var needsMapIv = false;
    for (final line in lines) {
      final key = line.startsWith('#EXT-X-KEY:');
      if (!key && !line.startsWith('#EXT-X-MAP:')) continue;
      final attributes = hlsRawAttributes(line);
      if (key) {
        final method = attributes['METHOD'];
        needsMapIv = method != 'NONE' && attributes['IV'] == null;
        if (method == 'NONE') continue;
        if (method != 'AES-128' ||
            hlsAttributeValue(attributes['KEYFORMAT'] ?? 'identity') != 'identity') {
          return '该加密格式不支持离线下载';
        }
      }
      if (hlsAttributeValue(attributes['URI'] ?? '').trim().isEmpty) {
        return key ? '播放清单缺少密钥地址' : '播放清单缺少初始化片段地址';
      }
      if (!key && needsMapIv) return '加密初始化片段缺少 IV';
    }
    return null;
  }

  static bool _isHtml(String prefix) {
    final text = prefix.trimLeft().toLowerCase();
    return text.startsWith('<!doctype') || text.startsWith('<html');
  }

  Future<void> _resource(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    File file, {
    bool key = false,
    bool unwrap = false,
  }) async {
    if (!key && await file.exists() && await file.length() > 0) {
      task.bytes += await file.length();
      return;
    }
    final scopedHeaders = Map.of(headers);
    final (r, finalUri) = await _openFromStart(task, uri, origin, scopedHeaders);
    if (r.statusCode != 200 && r.statusCode != 206) {
      await r.listen(null).cancel();
      throw StateError('分片下载失败：HTTP ${r.statusCode}');
    }
    final temporary = File('${file.path}.part');
    final sink = temporary.openWrite();
    final prefix = <int>[];
    var size = 0, received = 0;
    try {
      final body = _downloadBody(task, finalUri, origin, scopedHeaders, r, 0).map((chunk) {
        received += chunk.length;
        return chunk;
      });
      await for (final b in (unwrap ? unwrapTransportStream(body) : body)) {
        _check(task);
        if (!key && prefix.length < 80) {
          prefix.addAll(b.take(80 - prefix.length));
          if (_isHtml(utf8.decode(prefix, allowMalformed: true))) {
            throw StateError('分片下载返回网页，请重试');
          }
        }
        sink.add(b);
        size += b.length;
        task.bytes += b.length;
        _speedBytes += b.length;
        if (_speedWatch.elapsedMilliseconds >= 300) {
          task.bytesPerSecond =
              _speedBytes * 1000 / _speedWatch.elapsedMilliseconds;
          _speedBytes = 0;
          _speedWatch.reset();
          notifyListeners();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (size == 0 ||
        key && size != 16 ||
        r.statusCode == 200 &&
            _encoding(r) == 'identity' &&
            r.contentLength >= 0 &&
            received != r.contentLength) {
      throw StateError('分片或密钥不完整');
    }
    _check(task);
    await temporary.rename(file.path);
  }

  Future<void> _save() {
    final bytes = jsonEncode([for (final task in tasks) task.toJson()]);
    final next = _writes.then((_) async {
      final part = File(p.join(root.path, 'tasks.json.part'));
      await part.writeAsString(bytes, flush: true);
      await part.rename(p.join(root.path, 'tasks.json'));
      storageError = null;
    });
    _writes = next.catchError((Object _) {
      storageError = '下载任务未能保存，请检查剩余空间';
    });
    return _writes;
  }

  Future<void> flush() async {
    // A completed merge can still be removing fragments and writing its
    // final manifest. Flushing a running transfer only waits for its writes.
    if (_active?.state == 'done') await _activeFinished?.future;
    await _writes;
  }
}

class _Paused implements Exception {
  const _Paused();
}
