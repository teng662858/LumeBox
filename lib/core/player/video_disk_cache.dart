import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'abstract_player.dart';
import 'hls_ad_filter.dart';
import 'apple_hls_fragments.dart';
import 'playback_diagnostics.dart';
import '../net/lume_net.dart';
import '../net/http_byte_range.dart';
import '../net/http_header_scope.dart';

/// Bounded, session-only HTTP cache shared by all native playback kernels.
/// Credentials stay in memory; local URLs expose only an unguessable ticket.
class VideoDiskCache extends ChangeNotifier {
  VideoDiskCache({@visibleForTesting this._ipHttpsClient}) {
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
  final _detectedFormats = <String, String>{};
  Timer? _progressNotice;
  final _files =
      <String, ({File file, int bytes, DateTime used, _Block block})>{};
  final _pending = <String, Future<_Block>>{};
  http.Client? _ipHttpsClient;
  final _fragments = AppleHlsFragments();
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
  bool skipHlsAds = true;
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
    if (_ready) return;
    final base = directory ?? await getApplicationSupportDirectory();
    _settings = File('${base.path}/video_buffer.json');
    if (await _settings!.exists()) {
      try {
        final p = jsonDecode(await _settings!.readAsString()) as Map;
        enabled = p['enabled'] != false;
        skipHlsAds = p['skipHlsAds'] != false;
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

  Future<void> configure({
    bool? enabled,
    int? capacityMb,
    bool? skipHlsAds,
  }) async {
    this.enabled = enabled ?? this.enabled;
    this.skipHlsAds = skipHlsAds ?? this.skipHlsAds;
    if (capacityMb != null) {
      this.capacityMb = capacityMb.clamp(minCapacityMb, maxCapacityMb);
    }
    final settings = _settings;
    final encoded = jsonEncode({
      'enabled': this.enabled,
      'skipHlsAds': this.skipHlsAds,
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

  Future<PlayerMedia> wrap(
    PlayerMedia media, {
    bool force = false,
    bool inspect = false,
    bool appleHls = false,
  }) async {
    if (!_ready ||
        !media.isNetwork ||
        _bypassed.contains('${_key(media, -1)}/$appleHls')) {
      return media;
    }
    String suffix = _mediaSuffix(media.uri);
    if (inspect && suffix.isEmpty) {
      final detected = await _scriptFormat(media)
          .timeout(const Duration(seconds: 3), onTimeout: () => '');
      if (detected.isNotEmpty) suffix = detected;
    }
    if (appleHls &&
        ['.mkv', '.webm', '.mpd', '.avi', '.flv', '.wmv'].contains(suffix)) {
      throw UnsupportedError(
        '当前内核无法打开该媒体：${suffix.substring(1).toUpperCase()} 封装需要 MPV',
      );
    }
    if (!force && !enabled && !_loopback(media.uri) && suffix != '.m3u8') {
      return media;
    }
    return _ticket(
      media,
      appleHls && suffix == '.m3u8' ? '.apple.m3u8' : suffix,
    );
  }

  // Some resolvers serve an HLS playlist from a PHP URL with an image MIME type.
  // Only a positive content signature changes routing. Stop after the prefix,
  // including when a progressive origin ignores Range.
  Future<String> _scriptFormat(PlayerMedia media) async {
    final key = _key(media, -1);
    final cached = _detectedFormats[key];
    if (cached != null) return cached;
    try {
      final response = await _request(media, null);
      if (response.statusCode ~/ 100 != 2) {
        await response.listen(null).cancel();
        return '';
      }
      final format = await _inspectFormat(
        response.timeout(const Duration(seconds: 3)),
        response.header('content-encoding'),
      );
      if (format.isNotEmpty) {
        if (_detectedFormats.length >= 128) {
          _detectedFormats.remove(_detectedFormats.keys.first);
        }
        _detectedFormats[key] = format;
      }
      return format;
    } catch (_) {
      return '';
    }
  }

  static Stream<List<int>> _decodedBody(Stream<List<int>> body, String? encoding) =>
      switch (encoding?.trim().toLowerCase()) {
        'gzip' => body.transform(gzip.decoder),
        'deflate' => body.transform(zlib.decoder),
        _ => body,
      };

  static Future<String> _inspectFormat(Stream<List<int>> body, String? encoding) async {
    final prefix = BytesBuilder();
    await for (final chunk in _decodedBody(body, encoding)) {
      prefix.add(chunk.take(1024 - prefix.length).toList());
      if (prefix.length >= 1024) break;
    }
    return detectFormat(prefix.takeBytes());
  }

  @visibleForTesting
  static String detectFormat(List<int> prefix) {
    if (prefix.length >= 4 &&
        prefix[0] == 0x1a &&
        prefix[1] == 0x45 &&
        prefix[2] == 0xdf &&
        prefix[3] == 0xa3) {
      return '.mkv';
    }
    final text = utf8
        .decode(prefix, allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .trimLeft();
    if (text.startsWith('#EXTM3U')) return '.m3u8';
    if (RegExp(r'<(?:[A-Za-z0-9_]+:)?MPD(?:\s|>)').hasMatch(text)) {
      return '.mpd';
    }
    return '';
  }

  static String _mediaSuffix(Uri uri) =>
      RegExp(
        r'\.(?:m3u8|mpd|ts|mp4|m4s|mkv|mov|m4a|aac|ac3|mp3|vtt|webvtt|key|webm|flv|avi|wmv|m2ts)$',
      ).stringMatch(uri.path.toLowerCase()) ??
      '';

  Future<PlayerMedia> _ticket(PlayerMedia media, String suffix) async {
    try {
      await (_starting ??= _start());
      final key = _key(media, -1) + suffix;
      final ticket =
          _ticketKeys[key] ??
          base64UrlEncode(
                List.generate(24, (_) => Random.secure().nextInt(256)),
              ) +
              suffix;
      _tickets[ticket] = media;
      _ticketKeys[key] = ticket;
      while (_tickets.length > 12000) {
        final name = _tickets.keys.first;
        final removed = _tickets.remove(name)!;
        final dot = name.indexOf('.');
        _ticketKeys.remove(
          _key(removed, -1) + (dot < 0 ? '' : name.substring(dot)),
        );
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
    final appleHls =
        Platform.isIOS && player.stats.value.engineLabel == 'AVPlayer';
    final wrapped = await wrap(media, inspect: true, appleHls: appleHls);
    try {
      await _loadAndWait(player, wrapped);
      if (wrapped.uri == media.uri || player.snapshot.value.error == null) {
        return;
      }
    } catch (_) {
      if (wrapped.uri == media.uri) rethrow;
    }
    PlaybackDiagnostics.record('cache-fallback-start', uri: media.uri);
    await _loadAndWait(player, media);
    PlaybackDiagnostics.record(
      'cache-fallback-complete',
      uri: media.uri,
      error: player.snapshot.value.error,
    );
    if (player.snapshot.value.error == null) {
      if (_bypassed.length >= 128) _bypassed.remove(_bypassed.first);
      _bypassed.add('${_key(media, -1)}/$appleHls');
      status = '本地缓存连接失败，当前资源已改用内核缓冲';
      notifyListeners();
    }
  }

  static Future<void> _loadAndWait(
    AbstractPlayer player,
    PlayerMedia media,
  ) async {
    await player.load(media);
    final ready = Completer<void>();
    void changed() {
      final snapshot = player.snapshot.value;
      final initialized = player.mediaInitialized;
      if ((initialized || snapshot.error != null) && !ready.isCompleted) {
        ready.complete();
      }
    }

    player.snapshot.addListener(changed);
    try {
      changed();
      // AVPlayer can return from load while its network retry is still pending.
      await ready.future.timeout(const Duration(seconds: 30));
    } finally {
      player.snapshot.removeListener(changed);
    }
  }

  Future<void> _start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      (request) => unawaited(
        _handle(request).catchError((Object _) {
          // Client cancellation and origin failures must never escape the server task.
          PlaybackDiagnostics.record('cache-request-interrupted');
        }),
      ),
    );
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

  Future<_MediaResponse> _request(PlayerMedia media, String? range) async {
    var uri = media.uri;
    final headers =
        <String, String>{
          for (final entry
              in (media.headers ?? const <String, String>{}).entries)
            entry.key.toLowerCase(): entry.value,
        }..removeWhere(
          (key, _) => const {
            'host',
            'range',
            'connection',
            'content-length',
            'accept-encoding',
          }.contains(key),
        );
    headers['accept-encoding'] = 'identity';
    if (LumeNet.settings.userAgent.isNotEmpty) {
      headers.putIfAbsent('user-agent', () => LumeNet.settings.userAgent);
    }
    if (range != null) headers['range'] = range;
    for (var redirect = 0; redirect < 6; redirect++) {
      final _MediaResponse response;
      // Some CDNs terminate TLS if an IP literal is sent as the SNI name.
      // URLSession verifies the IP against the certificate's IP subjectAltName.
      if ((Platform.isIOS || Platform.isMacOS || _ipHttpsClient != null) &&
          uri.scheme == 'https' &&
          InternetAddress.tryParse(uri.host) != null &&
          LumeNet.settings.proxy.trim().isEmpty) {
        final client = _ipHttpsClient ??=
            CupertinoClient.fromSessionConfiguration(
              URLSessionConfiguration.ephemeralSessionConfiguration()
                ..httpShouldSetCookies = false
                ..cache = null,
            );
        final abort = Completer<void>();
        final outgoing =
            http.AbortableRequest('GET', uri, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers.addAll(headers);
        final native = await client
            .send(outgoing)
            .timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                abort.complete();
                throw const HttpException('媒体请求超时');
              },
            );
        // URLSession delivers decompressed bytes even if an origin ignores identity.
        String? header(String name) {
          final encoding = native.headers['content-encoding']?.toLowerCase();
          if (const {'gzip', 'deflate', 'br'}.contains(encoding) &&
              (name == 'content-encoding' || name == 'content-length')) {
            return null;
          }
          return native.headers[name];
        }

        response = _MediaResponse(
          native.stream,
          native.statusCode,
          uri,
          header,
        );
      } else {
        final request = await _client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        final io = await request.close().timeout(const Duration(seconds: 30));
        response = _MediaResponse(io, io.statusCode, uri, io.headers.value);
      }
      final location = response.header('location');
      if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null) {
        return response;
      }
      await response.listen(null).cancel();
      final next = uri.resolve(location);
      if (!['http', 'https'].contains(next.scheme)) {
        throw const HttpException('Invalid media redirect');
      }
      if (next.origin != uri.origin) {
        headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
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

  Future<_Block> _read(
    PlayerMedia media,
    int position, {
    bool playlist = false,
  }) async {
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
    final task = _fetch(media, start, playlist: playlist);
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

  Future<_Block> _fetch(
    PlayerMedia media,
    int start, {
    bool playlist = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _request(
        media,
        playlist || media.uri.path.toLowerCase().endsWith('.m3u8')
            ? null
            : 'bytes=$start-${start + blockBytes - 1}',
      );
      if ([502, 503, 504].contains(response.statusCode) && attempt == 0) {
        await response.drain<void>();
        continue;
      }
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.header('content-range') ?? '');
      if (response.statusCode >= 400) {
        PlaybackDiagnostics.record(
          'cache-upstream-failed',
          uri: media.uri,
          error: 'HTTP ${response.statusCode}',
        );
      }
      if (response.statusCode == 416) {
        final total = RegExp(r'^bytes \*/(\d+)$')
            .firstMatch(response.header('content-range') ?? '');
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
      if (response.statusCode >= 400) {
        // Preserve upstream access errors. Turning HTTP 400/403/404 into 502
        // makes native kernels retry a request that can never succeed.
        final status = response.statusCode;
        await response.listen(null).cancel();
        throw _UpstreamStatus(status);
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
          response
              .header('content-type')
              ?.split(';')
              .first
              .trim()
              .toLowerCase() ??
          'application/octet-stream';
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
        response.header('etag') ?? response.header('last-modified'),
        response.uri,
        response.header('content-encoding'),
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

  Future<Uint8List> _segmentBytes(
    PlayerMedia media,
    int limit, {
    bool prefix = false,
  }) async {
    // Read a bounded decoded prefix. Byte ranges apply to the encoded
    // representation and some segment endpoints reject Range altogether.
    final upstream = await _request(media, null);
    if (upstream.statusCode != 200 && upstream.statusCode != 206) {
      await upstream.listen(null).cancel();
      throw _UpstreamStatus(upstream.statusCode);
    }
    final body = BytesBuilder(copy: false);
    final decoded = _decodedBody(upstream, upstream.header('content-encoding'));
    await for (final chunk in decoded.timeout(const Duration(seconds: 20))) {
      if (prefix && chunk.length >= limit - body.length) {
        body.add(chunk.sublist(0, limit - body.length));
        break;
      }
      if (chunk.length > limit - body.length) {
        throw const FormatException('视频分片过大');
      }
      body.add(chunk);
    }
    final bytes = body.takeBytes();
    return Uint8List.sublistView(bytes, transportStreamImagePrefix(bytes));
  }

  /// Forward playable bytes before filling a disk block. Keeping the native
  /// HTTP reader behind a complete 1 MiB download delays every playback kernel.
  Future<bool> _streamMedia(
    HttpRequest request,
    PlayerMedia media,
    bool segment,
  ) async {
    final generation = _generation;
    final rangeHeader = request.headers.value('range');
    var upstream = await _request(media, rangeHeader);
    if ([502, 503, 504].contains(upstream.statusCode)) {
      await upstream.listen(null).cancel();
      upstream = await _request(media, rangeHeader);
    }
    if (upstream.statusCode >= 400) {
      final contentRange = upstream.header('content-range');
      if (upstream.statusCode == 416 &&
          contentRange != null &&
          RegExp(r'^bytes \*/\d+$').hasMatch(contentRange)) {
        request.response.headers.set('Content-Range', contentRange);
      }
      await upstream.listen(null).cancel();
      throw _UpstreamStatus(upstream.statusCode);
    }
    final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(upstream.header('content-range') ?? '');
    final length = int.tryParse(upstream.header('content-length') ?? '');
    final partial = upstream.statusCode == 206;
    final start = partial ? int.tryParse(range?[1] ?? '') ?? -1 : 0;
    final end = int.tryParse(range?[2] ?? '');
    final total = partial ? int.tryParse(range?[3] ?? '') : length;
    final expected = partial && total != null
        ? parseHttpByteRange(rangeHeader ?? 'bytes=0-', total)
        : null;
    if (![200, 206].contains(upstream.statusCode) ||
        partial &&
            (expected == null ||
                start != expected.start ||
                end != expected.end ||
                length != null && length != expected.end - start + 1)) {
      // Preserve the established repair path for capped/misdeclared local proxies.
      await upstream.listen(null).cancel();
      return false;
    }
    final chunks = StreamIterator(
      upstream.timeout(const Duration(seconds: 30)),
    );
    final prefix = BytesBuilder(copy: false);
    final cached = BytesBuilder(copy: false);
    var received = 0;
    void capture(List<int> bytes) {
      received += bytes.length;
      downloadedBytes += bytes.length;
    }

    var cachedStart = 0;
    Future<void> storeCaptured() async {
      if (cached.isEmpty) return;
      final bytes = cached.takeBytes();
      final offset = cachedStart;
      cachedStart += bytes.length;
      await _store(
        _key(media, offset),
        _Block(
          bytes,
          offset,
          total ?? received,
          upstream.header('content-type') ?? 'application/octet-stream',
          upstream.header('etag') ?? upstream.header('last-modified'),
          upstream.uri,
          upstream.header('content-encoding'),
        ),
        generation,
      ).catchError((Object _) {});
    }

    Future<void> persist(List<int> bytes) async {
      if (start != 0 || generation != _generation || !enabled) return;
      if (total == null && cached.length == blockBytes) return;
      var offset = 0;
      while (offset < bytes.length) {
        final end = min(offset + blockBytes - cached.length, bytes.length);
        cached.add(bytes.sublist(offset, end));
        offset = end;
        if (cached.length == blockBytes) {
          // An unknown-length stream cannot advertise correct seek totals yet.
          // Retain only its first block until EOF establishes that total.
          if (total == null) return;
          await storeCaptured();
        }
      }
    }

    var skipped = 0;
    try {
      if (!segment) {
        // A resolver can return an HLS manifest from an MP4-labelled URL.
        // Keep the established manifest rewrite instead of forwarding relative
        // child URLs against the opaque local ticket address.
        while (prefix.length < 16 && await chunks.moveNext()) {
          capture(chunks.current);
          prefix.add(chunks.current);
        }
        if (_playlist(
          _Block(
            prefix.toBytes(),
            0,
            total ?? received,
            upstream.header('content-type') ?? '',
            null,
            upstream.uri,
            null,
          ),
        )) {
          return false;
        }
      }
      if (segment && upstream.header('content-encoding') == null) {
        // Normal TS/encrypted bytes pass after 8 bytes. A PNG wrapper needs
        // four aligned TS packets; inspect only the bounded prefix, not EOF.
        const png = [137, 80, 78, 71, 13, 10, 26, 10];
        while (await chunks.moveNext()) {
          capture(chunks.current);
          prefix.add(chunks.current);
          if (prefix.length < 8) continue;
          final bytes = prefix.toBytes();
          if (!listEquals(bytes.take(8).toList(), png)) break;
          skipped = transportStreamImagePrefix(bytes);
          if (skipped > 0 || prefix.length >= transportStreamProbeLength) break;
        }
      }
      final response = request.response;
      response.statusCode = rangeHeader == null ? 200 : upstream.statusCode;
      response.headers.set(
        'Content-Type',
        segment
            ? 'video/mp2t'
            : upstream.header('content-type') ?? 'application/octet-stream',
      );
      for (final name in ['content-encoding', 'accept-ranges']) {
        final value = upstream.header(name);
        if (value != null) response.headers.set(name, value);
      }
      if (rangeHeader != null && partial) {
        response.headers.set(
          'Content-Range',
          upstream.header('content-range')!,
        );
      }
      if (length != null) response.contentLength = length - skipped;
      response.bufferOutput = false;
      if (prefix.isNotEmpty) {
        final bytes = prefix.takeBytes();
        response.add(Uint8List.sublistView(bytes, skipped));
        await response.flush();
        await persist(bytes);
      }
      while (await chunks.moveNext()) {
        capture(chunks.current);
        response.add(chunks.current);
        await response.flush();
        await persist(chunks.current);
      }
      if (length != null && received != length) {
        throw const HttpException('媒体流长度不完整');
      }
      if (start == 0 && cached.isNotEmpty) {
        await storeCaptured();
      }
      return true;
    } finally {
      await chunks.cancel();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var streaming = false;
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
      final path = request.uri.path;
      if (path.endsWith('.init.mp4') || path.endsWith('.frag.m4s')) {
        final sequence = int.tryParse(request.uri.queryParameters['n'] ?? '');
        if (sequence == null || sequence < 1 || sequence > 0x7fffffff) {
          response.statusCode = 400;
          return;
        }
        final key = '${_key(media, -1)}/$sequence';
        final bytes = await _fragments.get(
          key,
          sequence,
          path.endsWith('.init.mp4'),
          () => _segmentBytes(media, AppleHlsFragments.maxSegmentBytes),
        );
        AppleHlsFragments.serve(request, bytes);
        return;
      }
      final rawRange = request.headers.value('range');
      final match = RegExp(
        r'^bytes=(\d*)-(\d*)$',
        caseSensitive: false,
      ).firstMatch(rawRange?.trim() ?? '');
      if (rawRange != null &&
          (match == null || (match[1]!.isEmpty && match[2]!.isEmpty))) {
        response.statusCode = 416;
        return;
      }
      // If the offset exceeds the integer range, obtain the length from block
      // zero so the client still gets the actual unsatisfied Content-Range.
      var start = int.tryParse(match?[1] ?? '') ?? 0;
      if (start > 0x7fffffffffffffff - blockBytes) start = 0;
      final segment = path.endsWith('.ts');
      final canStream =
          segment ||
          [
            '.mp4',
            '.mkv',
            '.m4s',
            '.key',
            '.vtt',
            '.webvtt',
            '.webm',
            '.mov',
            '.mp3',
            '.m4a',
          ].any(path.endsWith);
      final cached = _files[_key(media, start ~/ blockBytes * blockBytes)];
      if (request.method == 'GET' &&
          canStream &&
          (rawRange == null || !segment && !_loopback(media.uri)) &&
          !(enabled &&
              (cached?.bytes ?? 0) >=
                  min(
                    65536,
                    cached == null
                        ? 65536
                        : cached.block.total - cached.block.start,
                  ))) {
        if (await _streamMedia(request, media, segment)) return;
      }
      var block = await _read(
        media,
        path.endsWith('.m3u8') || segment ? 0 : start,
        playlist: path.endsWith('.m3u8'),
      );
      if (_playlist(block) ||
          path.endsWith('.m3u8') && block.encoding != null &&
              await _inspectFormat(Stream.value(block.data), block.encoding) == '.m3u8') {
        // Always refetch playlists. Relative segment, key, map and variant URLs
        // share the same cache while cross-origin credentials stay scoped.
        PlayerMedia? childMedia(String text) {
          final uri = block.base.resolve(text);
          if (!['http', 'https'].contains(uri.scheme)) return null;
          final headers = Map<String, String>.of(media.headers ?? {});
          if (uri.origin != media.uri.origin) {
            headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
          }
          return PlayerMedia(uri: uri, headers: headers);
        }

        final apple = path.endsWith('.apple.m3u8');
        Future<String> rewrite(
          String text,
          String fallback, {
          int? sequence,
        }) async {
          final child = childMedia(text);
          if (child == null) return text;
          var suffix = _mediaSuffix(child.uri);
          if (sequence != null || suffix.isEmpty || fallback == '.m3u8') {
            suffix = fallback;
          }
          if (apple && suffix == '.m3u8') suffix = '.apple.m3u8';
          var uri = (await _ticket(child, suffix)).uri;
          if (sequence != null) {
            uri = uri.replace(queryParameters: {'n': '$sequence'});
          }
          return uri.toString();
        }

        final manifest = _decodedBody(Stream.value(block.data), block.encoding);
        final decoded = BytesBuilder(copy: false);
        await for (final chunk in manifest) {
          decoded.add(chunk);
          if (decoded.length > blockBytes) throw const HttpException('媒体清单过大');
        }
        final lines = <String>[];
        final rawManifest = utf8.decode(decoded.takeBytes());
        final manifestText = skipHlsAds
            ? HlsAdFilter.filter(rawManifest)
            : rawManifest;
        final master = manifestText.contains('#EXT-X-STREAM-INF:');
        final mapped = manifestText.contains('#EXT-X-MAP:');
        final original = const LineSplitter().convert(manifestText);
        bool isResource(String line) =>
            line.trim().isNotEmpty && !line.trimLeft().startsWith('#');
        final first = original.where(isResource).firstOrNull;
        var fragment = false;
        if (apple &&
            !master &&
            !mapped &&
            first != null &&
            original.contains('#EXT-X-ENDLIST') &&
            !original.any(
              (l) =>
                  l.startsWith('#EXT-X-KEY:') ||
                  l.startsWith('#EXT-X-BYTERANGE:') ||
                  l.startsWith('#EXT-X-DISCONTINUITY') ||
                  l.startsWith('#EXT-X-GAP'),
            )) {
          final child = childMedia(first.trim());
          if (child != null) {
            try {
              fragment = transportStreamHasHevc(
                await _segmentBytes(child, 16384, prefix: true),
              );
            } catch (_) {
              /* An inconclusive probe keeps the original transport. */
            }
          }
        }
        if (fragment) {
          PlaybackDiagnostics.record('hls-hevc-ts-to-fmp4', uri: media.uri);
        }
        var sequence = 0;
        for (final line in original) {
          if (fragment && line == '#EXTM3U') {
            lines.addAll([
              line,
              '#EXT-X-VERSION:7',
              '#EXT-X-MAP:URI="${await rewrite(first!.trim(), '.init.mp4', sequence: 1)}"',
            ]);
          } else if (fragment && line.startsWith('#EXT-X-VERSION:')) {
            continue;
          } else if (isResource(line)) {
            if (fragment) {
              sequence++;
              lines.add(
                await rewrite(line.trim(), '.frag.m4s', sequence: sequence),
              );
            } else {
              lines.add(
                await rewrite(
                  line.trim(),
                  master
                      ? '.m3u8'
                      : mapped
                      ? '.m4s'
                      : '.ts',
                ),
              );
            }
          } else {
            var result = line;
            for (final m in RegExp(
              r'URI="([^"]+)"',
            ).allMatches(line).toList().reversed) {
              final attributeSuffix = switch (line.split(':').first) {
                '#EXT-X-KEY' || '#EXT-X-SESSION-KEY' => '.key',
                '#EXT-X-MAP' => '.mp4',
                '#EXT-X-MEDIA' ||
                '#EXT-X-I-FRAME-STREAM-INF' ||
                '#EXT-X-RENDITION-REPORT' => '.m3u8',
                '#EXT-X-PART' => '.m4s',
                _ => '',
              };
              result = result.replaceRange(
                m.start,
                m.end,
                'URI="${await rewrite(m[1]!, attributeSuffix)}"',
              );
            }
            lines.add(result);
          }
        }
        final body = utf8.encode('${lines.join('\n')}\n');
        serveHttpBytes(request, body, 'application/vnd.apple.mpegurl');
        return;
      }
      final prefixBytes = segment ? transportStreamImagePrefix(block.data) : 0;
      final mediaTotal = block.total - prefixBytes;
      final offsets = rawRange == null
          ? null
          : parseHttpByteRange(rawRange, mediaTotal);
      if (rawRange != null && offsets == null) {
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */$mediaTotal');
        return;
      }
      start = offsets?.start ?? 0;
      final end = offsets?.end ?? mediaTotal - 1;
      response.statusCode = offsets == null ? 200 : 206;
      response.headers.set('Content-Type', segment ? 'video/mp2t' : block.mime);
      response.headers.set('Accept-Ranges', 'bytes');
      if (match != null) {
        response.headers.set('Content-Range', 'bytes $start-$end/$mediaTotal');
      }
      if (block.encoding != null) {
        response.headers.set('Content-Encoding', block.encoding!);
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      final total = block.total;
      final validator = block.validator;
      start += prefixBytes;
      final physicalEnd = end + prefixBytes;
      if (start < block.start || start >= block.start + block.data.length) {
        block = await _read(media, start);
      }
      while (start <= physicalEnd) {
        if (block.total != total ||
            (validator != null &&
                block.validator != null &&
                validator != block.validator)) {
          throw const HttpException('媒体已变化，请重新加载');
        }
        final offset = start - block.start;
        final length = min(block.data.length - offset, physicalEnd - start + 1);
        if (length <= 0) throw const HttpException('媒体代理没有返回后续数据');
        response.add(block.data.sublist(offset, offset + length));
        streaming = true;
        await response.flush();
        start += length;
        _positions[media.uri] = (next: start, total: total);
        while (_positions.length > 128) {
          _positions.remove(_positions.keys.first);
        }
        if (start <= physicalEnd) block = await _read(media, start);
      }
    } on _Passthrough {
      if (streaming) {
        PlaybackDiagnostics.record(
          'cache-stream-interrupted',
          error: '源在分段传输中改变了响应方式',
        );
        return;
      }
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
        final value = upstream.header(name);
        if (value != null) response.headers.set(name, value);
      }
      if (request.uri.path.endsWith('.ts') && upstream.statusCode ~/ 100 == 2) {
        response.headers.set('Content-Type', 'video/mp2t');
      }
      status = '该媒体使用内核缓冲';
      notifyListeners();
      if (request.method != 'HEAD') {
        await response.addStream(upstream);
      } else {
        await upstream.drain<void>();
      }
    } on _UpstreamStatus catch (error) {
      // The first range may have been sent before the next range returned 403
      // or 404. HTTP cannot replace an already-sent status; close the partial
      // response and let the player re-resolve the source instead.
      if (!streaming) {
        try {
          response.statusCode = error.status;
        } catch (_) {}
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
    _detectedFormats.clear();
    _progressNotice?.cancel();
    _ticketKeys.clear();
    _ready = false;
    _client.close(force: true);
    _ipHttpsClient?.close();
    await _server?.close(force: true);
    await clear();
    _progressNotice?.cancel();
    _progressNotice = null;
    _tickets.clear();
    _positions.clear();
  }
}

class _MediaResponse extends StreamView<List<int>> {
  _MediaResponse(super.stream, this.statusCode, this.uri, this.header);
  final int statusCode;
  final Uri uri;
  final String? Function(String name) header;
}

class _UpstreamStatus implements Exception {
  const _UpstreamStatus(this.status);
  final int status;
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
