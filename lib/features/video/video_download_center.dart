import '../../core/experience/content_center.dart';
import '../../core/reading/reading.dart';
import '../../core/experience/offline_policy.dart';
import '../../core/source/source_runtime_pins.dart';
import '../../core/media/playback_focus.dart';
import '../../core/net/lume_net.dart';
import '../../core/net/lume_http.dart';
import '../../core/net/http_header_scope.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/sensitive_data.dart';
import 'source_playback.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/apple_hls_fragments.dart';
import '../../core/player/hls_ad_filter.dart';
import '../../core/player/hls_attributes.dart';
import '../../core/player/hls_variants.dart';
import '../../core/player/video_disk_cache.dart';
import 'video_download_merger.dart';
import 'offline_video_server.dart';

class DownloadedVideoPlayback {
  DownloadedVideoPlayback(this.uri, [this.server]);
  final Uri uri;
  final OfflineVideoServer? server;
  PlayerMedia media(String title) =>
      PlayerMedia(uri: uri, title: title, isDownloaded: true);
  Future<void> close() async {
    await server?.close();
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
    this.state = 'paused',
    this.bytes = 0,
    this.totalBytes = 0,
    this.completed = 0,
    this.total = 0,
    this.fileName = '',
    this.chapterIndex = 0,
    this.line = '',
    this.error,
  });
  final String id, sourceId, itemId, chapterId, title, chapterTitle;
  final int chapterIndex;
  final String line;
  String state, fileName;
  String? error;
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
  };
}

/// Persistent, page-independent VOD downloads. Credentials and resolved URLs are never serialized.
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
  static String identity(String source, String item, String chapter) => sha256
      .convert(utf8.encode(jsonEncode([source, item, chapter])))
      .toString();
  Future<void> boot() => _boot ??= _restore();
  Future<void> _restore() async {
    root = Directory(
      p.join(
        (await (directory?.call() ?? getApplicationSupportDirectory())).path,
        'video_downloads',
      ),
    );
    await root.create(recursive: true);
    final manifest = File(p.join(root.path, 'tasks.json'));
    try {
      if (await manifest.exists()) {
        for (final value in jsonDecode(await manifest.readAsString()) as List) {
          final m = value as Map;
          final id = identity(
            '${m['sourceId']}',
            '${m['itemId']}',
            '${m['chapterId']}',
          );
          if (m['id'] != id) continue;
          final fileName = '${m['fileName'] ?? ''}';
          if (fileName.isNotEmpty &&
              (p.isAbsolute(fileName) || p.split(fileName).contains('..'))) {
            continue;
          }
          tasks.add(
            VideoDownloadTask(
              id: id,
              sourceId: '${m['sourceId']}',
              itemId: '${m['itemId']}',
              chapterId: '${m['chapterId']}',
              title: '${m['title']}',
              chapterTitle: '${m['chapterTitle']}',
              chapterIndex: (m['chapterIndex'] as num?)?.toInt() ?? 0,
              line: m['line'] as String? ?? '',
              state: ['done', 'merge_failed'].contains(m['state'])
                  ? '${m['state']}'
                  : 'paused',
              bytes: (m['bytes'] as num?)?.toInt() ?? 0,
              totalBytes: (m['totalBytes'] as num?)?.toInt() ?? 0,
              completed: (m['completed'] as num?)?.toInt() ?? 0,
              total: (m['total'] as num?)?.toInt() ?? 0,
              fileName: fileName,
            ),
          );
        }
      }
    } catch (_) {
      storageError = '下载任务记录读取失败，已下载文件仍保留';
    }
    notifyListeners();
  }

  String folder(VideoDownloadTask task) => p.join(root.path, task.id);
  File localFile(VideoDownloadTask task) =>
      File(p.join(folder(task), task.fileName));
  Future<File?> completedFile(
    String sourceId,
    String itemId,
    String chapterId,
  ) async {
    await boot();
    final id = identity(sourceId, itemId, chapterId);
    final task = tasks
        .where((t) => t.id == id && t.canPlayOffline)
        .firstOrNull;
    if (task == null) return null;
    final file = localFile(task);
    return await file.exists() ? file : null;
  }

  Future<DownloadedVideoPlayback?> completedPlayback(
    String sourceId,
    String itemId,
    String chapterId,
  ) async {
    final file = await completedFile(sourceId, itemId, chapterId);
    if (file == null) return null;
    if (!file.path.endsWith('.m3u8')) return DownloadedVideoPlayback(file.uri);
    final server = await OfflineVideoServer.open(file.parent);
    return DownloadedVideoPlayback(
      server.uri.replace(
        pathSegments: [
          ...server.uri.pathSegments.take(1),
          p.basename(file.path),
        ],
      ),
      server,
    );
  }

  Future<void> enqueue({
    required String sourceId,
    required String itemId,
    required String title,
    required List<SourceChapter> chapters,
    Map<String, int> chapterIndices = const {},
  }) async {
    await boot();
    for (final chapter in chapters) {
      final id = identity(sourceId, itemId, chapter.id);
      final existing = tasks.where((t) => t.id == id).firstOrNull;
      if (existing != null) {
        if (!existing.running &&
            (existing.state != 'done' || !await localFile(existing).exists())) {
          existing.state = 'queued';
        }
        continue;
      }
      tasks.add(
        VideoDownloadTask(
          id: id,
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
    final library = await ReadingLibrary.open(Section.video);
    var removed = 0;
    for (final task in List<VideoDownloadTask>.of(tasks)) {
      if (task.state != 'done' || identical(_active, task)) continue;
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
        final localMerge = task.hasLocalPlaylist && await localFile(task).exists();
        final blocked = await OfflinePolicy.blocked(needsNetwork: !localMerge);
        if (task.state != 'queued') continue;
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
          Section.video,
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
          await _download(task, uri, content.headers);
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
    final source = await LumeSources.manager(Section.video).open(task.sourceId);
    if (source == null) throw StateError('源不可用，请恢复对应源后继续');
    final descriptor = (await LumeSources.manager(
      Section.video,
    ).list()).where((d) => d.id == task.sourceId).firstOrNull;
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
        await for (final entry in dir.list(followLinks: false)) {
          if (p.equals(entry.path, output.path)) continue;
          try {
            await entry.delete(recursive: true);
          } on FileSystemException {
            task.error = 'MP4 已合并，部分临时文件未能清理';
          }
        }
      }
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  static Future<bool> _isMp4(File file) async {
    if (!await file.exists()) return false;
    final input = await file.open();
    try {
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
    } finally {
      await input.close();
    }
  }

  Future<(HttpClientResponse, Uri)> _open(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers, {
    Map<String, String> extra = const {},
  }) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      _check(task);
      if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
        throw StateError('下载地址协议无效');
      }
      final req = await _client!.getUrl(uri);
      req.followRedirects = false;
      for (final e in headers.entries) {
        if (uri.origin != origin.origin && isOriginBoundHttpHeader(e.key)) {
          continue;
        }
        req.headers.set(e.key, e.value);
      }
      if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
        req.headers.set(
          'User-Agent',
          LumeNet.settings.userAgent.isNotEmpty
              ? LumeNet.settings.userAgent
              : LumeHttp.defaultUserAgent,
        );
      }
      req.headers.set('Accept-Encoding', 'identity');
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

  Stream<List<int>> _downloadBody(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    HttpClientResponse response,
    int offset, {
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

  // Byte ranges and validators refer to the encoded HTTP representation.
  Stream<List<int>> _wireBody(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    HttpClientResponse response,
    int offset, {
    void Function(int)? onLength,
  }) async* {
    if (response.statusCode == 200) {
      onLength?.call(response.contentLength < 0 ? 0 : response.contentLength);
      yield* response.timeout(const Duration(seconds: 45));
      return;
    }
    final validator = _validator(response);
    final encoding = _encoding(response);
    int? total;
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
      final range = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+|\*)$',
        caseSensitive: false,
      ).firstMatch(response.headers.value('content-range') ?? '');
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
        extra: {'Range': 'bytes=$offset-', 'If-Range': ?validator},
      );
      (response, uri) = next;
    }
  }

  Future<void> _download(
    VideoDownloadTask task,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final extension = p.extension(uri.path).toLowerCase();
    final targetName =
        'media${['.mp4', '.mkv', '.webm', '.m4v', '.mov', '.ts', '.avi', '.flv'].contains(extension) ? extension : '.mp4'}';
    final partial = File(p.join(folder(task), 'media.mp4.part'));
    final validator = File(p.join(folder(task), 'resume.json'));
    final signature = sha256
        .convert(utf8.encode(uri.replace(query: '', fragment: '').toString()))
        .toString();
    Map old = {};
    try {
      old = jsonDecode(await validator.readAsString()) as Map;
    } catch (_) {}
    if ((old['signature'] != signature || old['encoded'] == true) &&
        await partial.exists()) {
      await partial.delete();
    }
    var offset = await partial.exists() ? await partial.length() : 0;
    final extra = <String, String>{
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0 && old['validator'] is String)
        'If-Range': old['validator'] as String,
    };
    var (response, finalUri) = await _open(
      task,
      uri,
      uri,
      headers,
      extra: extra,
    );
    final previousValidator = old['validator'];
    final responseValidator = _validator(response);
    final changed =
        previousValidator != null &&
        responseValidator != null &&
        previousValidator != responseValidator;
    if (offset > 0 &&
        (response.statusCode == 206 &&
                (_encoding(response) != 'identity' || changed) ||
            response.statusCode == 416 &&
                (changed ||
                    response.headers.value('content-range') !=
                        'bytes */$offset'))) {
      await response.listen(null).cancel();
      offset = 0;
      (response, finalUri) = await _open(task, uri, uri, headers);
    }
    if (response.statusCode == 416 &&
        offset > 0 &&
        response.headers.value('content-range') == 'bytes */$offset') {
      await response.listen(null).cancel();
      _check(task);
      await partial.rename(p.join(folder(task), targetName));
      task.bytes = task.totalBytes = offset;
      task.fileName = targetName;
      return;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw StateError('下载请求失败：HTTP ${response.statusCode}');
    }
    if (response.statusCode == 200) offset = 0;
    final etag =
        _validator(response) ??
        (offset > 0 ? old['validator'] as String? : null);
    final iterator = StreamIterator(
      _downloadBody(
        task,
        finalUri,
        uri,
        headers,
        response,
        offset,
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
        await _playlist(task, finalUri, uri, headers, playlist, 'index', 0);
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
      await validator.writeAsString(
        jsonEncode({
          'signature': signature,
          'validator': ?etag,
          if (_encoding(response) != 'identity') 'encoded': true,
        }),
        flush: true,
      );
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
      _check(task);
      await partial.rename(p.join(folder(task), targetName));
      task.fileName = targetName;
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

  Future<(String, Uri)> _fetchText(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
  ) async {
    await _policyCheckpoint(task);
    final (r, finalUri) = await _open(task, uri, origin, headers);
    if (r.statusCode != 200 && r.statusCode != 206) {
      throw StateError('播放清单不可用：HTTP ${r.statusCode}');
    }
    return (
      await _text(_downloadBody(task, finalUri, origin, headers, r, 0)),
      finalUri,
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
    final lines = const LineSplitter().convert(body);
    final variants =
        <({Map<String, String> attributes, String url, int bandwidth})>[];
    for (final pair in hlsVariants(lines)) {
      final attributes = hlsRawAttributes(lines[pair.tag]);
      variants.add((
        attributes: attributes,
        url: lines[pair.uri].trim(),
        bandwidth: int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0,
      ));
    }
    if (variants.isEmpty &&
        lines.any((line) => line.trimLeft().startsWith('#EXT-X-STREAM-INF:'))) {
      throw StateError('播放清单缺少画质线路地址');
    }
    if (variants.isNotEmpty) {
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
            final (text, finalUri) = await _fetchText(
              task,
              url,
              origin,
              headers,
            );
            await _playlist(
              task,
              finalUri,
              origin,
              headers,
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
      final (text, finalUri) = await _fetchText(task, url, origin, headers);
      await _playlist(
        task,
        finalUri,
        origin,
        headers,
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
        .convert(utf8.encode(jsonEncode(['ts-v2', uri.toString(), body])))
        .toString()
        .substring(0, 16);
    final resourceDir = Directory(p.join(folder(task), '$name-$plan'));
    await resourceDir.create(recursive: true);
    final output = <String>[];
    var encrypted = false;
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
        if (key) encrypted = attributes['METHOD'] != 'NONE';
        final rawUri = attributes['URI'];
        if (rawUri != null) {
          final url = uri.resolve(hlsAttributeValue(rawUri));
          final relative =
              '$name-$plan/${key ? 'key' : 'map'}-${index++}.${key ? 'key' : 'mp4'}';
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
          if (!key) {
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
            ['.ts', '.m4s', '.mp4', '.aac', '.mp3'].contains(suffix)
            ? suffix
            : mappedMp4 ? '.m4s' : '.ts';
        final relative = '$name-$plan/segment-${index++}$extension';
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
    if (await file.exists() && await file.length() > 0) {
      task.bytes += await file.length();
      return;
    }
    final (r, finalUri) = await _open(task, uri, origin, headers);
    if (r.statusCode != 200 && r.statusCode != 206) {
      throw StateError('分片下载失败：HTTP ${r.statusCode}');
    }
    final temporary = File('${file.path}.part');
    final sink = temporary.openWrite();
    final prefix = <int>[];
    var size = 0, received = 0;
    try {
      final body = _downloadBody(task, finalUri, origin, headers, r, 0).map((chunk) {
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
