import '../../core/media/playback_focus.dart';
import '../../core/net/lume_net.dart';
import '../../core/net/lume_http.dart';

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
import 'video_download_merger.dart';

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
    this.error,
  });
  final String id, sourceId, itemId, chapterId, title, chapterTitle;
  String state, fileName;
  String? error;
  int bytes, totalBytes, completed, total;
  double bytesPerSecond = 0;
  bool get running => state == 'running' || state == 'merging';
  bool get hasLocalPlaylist => fileName.endsWith('.m3u8');
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
              state: m['state'] == 'done' ? 'done' : 'paused',
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
  Future<void> enqueue({
    required String sourceId,
    required String itemId,
    required String title,
    required List<SourceChapter> chapters,
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

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final task = tasks.where((t) => t.state == 'queued').firstOrNull;
        if (task == null) break;
        _active = task;
        task.state = 'running';
        task.error = null;
        task.completed = 0;
        task.total = 0;
        _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 25)
          ..autoUncompress = false;
        await _save();
        notifyListeners();
        try {
          if (task.hasLocalPlaylist && await localFile(task).exists()) {
            await _mergeDownloaded(task);
            continue;
          }
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
          await _download(task, uri, content.headers);
          _check(task);
          if (task.hasLocalPlaylist) {
            await _save();
            await _mergeDownloaded(task);
          }
          task.state = 'done';
        } catch (error) {
          if (task.running) {
            task.state = task.hasLocalPlaylist ? 'merge_failed' : 'failed';
            task.error = SensitiveData.redact('$error')
                .replaceAll(RegExp(r'https?://[^\s]+'), '[地址]');
          }
        } finally {
          _client?.close(force: true);
          _client = null;
          _active = null;
          task.bytesPerSecond = 0;
          await _save();
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
    task.state = 'merging';
    task.bytesPerSecond = 0;
    await _save();
    notifyListeners();
    final dir = Directory(folder(task));
    final part = File(p.join(dir.path, 'merged.mp4.part'));
    final output = File(p.join(dir.path, 'merged.mp4'));
    try {
      // A crash after atomic rename but before manifest update can reuse the result.
      if (!await output.exists()) {
        if (await part.exists()) await part.delete();
        _check(task);
        await (merge ?? _merger.merge)(dir, part, task.id);
        _check(task);
        if (!await _isMp4(part)) throw StateError('合并未生成有效的 MP4 文件');
        await part.rename(output.path);
      } else if (!await _isMp4(output)) {
        throw StateError('已有合并文件不完整，请删除该文件后重试');
      }
      _check(task);
      task.fileName = 'merged.mp4';
      task.bytes = task.totalBytes = await output.length();
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
    if (!await file.exists() || await file.length() < 16) return false;
    final header = await file.open();
    try {
      final bytes = await header.read(12);
      return ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp';
    } finally {
      await header.close();
    }
  }

  Future<HttpClientResponse> _open(
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
        if (uri.origin != origin.origin &&
            [
              'cookie',
              'authorization',
              'proxy-authorization',
            ].contains(e.key.toLowerCase())) {
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
        await response.drain<void>();
        if (location == null) throw StateError('下载重定向缺少地址');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw StateError('下载重定向过多');
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
    if (old['signature'] != signature && await partial.exists()) {
      await partial.delete();
    }
    var offset = await partial.exists() ? await partial.length() : 0;
    final extra = <String, String>{
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0 && old['validator'] is String)
        'If-Range': old['validator'] as String,
    };
    final response = await _open(task, uri, uri, headers, extra: extra);
    if (response.statusCode == 416 &&
        offset > 0 &&
        response.headers.value('content-range') == 'bytes */$offset') {
      await response.drain<void>();
      await partial.rename(p.join(folder(task), targetName));
      task.fileName = targetName;
      return;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw StateError('下载请求失败：HTTP ${response.statusCode}');
    }
    final iterator = StreamIterator(
      response.timeout(const Duration(seconds: 45)),
    );
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
    if (prefix.startsWith('#EXTM3U')) {
      final playlist = await _text(stream());
      task.bytes = 0;
      task.totalBytes = 0;
      await _playlist(task, uri, uri, headers, playlist, 'index', 0);
      task.fileName = 'index.m3u8';
      return;
    }
    final type = response.headers.contentType?.mimeType ?? '';
    if (type == 'application/json' || type == 'text/html') {
      throw StateError('站点返回的不是视频文件');
    }
    if (prefix.toLowerCase().startsWith('<!doctype') ||
        prefix.toLowerCase().startsWith('<html')) {
      throw StateError('站点返回网页而非视频文件');
    }
    if (response.statusCode == 206) {
      if (!RegExp('^bytes $offset-')
          .hasMatch(response.headers.value('content-range') ?? '')) {
        throw StateError('服务器续传位置不匹配，请重试');
      }
    } else {
      offset = 0;
    }
    final etag =
        response.headers.value('etag') ??
        response.headers.value('last-modified');
    await validator.writeAsString(
      jsonEncode({'signature': signature, 'validator': ?etag}),
      flush: true,
    );
    task.bytes = offset;
    task.totalBytes = response.contentLength < 0
        ? 0
        : offset + response.contentLength;
    final sink = partial.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    final watch = Stopwatch()..start();
    var interval = 0;
    try {
      await for (final bytes in stream()) {
        _check(task);
        sink.add(bytes);
        task.bytes += bytes.length;
        interval += bytes.length;
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
      await iterator.cancel();
    }
    if (task.bytes == 0 ||
        task.totalBytes > 0 && task.bytes != task.totalBytes) {
      throw StateError('文件尚未下载完整');
    }
    _check(task);
    await partial.rename(p.join(folder(task), targetName));
    task.fileName = targetName;
  }

  Future<String> _text(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final part in stream) {
      bytes.addAll(part);
      if (bytes.length > 4 * 1024 * 1024) throw StateError('播放清单过大');
    }
    return utf8.decode(bytes);
  }

  Future<String> _fetchText(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
  ) async {
    final r = await _open(task, uri, origin, headers);
    if (r.statusCode != 200) throw StateError('播放清单不可用：HTTP ${r.statusCode}');
    return _text(r.timeout(const Duration(seconds: 45)));
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
    final lines = const LineSplitter().convert(body);
    final variants = <({String tag, String url, int bandwidth})>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF:') && i + 1 < lines.length) {
        final bandwidth =
            int.tryParse(
              RegExp(r'(?:^|,)BANDWIDTH=(\d+)')
                      .firstMatch(lines[i].split(':').skip(1).join(':'))
                      ?.group(1) ??
                  '',
            ) ??
            0;
        variants.add((
          tag: lines[i],
          url: lines[i + 1].trim(),
          bandwidth: bandwidth,
        ));
      }
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      final best = variants.first;
      var tag = best.tag.replaceAll(RegExp(r',?SUBTITLES="[^"]*"'), '');
      final group = RegExp(r'AUDIO="([^"]+)"').firstMatch(tag)?.group(1);
      final master = <String>['#EXTM3U'];
      if (group != null) {
        final audios = lines
            .where(
              (l) =>
                  l.startsWith('#EXT-X-MEDIA:') &&
                  l.contains('TYPE=AUDIO') &&
                  l.contains('GROUP-ID="$group"') &&
                  l.contains('URI="'),
            )
            .toList();
        if (audios.isNotEmpty) {
          final audio =
              audios.where((l) => l.contains('DEFAULT=YES')).firstOrNull ??
              audios.first;
          final url = uri.resolve(
            RegExp(r'URI="([^"]+)"').firstMatch(audio)!.group(1)!,
          );
          final text = await _fetchText(task, url, origin, headers);
          await _playlist(
            task,
            url,
            origin,
            headers,
            text,
            '$name-audio',
            depth + 1,
          );
          master.add(
            audio.replaceFirst(
              RegExp(r'URI="[^"]+"'),
              'URI="$name-audio.m3u8"',
            ),
          );
        } else {
          tag = tag.replaceAll(RegExp(r',?AUDIO="[^"]*"'), '');
        }
      }
      final url = uri.resolve(best.url);
      final text = await _fetchText(task, url, origin, headers);
      await _playlist(
        task,
        url,
        origin,
        headers,
        text,
        '$name-video',
        depth + 1,
      );
      master.addAll([tag, '$name-video.m3u8']);
      await File(p.join(folder(task), '$name.m3u8'))
          .writeAsString('${master.join('\n')}\n', flush: true);
      return;
    }
    final unsupported = unsupportedPlaylistReason(body);
    if (unsupported != null) throw StateError(unsupported);
    final plan = sha256.convert(utf8.encode(body)).toString().substring(0, 16);
    final resourceDir = Directory(p.join(folder(task), '$name-$plan'));
    await resourceDir.create(recursive: true);
    final output = <String>[];
    var index = 0;
    task.total += lines.where((l) => l.isNotEmpty && !l.startsWith('#')).length;
    final pending = <Future<void>>[];
    Future<void> flushSegments() async {
      final batch = List<Future<void>>.of(pending);
      pending.clear();
      await Future.wait(batch);
    }

    for (final line in lines) {
      _check(task);
      if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
        await flushSegments();
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) {
          final url = uri.resolve(match.group(1)!);
          final key = line.startsWith('#EXT-X-KEY:');
          final relative =
              '$name-$plan/${key ? 'key' : 'map'}-${index++}.${key ? 'key' : 'mp4'}';
          await _resource(
            task,
            url,
            origin,
            headers,
            File(p.join(folder(task), relative)),
            key: key,
          );
          output.add(
            line.replaceRange(match.start, match.end, 'URI="$relative"'),
          );
          continue;
        }
      }
      if (line.isNotEmpty && !line.startsWith('#')) {
        final url = uri.resolve(line);
        final suffix = p.extension(url.path).toLowerCase();
        final extension =
            ['.ts', '.m4s', '.mp4', '.aac', '.mp3'].contains(suffix)
            ? suffix
            : '.ts';
        final relative = '$name-$plan/segment-${index++}$extension';
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
          );
          task.completed++;
          _notifyProgress();
        }());
        output.add(relative);
        if (pending.length >= (_yieldToPlayback ? 1 : 3)) await flushSegments();
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
    if (lines.any(
      (line) =>
          line.startsWith('#EXT-X-KEY:') &&
          !line.contains('METHOD=NONE') &&
          (!line.contains('METHOD=AES-128') ||
              line.contains('KEYFORMAT=') &&
                  !line.contains('KEYFORMAT="identity"')),
    )) {
      return '该加密格式不支持离线下载';
    }
    return null;
  }

  Future<void> _resource(
    VideoDownloadTask task,
    Uri uri,
    Uri origin,
    Map<String, String> headers,
    File file, {
    bool key = false,
  }) async {
    if (await file.exists() && await file.length() > 0) {
      task.bytes += await file.length();
      return;
    }
    final r = await _open(task, uri, origin, headers);
    if (r.statusCode != 200 && r.statusCode != 206) {
      throw StateError('分片下载失败：HTTP ${r.statusCode}');
    }
    final temporary = File('${file.path}.part');
    final sink = temporary.openWrite();
    var size = 0;
    try {
      await for (final b in r.timeout(const Duration(seconds: 45))) {
        _check(task);
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
        r.contentLength >= 0 && size != r.contentLength) {
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
    });
    _writes = next.catchError((Object _) {
      storageError = '下载任务未能保存，请检查剩余空间';
    });
    return _writes;
  }

  Future<void> flush() => _writes;
}

class _Paused implements Exception {
  const _Paused();
}
