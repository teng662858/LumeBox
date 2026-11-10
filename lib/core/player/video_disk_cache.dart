import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'abstract_player.dart';
import '../net/lume_net.dart';

/// Bounded, session-only HTTP cache shared by all native playback kernels.
/// Credentials stay in memory; local URLs expose only an unguessable ticket.
class VideoDiskCache extends ChangeNotifier {
  VideoDiskCache() {
    _client.findProxy = (uri) {
      if (_loopback(uri)) return 'DIRECT';
      final proxy = Uri.tryParse(LumeNet.settings.proxy);
      return proxy != null &&
              ['http', 'https'].contains(proxy.scheme) &&
              proxy.host.isNotEmpty
          ? 'PROXY ${proxy.host}:${proxy.port}'
          : 'DIRECT';
    };
  }
  static final instance = VideoDiskCache();
  static const blockBytes = 1024 * 1024;
  static const minCapacityMb = 100, maxCapacityMb = 20480;
  final _client = HttpClient()..autoUncompress = false;
  final _tickets = <String, PlayerMedia>{};
  final _ticketKeys = <String, String>{};
  final _bypassed = <String>{};
  Timer? _progressNotice;
  final _files =
      <String, ({File file, int bytes, DateTime used, _Block block})>{};
  final _pending = <String, Future<_Block>>{};
  final _origins = Expando<Uri>();
  final _positions = <Uri, ({int next, int total})>{};
  Uri? _active;
  bool _warming = false, _warmAllowed = false;
  (Uri, int, int)? _warmMark;
  DateTime? _warmRetry;
  Directory? _root;
  File? _settings;
  HttpServer? _server;
  Future<void>? _starting;
  Future<void> _diskTail = Future.value();
  bool enabled = true, _ready = false, _clearing = false, _diskAvailable = true;
  int capacityMb = 1024, bytes = 0, hits = 0, downloadedBytes = 0;
  int _generation = 0;
  DateTime? _spaceChecked;
  String status = '尚未使用';
  Future<int?> Function()? freeSpace;
  int? _availableBytes;

  void stopPrefetch() {
    _warmAllowed = false;
    _active = null;
    _warmMark = null;
  }

  Future<void> boot({Directory? directory}) async {
    final base = directory ?? await getApplicationSupportDirectory();
    _settings = File('${base.path}/video_buffer.json');
    if (await _settings!.exists()) {
      try {
        final p = jsonDecode(await _settings!.readAsString()) as Map;
        enabled = p['enabled'] != false;
        final capacity = p['capacityMb'];
        if (capacity is num && capacity.isFinite) {
          capacityMb = capacity.toInt().clamp(minCapacityMb, maxCapacityMb);
        }
      } catch (_) {
        /* Keep bounded defaults for damaged settings. */
      }
    }
    _root = Directory('${base.path}/video-buffer-v1');
    try {
      await _root!.create(recursive: true);
      // Tickets and validators are session-owned; never reuse stale signed media.
      await for (final entry in _root!.list(followLinks: false)) {
        if (entry is File) await entry.delete();
      }
    } on FileSystemException {
      _root = null;
      _diskAvailable = false;
      status = '磁盘不可用，使用内核内存缓冲';
    }
    _ready = true;
  }

  Future<void> configure({bool? enabled, int? capacityMb}) async {
    this.enabled = enabled ?? this.enabled;
    if (capacityMb != null) {
      this.capacityMb = capacityMb.clamp(minCapacityMb, maxCapacityMb);
    }
    final settings = _settings;
    final encoded = jsonEncode({
      'enabled': this.enabled,
      'capacityMb': this.capacityMb,
    });
    try {
      await _disk(() async {
        if (settings != null) {
          final temp = File('${settings.path}.tmp');
          await temp.writeAsString(encoded);
          await temp.rename(settings.path);
        }
        await _trim(0);
      });
    } on FileSystemException {
      status = '缓冲设置保存或清理失败，本次参数仅用于当前运行';
      notifyListeners();
      return;
    }
    status = this.enabled ? '磁盘缓冲已启用，下次加载资源生效' : '使用内核内存缓冲';
    notifyListeners();
  }

  static bool _loopback(Uri uri) =>
      ['localhost', '127.0.0.1', '::1'].contains(uri.host);

  Future<PlayerMedia> wrap(PlayerMedia media, {bool force = false}) async {
    if (!_ready ||
        !media.isNetwork ||
        _bypassed.contains(_key(media, -1)) ||
        (!force && !enabled && !_loopback(media.uri))) {
      return media;
    }
    try {
      await (_starting ??= _start());
      final key = _key(media, -1);
      final existing = _ticketKeys[key];
      final ticket =
          existing ??
          base64UrlEncode(
            List.generate(24, (_) => Random.secure().nextInt(256)),
          );
      _tickets[ticket] = media;
      _ticketKeys[key] = ticket;
      // Bounded registry also covers large HLS playlists without retaining URLs forever.
      while (_tickets.length > 12000) {
        final removed = _tickets.remove(_tickets.keys.first)!;
        _ticketKeys.remove(_key(removed, -1));
      }
      return PlayerMedia(
        uri: Uri.parse('http://127.0.0.1:${_server!.port}/$ticket'),
        title: media.title,
      );
    } catch (_) {
      _starting = null;
      status = '缓存服务不可用，使用内核缓冲';
      notifyListeners();
      return media;
    }
  }

  /// A failed local cache transport must not make a reachable origin unplayable.
  Future<void> load(AbstractPlayer player, PlayerMedia media) async {
    final wrapped = await wrap(media);
    try {
      await player.load(wrapped);
      if (wrapped.uri == media.uri || player.snapshot.value.error == null) {
        return;
      }
    } catch (_) {
      if (wrapped.uri == media.uri) rethrow;
    }
    await player.load(media);
    if (player.snapshot.value.error == null) {
      if (_bypassed.length >= 128) _bypassed.remove(_bypassed.first);
      _bypassed.add(_key(media, -1));
      status = '本地缓存连接失败，当前资源已改用内核缓冲';
      notifyListeners();
    }
  }

  Future<void> _start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  /// Extra disk read-ahead is one serial task, only while current playback has
  /// a reserve. It never seeks or changes the player's selected quality.
  void prefetch(
    PlayerMedia media,
    Duration duration, {
    required bool allowed,
    Duration ahead = const Duration(seconds: 300),
  }) {
    _active = media.uri;
    _warmAllowed = allowed;
    final row = _positions[media.uri];
    if (_warming ||
        _root == null ||
        !enabled ||
        !_diskAvailable ||
        !allowed ||
        row == null ||
        duration.inSeconds <= 0) {
      return;
    }
    final mark = (media.uri, row.next, _generation);
    if (_warmMark == mark || (_warmRetry?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _warmMark = mark;
    final window = min(
      capacityMb * blockBytes ~/ 2,
      (row.total / duration.inSeconds * ahead.inSeconds).ceil(),
    );
    final generation = _generation;
    _warming = true;
    unawaited(() async {
      try {
        var position = row.next;
        final end = min(row.total, position + window);
        while (position < end &&
            enabled &&
            _diskAvailable &&
            _warmAllowed &&
            _active == media.uri &&
            generation == _generation) {
          final block = await _read(media, position);
          final next = block.start + block.data.length;
          if (next <= position) break;
          position = next;
        }
      } catch (_) {
        _warmMark = null;
        _warmRetry = DateTime.now().add(const Duration(seconds: 10));
        /* Speculative failures never interrupt current playback. */
      } finally {
        _warming = false;
      }
    }());
  }

  Future<HttpClientResponse> _request(PlayerMedia media, String? range) async {
    var uri = media.uri;
    var headers = Map<String, String>.of(media.headers ?? {});
    for (var redirect = 0; redirect < 6; redirect++) {
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      for (final h in headers.entries) {
        if (![
          'host',
          'range',
          'connection',
          'content-length',
          'accept-encoding',
        ].contains(h.key.toLowerCase())) {
          request.headers.set(h.key, h.value);
        }
      }
      request.headers.set('Accept-Encoding', 'identity');
      if (!headers.keys.any((h) => h.toLowerCase() == 'user-agent') &&
          LumeNet.settings.userAgent.isNotEmpty) {
        request.headers.set('User-Agent', LumeNet.settings.userAgent);
      }
      if (range != null) request.headers.set('Range', range);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final location = response.headers.value('location');
      if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null) {
        _origins[response] = uri;
        return response;
      }
      await response.drain<void>();
      final next = uri.resolve(location);
      if (!['http', 'https'].contains(next.scheme)) {
        throw const HttpException('Invalid media redirect');
      }
      if (next.origin != uri.origin) {
        headers.removeWhere(
          (k, _) => ['authorization', 'cookie'].contains(k.toLowerCase()),
        );
      }
      uri = next;
    }
    throw const HttpException('Too many media redirects');
  }

  String _key(PlayerMedia media, int start) {
    final headers = (media.headers ?? {}).entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              media.uri.toString(),
              [
                for (final h in headers) [h.key, h.value],
              ],
              start,
            ]),
          ),
        )
        .toString();
  }

  Future<_Block> _read(PlayerMedia media, int position) async {
    var start = enabled && _diskAvailable
        ? position ~/ blockBytes * blockBytes
        : position;
    var key = _key(media, start);
    // A local proxy may cap its reply below our block boundary.
    if ((_files[key]?.bytes ?? blockBytes) <= position - start) {
      start = position;
      key = _key(media, start);
    }
    final cached = _files[key];
    if (enabled &&
        cached != null &&
        DateTime.now().difference(cached.used) < const Duration(minutes: 5)) {
      try {
        final data = await cached.file.readAsBytes();
        if (data.length == cached.bytes) {
          if (_files[key] == cached && !_clearing) {
            _files.remove(key);
            _files[key] = (
              file: cached.file,
              bytes: cached.bytes,
              used: DateTime.now(),
              block: cached.block,
            );
          }
          hits++;
          return cached.block.withData(data);
        }
      } on FileSystemException {
        /* A concurrent clear is a cache miss. */
      }
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final task = _fetch(media, start);
    final generation = _generation;
    _pending[key] = task;
    try {
      final block = await task;
      await _store(key, block, generation);
      if (position >= block.start + block.data.length &&
          block.total > position) {
        final tail = await _fetch(media, position);
        await _store(_key(media, position), tail, generation);
        return tail;
      }
      return block;
    } finally {
      _pending.remove(key);
    }
  }

  Future<_Block> _fetch(PlayerMedia media, int start) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _request(
        media,
        'bytes=$start-${start + blockBytes - 1}',
      );
      if ([502, 503, 504].contains(response.statusCode) && attempt == 0) {
        await response.drain<void>();
        continue;
      }
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers.value('content-range') ?? '');
      if (response.statusCode == 416) {
        final total = RegExp(r'^bytes \*/(\d+)$')
            .firstMatch(response.headers.value('content-range') ?? '');
        await response.drain<void>();
        if (total != null) {
          return _Block(
            Uint8List(0),
            start,
            int.parse(total[1]!),
            'application/octet-stream',
            null,
            media.uri,
            null,
          );
        }
        throw const HttpException('媒体代理范围无效');
      }
      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          builder.add(chunk);
          if (builder.length > 8 * blockBytes) throw const _Passthrough();
        }
      } on HttpException {
        // Some local cat servers overstate Content-Length/Range. Only retain
        // bytes actually received, and only when their starting offset is known.
        if (!_loopback(media.uri) || range == null || builder.isEmpty) rethrow;
      }
      final data = builder.takeBytes();
      downloadedBytes += data.length;
      if (![200, 206].contains(response.statusCode)) {
        throw HttpException('媒体代理 HTTP ${response.statusCode}');
      }
      final mime =
          response.headers.contentType?.mimeType ?? 'application/octet-stream';
      if (response.statusCode == 200 && start != 0) throw const _Passthrough();
      if (response.statusCode == 206 &&
          (range == null || int.parse(range[1]!) != start)) {
        throw const HttpException('媒体代理分段起点不匹配');
      }
      final total = range == null ? data.length : int.parse(range[3]!);
      if (data.isEmpty || total < start + data.length) {
        throw const HttpException('媒体代理分段长度无效');
      }
      if (range != null &&
          data.length != int.parse(range[2]!) - start + 1 &&
          !_loopback(media.uri)) {
        throw const HttpException('远端媒体分段不完整');
      }
      return _Block(
        data,
        start,
        total,
        mime,
        response.headers.value('etag') ??
            response.headers.value('last-modified'),
        _origins[response] ?? media.uri,
        response.headers.value('content-encoding'),
      );
    }
    throw const HttpException('媒体代理暂不可用');
  }

  Future<void> _disk(Future<void> Function() work) {
    final task = _diskTail.then((_) => work());
    _diskTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> _store(String key, _Block block, int generation) =>
      _disk(() => _writeBlock(key, block, generation));

  Future<void> _writeBlock(String key, _Block block, int generation) async {
    if (!enabled ||
        _root == null ||
        _clearing ||
        generation != _generation ||
        block.data.isEmpty ||
        _playlist(block) ||
        block.encoding != null) {
      return;
    }
    try {
      if (_spaceChecked == null ||
          DateTime.now().difference(_spaceChecked!) >
              const Duration(seconds: 30)) {
        _spaceChecked = DateTime.now();
        final free = freeSpace != null
            ? await freeSpace!()
            : Platform.isIOS
            ? await const MethodChannel('lumebox/experience')
                  .invokeMethod<int>('freeDiskBytes')
            : null;
        _availableBytes = free;
        if (free != null && free < 256 * blockBytes + block.data.length) {
          _diskAvailable = false;
          status = '可用空间不足，已回退内核内存缓冲';
          notifyListeners();
          return;
        }
        _diskAvailable = true;
      }
      if (_availableBytes != null &&
          _availableBytes! < 256 * blockBytes + block.data.length) {
        _diskAvailable = false;
        status = '可用空间不足，已回退内核内存缓冲';
        notifyListeners();
        return;
      }
      if (!_diskAvailable) return;
      // The queue serializes accounting without doing disk I/O on the UI thread.
      if (generation != _generation || _clearing || !enabled) return;
      await _trim(block.data.length);
      if (generation != _generation || _clearing || !enabled) return;
      final file = File('${_root!.path}/$key');
      final old = _files.remove(key);
      bytes -= old?.bytes ?? 0;
      if (_availableBytes != null) {
        _availableBytes = _availableBytes! + (old?.bytes ?? 0);
      }
      await file.writeAsBytes(block.data, flush: false);
      _files[key] = (
        file: file,
        bytes: block.data.length,
        used: DateTime.now(),
        block: block.withData(Uint8List(0)),
      );
      bytes += block.data.length;
      if (_availableBytes != null) {
        _availableBytes = _availableBytes! - block.data.length;
      }
      status = '磁盘缓冲中';
    } on FileSystemException {
      _diskAvailable = false;
      final partial = File('${_root!.path}/$key');
      try {
        if (await partial.exists()) await partial.delete();
      } on FileSystemException {
        /* Volume unavailable. */
      }
      status = '磁盘写入失败，已回退内核内存缓冲';
    } on PlatformException {
      _diskAvailable = false;
      status = '空间检查失败，使用内核内存缓冲';
    } on MissingPluginException {
      _diskAvailable = false;
      status = '空间检查不可用，使用内核内存缓冲';
    }
    // Large buffers can write many blocks per second; the settings/HUD need only
    // two progress updates per second, not one rebuild per megabyte.
    _progressNotice ??= Timer(const Duration(milliseconds: 500), () {
      _progressNotice = null;
      notifyListeners();
    });
  }

  Future<void> _trim(int incoming) async {
    while (bytes + incoming > capacityMb * blockBytes && _files.isNotEmpty) {
      final key = _files.keys.first;
      final row = _files.remove(key)!;
      bytes -= row.bytes;
      if (await row.file.exists()) await row.file.delete();
      if (_availableBytes != null) {
        _availableBytes = _availableBytes! + row.bytes;
      }
    }
  }

  static bool _playlist(_Block block) =>
      block.mime.contains('mpegurl') ||
      utf8
          .decode(block.data.take(16).toList(), allowMalformed: true)
          .trimLeft()
          .startsWith('#EXTM3U');

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final media = _tickets[request.uri.path.substring(1)];
      if (media == null) {
        response.statusCode = 404;
        return;
      }
      if (!['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 405;
        return;
      }
      final rawRange = request.headers.value('range');
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rawRange ?? '');
      if (rawRange != null &&
          (match == null || (match[1]!.isEmpty && match[2]!.isEmpty))) {
        response.statusCode = 416;
        return;
      }
      var start = match == null || match[1]!.isEmpty ? 0 : int.parse(match[1]!);
      var block = await _read(media, start);
      if (_playlist(block)) {
        // Always refetch playlists. Relative segment, key, map and variant URLs
        // share the same cache while cross-origin credentials stay scoped.
        Future<String> rewrite(String text) async {
          final uri = block.base.resolve(text);
          if (!['http', 'https'].contains(uri.scheme)) return text;
          final headers = Map<String, String>.of(media.headers ?? {});
          if (uri.origin != media.uri.origin) {
            headers.removeWhere(
              (k, _) => ['authorization', 'cookie'].contains(k.toLowerCase()),
            );
          }
          return (await wrap(
            PlayerMedia(uri: uri, headers: headers),
            force: true,
          )).uri.toString();
        }

        Stream<List<int>> manifest = Stream.value(block.data);
        if (block.encoding == 'gzip') {
          manifest = manifest.transform(gzip.decoder);
        }
        if (block.encoding == 'deflate') {
          manifest = manifest.transform(zlib.decoder);
        }
        final decoded = BytesBuilder(copy: false);
        await for (final chunk in manifest) {
          decoded.add(chunk);
          if (decoded.length > blockBytes) throw const HttpException('媒体清单过大');
        }
        final lines = <String>[];
        for (final line in const LineSplitter().convert(
          utf8.decode(decoded.takeBytes()),
        )) {
          if (line.trim().isNotEmpty && !line.startsWith('#')) {
            lines.add(await rewrite(line.trim()));
          } else {
            var result = line;
            for (final m in RegExp(
              r'URI="([^"]+)"',
            ).allMatches(line).toList().reversed) {
              result = result.replaceRange(
                m.start,
                m.end,
                'URI="${await rewrite(m[1]!)}"',
              );
            }
            lines.add(result);
          }
        }
        final body = utf8.encode('${lines.join('\n')}\n');
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.contentLength = body.length;
        if (request.method != 'HEAD') response.add(body);
        return;
      }
      if (match != null && match[1]!.isEmpty) {
        start = max(0, block.total - int.parse(match[2]!));
        block = await _read(media, start);
      }
      final end = match == null || match[2]!.isEmpty || match[1]!.isEmpty
          ? block.total - 1
          : min(int.parse(match[2]!), block.total - 1);
      if (start >= block.total || end < start) {
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */${block.total}');
        return;
      }
      response.statusCode = match == null ? 200 : 206;
      response.headers.set('Content-Type', block.mime);
      response.headers.set('Accept-Ranges', 'bytes');
      if (match != null) {
        response.headers.set(
          'Content-Range',
          'bytes $start-$end/${block.total}',
        );
      }
      if (block.encoding != null) {
        response.headers.set('Content-Encoding', block.encoding!);
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      final total = block.total;
      final validator = block.validator;
      while (start <= end) {
        if (block.total != total ||
            (validator != null &&
                block.validator != null &&
                validator != block.validator)) {
          throw const HttpException('媒体已变化，请重新加载');
        }
        final offset = start - block.start;
        final length = min(block.data.length - offset, end - start + 1);
        if (length <= 0) throw const HttpException('媒体代理没有返回后续数据');
        response.add(block.data.sublist(offset, offset + length));
        await response.flush();
        start += length;
        _positions[media.uri] = (next: start, total: total);
        while (_positions.length > 128) {
          _positions.remove(_positions.keys.first);
        }
        if (start <= end) block = await _read(media, start);
      }
    } on _Passthrough {
      // Non-seekable/large responses remain playable without a disk promise.
      final media = _tickets[request.uri.path.substring(1)]!;
      final upstream = await _request(media, request.headers.value('range'));
      response.statusCode = upstream.statusCode;
      for (final name in [
        'content-type',
        'content-length',
        'content-range',
        'content-encoding',
        'accept-ranges',
      ]) {
        final value = upstream.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      status = '该媒体使用内核缓冲';
      notifyListeners();
      if (request.method != 'HEAD') {
        await response.addStream(upstream);
      } else {
        await upstream.drain<void>();
      }
    } catch (_) {
      // Never include source URLs, cookies or tokens in HTTP error bodies.
      try {
        response.statusCode = 502;
      } catch (_) {
        /* Already streaming. */
      }
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  Future<int> clear() async {
    _generation++;
    _clearing = true;
    stopPrefetch();
    try {
      await _diskTail;
      final freed = bytes;
      for (final row in _files.values) {
        if (await row.file.exists()) await row.file.delete();
      }
      _files.clear();
      bytes = 0;
      _spaceChecked = null;
      _diskAvailable = _root != null;
      status = '播放磁盘缓存已清理';
      return freed;
    } finally {
      _clearing = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    _bypassed.clear();
    _progressNotice?.cancel();
    _ticketKeys.clear();
    _ready = false;
    _client.close(force: true);
    await _server?.close(force: true);
    await clear();
    _progressNotice?.cancel();
    _progressNotice = null;
    _tickets.clear();
    _positions.clear();
  }
}

class _Passthrough implements Exception {
  const _Passthrough();
}

class _Block {
  const _Block(
    this.data,
    this.start,
    this.total,
    this.mime,
    this.validator,
    this.base,
    this.encoding,
  );
  final Uint8List data;
  final int start, total;
  final String mime;
  final String? validator;
  final Uri base;
  final String? encoding;
  _Block withData(Uint8List data) =>
      _Block(data, start, total, mime, validator, base, encoding);
}
