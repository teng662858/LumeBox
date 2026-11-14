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
import 'package:xml/xml.dart';

import 'abstract_player.dart';
import 'hls_ad_filter.dart';
import 'hls_attributes.dart';
import 'apple_hls_fragments.dart';
import 'playback_diagnostics.dart';
import '../net/lume_net.dart';
import '../net/http_byte_range.dart';
import '../net/http_header_scope.dart';
import '../net/media_range_response.dart';

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
  Future<void>? _booting;
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

  Future<void> boot({Directory? directory}) {
    if (_ready && _root != null) return Future.value();
    return _booting ??= _openDisk(directory).whenComplete(() => _booting = null);
  }

  Future<void> _openDisk(Directory? directory) async {
    try {
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
      final root = await Directory('${base.path}/video-buffer-v1').create(recursive: true);
      // Tickets and validators are session-owned; never reuse stale signed media.
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File) await entry.delete();
      }
      _root = root;
      if (!_diskAvailable) status = '磁盘缓存已恢复';
      _diskAvailable = true;
    } on Exception {
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
    if (!force && !enabled && !_loopback(media.uri) &&
        suffix != '.m3u8' && suffix != '.mpd') {
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
      final type = response.header('content-type')?.split(';').first.trim().toLowerCase();
      final String format;
      if (type == 'application/dash+xml' || type == 'text/vtt') {
        await response.listen(null).cancel();
        format = type == 'text/vtt' ? '.vtt' : '.mpd';
      } else {
        format = await _inspectFormat(
          _completeBody(response).timeout(const Duration(seconds: 3)),
          response.header('content-encoding'),
        );
      }
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

  static Future<String> detectFileFormat(File file) async {
    final input = await file.open();
    try {
      return detectFormat(await input.read(1024));
    } finally {
      await input.close();
    }
  }

  static bool _matroskaPrefix(List<int> prefix) =>
      prefix.length >= 4 &&
      prefix[0] == 0x1a &&
      prefix[1] == 0x45 &&
      prefix[2] == 0xdf &&
      prefix[3] == 0xa3;

  static String detectFormat(List<int> prefix) {
    if (_matroskaPrefix(prefix)) return '.mkv';
    final text = utf8
        .decode(prefix, allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .trimLeft();
    if (text.startsWith('#EXTM3U')) return '.m3u8';
    if (RegExp(r'^WEBVTT(?:[ \t\r\n]|$)').hasMatch(text)) return '.vtt';
    if (text.startsWith('<') &&
        RegExp(r'<(?:[A-Za-z0-9_.-]+:)?MPD(?:\s|/?>)').hasMatch(text)) {
      return '.mpd';
    }
    return '';
  }

  static String _mediaSuffix(Uri uri) =>
      RegExp(
        r'\.(?:m3u8|mpd|ts|mp4|m4s|mkv|mov|m4a|aac|ac3|ec3|eac3|mp3|vtt|webvtt|key|webm|flv|avi|wmv|m2ts)$',
      ).stringMatch(uri.path.toLowerCase()) ??
      '';

  static String _responseType(String path, String? original) {
    if (path.endsWith('.ts')) return 'video/mp2t';
    if (path.endsWith('.vtt') || path.endsWith('.webvtt')) return 'text/vtt';
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    if (path.endsWith('.ac3')) return 'audio/ac3';
    if (path.endsWith('.ec3') || path.endsWith('.eac3')) return 'audio/eac3';
    return original ?? 'application/octet-stream';
  }

  static bool _packedAudio(String path) =>
      const ['.aac', '.ac3', '.ec3', '.eac3', '.mp3'].any(path.endsWith);

  static bool _isHlsAudioSegment(String path) =>
      path.contains('.hls.') && _packedAudio(path);

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

  Future<MediaRangeResponse> _request(PlayerMedia media, String? range) async {
    var uri = media.uri;
    final headers =
        <String, String>{
          for (final entry
              in (media.headers ?? const <String, String>{}).entries)
            if (!isMediaTransportHeader(entry.key)) entry.key.toLowerCase(): entry.value,
        };
    headers['accept-encoding'] = 'identity';
    if (LumeNet.settings.userAgent.isNotEmpty) {
      headers.putIfAbsent('user-agent', () => LumeNet.settings.userAgent);
    }
    if (range != null) headers['range'] = range;
    for (var redirect = 0; redirect < 6; redirect++) {
      final MediaRangeResponse response;
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

        response = MediaRangeResponse(
          native.stream,
          native.statusCode,
          uri,
          header,
            headers,
        );
      } else {
        final request = await _client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        final io = await request.close().timeout(const Duration(seconds: 30));
        response = MediaRangeResponse(io, io.statusCode, uri, io.headers.value, headers);
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
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              media.uri.toString(),
              [
                for (final h in headers) [h.key, h.value],
              ],
            ]),
          ),
        )
        .toString();
    return start < 0 ? identity : '$identity-$start';
  }

  Future<void> _discardChangedMedia(PlayerMedia media) {
    final identity = _key(media, -1);
    final prefix = '$identity-';
    _generation++;
    _pending.removeWhere((key, _) => key.startsWith(prefix));
    _detectedFormats.remove(identity);
    _positions.remove(media.uri);
    return _disk(() async {
      final keys = _files.keys.where((key) => key.startsWith(prefix)).toList();
      for (final key in keys) {
        final row = _files.remove(key)!;
        bytes -= row.bytes;
        try {
          await row.file.delete();
        } on FileSystemException {
          // An inaccessible stale block must still be removed from the index.
        }
      }
      _spaceChecked = null;
    });
  }

  Future<_Block> _read(
    PlayerMedia media,
    int position, {
    bool playlist = false,
  }) async {
    var start = enabled && _diskAvailable
        ? position ~/ blockBytes * blockBytes
        : position;
    // A local proxy may cap its reply below our block boundary.
    if (position != start &&
        (_files[_key(media, start)]?.bytes ?? blockBytes) <= position - start) {
      start = position;
    }
    final block = await _readBlock(media, start, playlist: playlist);
    if (position != start &&
        position >= block.start + block.data.length &&
        block.total > position) {
      return _readBlock(media, position, playlist: playlist);
    }
    return block;
  }

  // Share only the block at this exact offset. Concurrent readers can need
  // different tails when the origin caps the aligned block.
  Future<_Block> _readBlock(
    PlayerMedia media,
    int start, {
    required bool playlist,
  }) async {
    final key = _key(media, start);
    final cached = await _cachedBlock(key);
    if (cached != null) return cached;
    final pending = _pending[key];
    if (pending != null) return pending;
    final task = _fetch(media, start, playlist: playlist);
    final generation = _generation;
    _pending[key] = task;
    try {
      final block = await task;
      await _store(key, block, generation);
      return block;
    } finally {
      if (identical(_pending[key], task)) _pending.remove(key);
    }
  }

  Future<_Block?> _cachedBlock(String key) async {
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
    return null;
  }

  // A partial response may omit the total. A one-byte suffix gives its
  // absolute final offset without transferring the entire video.
  Future<int?> _rangeTotal(
    MediaRangeResponse response,
    RegExpMatch range,
  ) async {
    if (range[3] != '*') return int.tryParse(range[3]!);
    final probe = await _request(PlayerMedia(uri: response.uri, headers: response.requestHeaders), 'bytes=-1');
    try {
      if (probe.uri.removeFragment() != response.uri.removeFragment()) {
        throw const HttpException('媒体已变化，请重新加载');
      }
      for (final header in ['etag', 'last-modified', 'content-encoding']) {
        final original = response.header(header);
        final latest = probe.header(header);
        if (original != latest &&
            (header == 'content-encoding' || original != null && latest != null)) {
          throw const HttpException('媒体已变化，请重新加载');
        }
      }
      if (probe.statusCode == 200) {
        return int.tryParse(probe.header('content-length') ?? '');
      }
      if (probe.statusCode != 206) return null;
      final suffix = mediaContentRange.firstMatch(probe.header('content-range') ?? '');
      final end = int.tryParse(suffix?[2] ?? '');
      if (end == null ||
          end == 0x7fffffffffffffff ||
          int.tryParse(suffix![1]!) != end ||
          (suffix[3] != '*' && int.tryParse(suffix[3]!) != end + 1)) {
        return null;
      }
      return end + 1;
    } finally {
      await probe.listen(null).cancel();
    }
  }

  Future<_Block> _fetch(
    PlayerMedia media,
    int start, {
    bool playlist = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      var response = await _request(
        media,
        playlist || media.uri.path.toLowerCase().endsWith('.m3u8')
            ? null
            : 'bytes=$start-${start + blockBytes - 1}',
      );
      if (_packedAudio(media.uri.path.toLowerCase()) &&
          const [400, 403, 405, 416].contains(response.statusCode)) {
        await response.listen(null).cancel();
        response = await _request(media, null);
      }
      if ([502, 503, 504].contains(response.statusCode) && attempt == 0) {
        await response.listen(null).cancel();
        continue;
      }
      final range = mediaContentRange.firstMatch(response.header('content-range') ?? '');
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
        await response.listen(null).cancel();
        if (total != null) {
          return _Block(
            Uint8List(0),
            start,
            int.parse(total[1]!),
            'application/octet-stream',
            null,
            response.uri,
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
      // Check the representation's first bytes before the large-body
      // passthrough or any write to the block cache.
      final prefix = <int>[];
      final inspectPrefix = response.statusCode == 200 || range?[1] == '0';
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (inspectPrefix && prefix.length < 80) {
            prefix.addAll(chunk.take(80 - prefix.length));
            _rejectHtml(prefix);
          }
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
      // A CDN may cap even an ordinary playlist GET. Rewriting a prefix can
      // silently discard variants, keys and the end of a media playlist.
      if (start == 0 && response.statusCode == 206 &&
          (playlist || media.uri.path.toLowerCase().endsWith('.m3u8') ||
              mime.contains('mpegurl') || _playlistSignature(data))) {
        final first = MediaRangeResponse(
          Stream.value(data), 206, response.uri, response.header, response.requestHeaders,
        );
        final complete = BytesBuilder(copy: false);
        var keepOriginHeaders = first.hasOriginHeaders;
        await for (final part in _completeBody(first, playlistPart: (response) {
          keepOriginHeaders = keepOriginHeaders && response.hasOriginHeaders;
        }).timeout(const Duration(seconds: 30))) {
          if (complete.length + part.length > 8 * blockBytes) {
            throw const HttpException('媒体清单过大');
          }
          complete.add(part);
        }
        downloadedBytes += complete.length - data.length;
        final manifest = complete.takeBytes();
        return _Block(manifest, 0, manifest.length, mime,
            response.header('etag') ?? response.header('last-modified'),
            response.uri, response.header('content-encoding'), keepOriginHeaders: keepOriginHeaders);
      }
      if (response.statusCode == 200 && start > 0 && _packedAudio(media.uri.path.toLowerCase())) {
        return _Block(
          Uint8List.sublistView(data, min(start, data.length)),
          start, data.length, mime,
          response.header('etag') ?? response.header('last-modified'),
          response.uri, response.header('content-encoding'),
        );
      }
      if (response.statusCode == 200 && start != 0) throw const _Passthrough();
      if (response.statusCode == 206 &&
          (range == null || int.parse(range[1]!) != start)) {
        throw const HttpException('媒体代理分段起点不匹配');
      }
      final total = range == null ? data.length : await _rangeTotal(response, range);
      final declaredEnd = int.tryParse(range?[2] ?? '');
      if (data.isEmpty || total == null || total < start + data.length ||
          (range != null && (declaredEnd == null || declaredEnd < start || declaredEnd >= total))) {
        throw const HttpException('媒体代理分段长度无效');
      }
      if (range != null &&
          data.length != declaredEnd! - start + 1 &&
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
        keepOriginHeaders: response.hasOriginHeaders,
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
      block.mime.contains('mpegurl') || _playlistSignature(block.data);

  static void _rejectHtml(List<int> bytes) {
    final text = utf8.decode(bytes.take(80).toList(), allowMalformed: true)
        .trimLeft().toLowerCase();
    if (text.startsWith('<!doctype html') || text.startsWith('<html')) {
      throw const FormatException('媒体地址返回了网页');
    }
  }

  static bool _playlistSignature(List<int> bytes) =>
      utf8
          .decode(bytes.take(16).toList(), allowMalformed: true)
          .trimLeft()
          .startsWith('#EXTM3U');

  Future<_Block> _probeTsPrefix(PlayerMedia media, _Block first) async {
    final limit = min(first.total, transportStreamProbeLength);
    if (first.encoding != null || first.data.length >= limit ||
        !couldStartWithPng(first.data) || transportStreamImagePrefix(first.data) > 0) {
      return first;
    }
    // Some origins return only a few bytes per range. Assemble enough of the
    // same representation to establish the logical offsets before sending headers.
    final bytes = Uint8List(limit)..setRange(0, first.data.length, first.data);
    var filled = first.data.length;
    var nextCheck = max(1024, filled * 2);
    var validator = first.validator;
    while (filled < limit) {
      final part = await _read(media, filled);
      if (!first.sameRepresentation(part, validator)) {
        await _discardChangedMedia(media);
        throw const HttpException('媒体已变化，请重新加载');
      }
      validator ??= part.validator;
      final offset = filled - part.start;
      final length = min(limit - filled, part.data.length - offset);
      if (offset < 0 || length <= 0) throw const HttpException('媒体分片前缀不完整');
      bytes.setRange(filled, filled + length, part.data, offset);
      filled += length;
      final prefix = Uint8List.sublistView(bytes, 0, filled);
      if (!couldStartWithPng(prefix)) break;
      if (filled >= nextCheck) {
        if (transportStreamImagePrefix(prefix) > 0) break;
        nextCheck = filled * 2;
      }
    }
    return _Block(Uint8List.sublistView(bytes, 0, filled), 0, first.total,
        first.mime, validator, first.base, first.encoding);
  }

  Stream<List<int>> _completeBody(
    MediaRangeResponse first, {
    void Function(MediaRangeResponse)? playlistPart,
  }) => completeMediaBody(
    first,
    allowRedirects: playlistPart != null,
    playlistPart: playlistPart,
    next: (part, offset) => _request(
      PlayerMedia(uri: part.uri, headers: part.requestHeaders),
      'bytes=$offset-',
    ),
  );

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
    final decoded = _decodedBody(_completeBody(upstream), upstream.header('content-encoding'));
    // Measure the probe and remux limits in actual TS bytes, after any
    // verified image wrapper. Ordinary TS still streams from the first chunk.
    await for (final chunk in unwrapTransportStream(decoded.timeout(const Duration(seconds: 20)))) {
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
    _rejectHtml(bytes);
    return bytes;
  }

  static String _keySuffix(String line) {
    final attributes = hlsRawAttributes(line);
    final format = hlsAttributeValue(attributes['KEYFORMAT'] ?? 'identity');
    return attributes['METHOD'] == 'AES-128' && format == 'identity'
        ? '.identity.key'
        : '.key';
  }

  Future<Uint8List> _identityKey(PlayerMedia media) async {
    var response = await _request(media, null);
    if (const [502, 503, 504].contains(response.statusCode)) {
      await response.listen(null).cancel();
      response = await _request(media, null);
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.listen(null).cancel();
      throw _UpstreamStatus(response.statusCode);
    }
    final key = Uint8List(16);
    var offset = 0;
    final body = _decodedBody(_completeBody(response), response.header('content-encoding'));
    await for (final chunk in body.timeout(const Duration(seconds: 20))) {
      if (chunk.length > key.length - offset) throw const FormatException('HLS 密钥长度无效');
      key.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (offset != key.length) throw const FormatException('HLS 密钥不完整');
    return key;
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
    if (rangeHeader != null && _packedAudio(request.uri.path) &&
        const [400, 403, 405, 416].contains(upstream.statusCode)) {
      await upstream.listen(null).cancel();
      if (!_isHlsAudioSegment(request.uri.path)) return false;
      upstream = await _request(media, null);
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
    final range = mediaContentRange.firstMatch(upstream.header('content-range') ?? '');
    final length = int.tryParse(upstream.header('content-length') ?? '');
    final partial = upstream.statusCode == 206;
    final start = partial ? int.tryParse(range?[1] ?? '') ?? -1 : 0;
    final end = int.tryParse(range?[2] ?? '');
    final total = partial ? int.tryParse(range?[3] ?? '') : length;
    var expected = partial && total != null
        ? parseHttpByteRange(rangeHeader ?? 'bytes=0-', total)
        : null;
    if (partial &&
        range?[3] == '*' &&
        end != null &&
        end >= start &&
        start >= 0 &&
        end < 0x7fffffffffffffff &&
        rangeHeader != null) {
      // The origin can serve a requested interval without knowing EOF.
      // A suffix still needs the final offset, which the block path probes.
      final asked = RegExp(r'^bytes=(\d+)-(\d*)$', caseSensitive: false)
          .firstMatch(rangeHeader.trim());
      final limit = int.tryParse(asked?[2] ?? '');
      if (int.tryParse(asked?[1] ?? '') == start &&
          (asked![2]!.isEmpty || limit != null && end <= limit)) {
        expected = (start: start, end: end);
      }
    }
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
    if (!partial && (length == null || rangeHeader != null) &&
        _isHlsAudioSegment(request.uri.path)) {
      await _serveCompleteSegment(request, media, upstream, generation);
      return true;
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
      if (start != 0 ||
          partial && total == null ||
          generation != _generation ||
          !enabled) {
        return;
      }
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
        while (prefix.length < 80 && await chunks.moveNext()) {
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
        // Normal TS/encrypted bytes pass after a short prefix. A PNG wrapper needs
        // four aligned TS packets; inspect only the bounded prefix, not EOF.
        while (await chunks.moveNext()) {
          capture(chunks.current);
          prefix.add(chunks.current);
          if (prefix.length < 80) continue;
          final bytes = prefix.toBytes();
          if (!couldStartWithPng(bytes)) break;
          skipped = transportStreamImagePrefix(bytes);
          if (skipped > 0 || prefix.length >= transportStreamProbeLength) break;
        }
      }
      if (start == 0) _rejectHtml(prefix.toBytes());
      final response = request.response;
      response.statusCode = rangeHeader == null ? 200 : upstream.statusCode;
      response.headers.set(
        'Content-Type',
        _responseType(request.uri.path, upstream.header('content-type')),
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
      final bodyLength = partial ? end! - start + 1 : length;
      if (bodyLength != null) response.contentLength = bodyLength - skipped;
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
      if (bodyLength != null && received != bodyLength) {
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

  // Some demuxers report an I/O error at a chunked EOF even after decoding
  // all frames. A playlist segment is finite, so measure it before serving it.
  Future<void> _serveCompleteSegment(
    HttpRequest request,
    PlayerMedia media,
    MediaRangeResponse upstream,
    int generation, {
    bool subtitle = false,
  }) async {
    final buffer = BytesBuilder(copy: false);
    Directory? directory;
    File? overflow;
    RandomAccessFile? writer;
    var length = 0;
    final prefix = <int>[];
    try {
      final encoding = upstream.header('content-encoding');
      if (subtitle && !const {null, 'identity', 'gzip', 'deflate'}.contains(encoding?.trim().toLowerCase())) {
        await upstream.listen(null).cancel();
        throw const FormatException('不支持的字幕内容编码');
      }
      final body = subtitle ? _decodedBody(_completeBody(upstream), encoding) : upstream;
      await for (final chunk in body.timeout(const Duration(seconds: 30))) {
        if (prefix.length < 80) {
          prefix.addAll(chunk.take(80 - prefix.length));
          _rejectHtml(prefix);
        }
        length += chunk.length;
        downloadedBytes += chunk.length;
        if (writer == null && length > blockBytes) {
          directory = await Directory.systemTemp.createTemp('lume-hls-');
          overflow = File('${directory.path}/segment');
          writer = await overflow.open(mode: FileMode.write);
          await writer.writeFrom(buffer.takeBytes());
        }
        if (writer == null) {
          buffer.add(chunk);
        } else {
          await writer.writeFrom(chunk);
        }
      }
      final mime = _responseType(request.uri.path, upstream.header('content-type'));
      if (encoding != null && !subtitle) request.response.headers.set('Content-Encoding', encoding);
      if (overflow == null) {
        final bytes = buffer.takeBytes();
        final key = _key(media, 0);
        await _store(subtitle ? '$key-vtt' : key, _Block(bytes, 0, length, mime,
            upstream.header('etag') ?? upstream.header('last-modified'),
            upstream.uri, subtitle ? null : encoding), generation);
        serveHttpBytes(request, bytes, mime);
      } else {
        await writer!.close();
        writer = null;
        final offsets = prepareHttpByteResponse(request, length, mime);
        if (offsets != null && request.method != 'HEAD') {
          await request.response.addStream(overflow.openRead(offsets.start, offsets.end + 1));
        }
      }
    } finally {
      try {
        await writer?.close();
      } finally {
        await directory?.delete(recursive: true);
      }
    }
  }

  PlayerMedia _playlistReload(PlayerMedia media, Uri ticket) {
    if (!ticket.hasQuery || !ticket.path.endsWith('.m3u8')) return media;
    const names = {'_HLS_msn', '_HLS_part', '_HLS_skip'};
    final directives = {
      for (final e in ticket.queryParameters.entries)
        if (names.contains(e.key)) e.key: e.value,
    };
    if (directives.isEmpty) return media;
    // Re-encoding the origin query can invalidate a signature or collapse
    // repeated parameters. Replace only delivery directives supplied by the player.
    final query = [
      if (media.uri.query.isNotEmpty)
        for (final pair in media.uri.query.split('&'))
          if (!directives.containsKey(pair.split('=').first)) pair,
      for (final e in directives.entries)
        '${e.key}=${Uri.encodeQueryComponent(e.value)}',
    ].join('&');
    return PlayerMedia(uri: media.uri.replace(query: query), headers: media.headers);
  }

  // Preserve the MPD's base directory while keeping the source's headers on
  // same-origin requests. MPV expands SegmentTemplate variables itself.
  Future<void> _serveDashManifest(HttpRequest request, PlayerMedia media) async {
    final upstream = await _request(media, null);
    if (upstream.statusCode != 200 && upstream.statusCode != 206) {
      await upstream.listen(null).cancel();
      throw _UpstreamStatus(upstream.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    final body = _decodedBody(_completeBody(upstream), upstream.header('content-encoding'));
    await for (final part in body.timeout(const Duration(seconds: 30))) {
      if (bytes.length + part.length > 4 * blockBytes) {
        throw const FormatException('DASH 清单过大');
      }
      bytes.add(part);
    }
    final document = XmlDocument.parse(utf8.decode(bytes.takeBytes()));
    final root = document.rootElement;
    if (root.name.local != 'MPD') throw const FormatException('DASH 清单无效');
    final origin = upstream.uri.origin;
    final ticket = await _ticket(
      PlayerMedia(uri: Uri.parse('$origin/'), headers: upstream.requestHeaders),
      '.dash-base',
    );
    final localRoot = ticket.uri.toString();
    String route(Uri url) {
      if (!url.hasAuthority ||
          !const {'http', 'https'}.contains(url.scheme) ||
          url.origin != origin) {
        return url.toString();
      }
      return '$localRoot${url.path.isEmpty ? '/' : url.path}'
          '${url.hasQuery ? '?${url.query}' : ''}${url.hasFragment ? '#${url.fragment}' : ''}';
    }

    // Absolute same-origin references otherwise bypass the proxy. A leading
    // slash resolves against the enclosing BaseURL, which can be a different CDN.
    void rewriteReferences(XmlElement element, Set<Uri> parents) {
      final bases = element.childElements.where((e) => e.name.local == 'BaseURL').toList();
      final resolved = <Uri>{};
      String reference(String value, Iterable<Uri> bases) {
        final uri = Uri.parse(value);
        if (uri.hasScheme) return route(uri);
        if (!value.startsWith('/')) return value;
        final targets = bases.map((base) => base.resolveUri(uri)).toSet();
        return targets.length == 1 ? route(targets.single) : value;
      }
      for (final base in bases) {
        final value = base.innerText.trim();
        final uri = Uri.parse(value);
        if (!uri.hasScheme && !uri.hasAuthority) {
          resolved.addAll(parents);
        } else {
          for (final parent in parents) {
            final url = parent.resolveUri(uri);
            if (const {'http', 'https'}.contains(url.scheme) && url.host.isNotEmpty) {
              resolved.add(Uri.parse(url.origin));
            }
          }
        }
        base.innerText = identical(element, root)
            ? route(upstream.uri.resolve(value))
            : reference(value, parents);
      }
      final effective = bases.isEmpty ? parents : resolved;
      final attributes = switch (element.name.local) {
        'SegmentTemplate' => const ['media', 'initialization', 'index', 'bitstreamSwitching'],
        'SegmentURL' => const ['media', 'index'],
        'Initialization' || 'RepresentationIndex' || 'BitstreamSwitching' => const ['sourceURL'],
        _ => const <String>[],
      };
      for (final name in attributes) {
        final value = element.getAttribute(name);
        if (value != null) element.setAttribute(name, reference(value, effective));
      }
      for (final child in element.childElements.where((e) => e.name.local != 'BaseURL')) {
        rewriteReferences(child, effective);
      }
    }
    rewriteReferences(root, {Uri.parse(origin)});
    for (final location in root.childElements.where((e) => e.name.local == 'Location')) {
      final url = upstream.uri.resolve(location.innerText.trim());
      if (url.scheme != 'http' && url.scheme != 'https') continue;
      final headers = Map<String, String>.of(upstream.requestHeaders);
      if (url.origin != origin) headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
      location.innerText = (await _ticket(PlayerMedia(uri: url, headers: headers), '.mpd')).uri.toString();
    }
    final bases = root.childElements.where((element) => element.name.local == 'BaseURL').toList();
    if (bases.isEmpty) {
      final base = XmlElement(XmlName.parts('BaseURL',
          prefix: root.name.prefix, namespaceUri: root.name.namespaceUri));
      base.innerText = route(upstream.uri);
      root.children.insert(0, base);
    }
    serveHttpBytes(request, utf8.encode(document.toXmlString()), 'application/dash+xml');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var streaming = false;
    late final PlayerMedia media;
    try {
      final path = request.uri.path;
      final slash = path.indexOf('/', 1);
      final name = path.substring(1, slash < 0 ? null : slash);
      final ticket = _tickets[name];
      if (ticket == null) {
        response.statusCode = 404;
        return;
      }
      if (!['GET', 'HEAD'].contains(request.method)) {
        response.statusCode = 405;
        return;
      }
      if (slash >= 0 && name.endsWith('.dash-base')) {
        final relative = path.substring(slash);
        final uri = ticket.uri.replace(path: relative, query: request.uri.hasQuery ? request.uri.query : null);
        media = PlayerMedia(uri: uri, headers: ticket.headers);
      } else if (slash >= 0 || name.endsWith('.dash-base')) {
        response.statusCode = 404;
        return;
      } else {
        media = _playlistReload(ticket, request.uri);
        if (name.endsWith('.mpd')) {
          await _serveDashManifest(request, media);
          return;
        }
      }
      if (slash < 0 && path.endsWith('.identity.key')) {
        response.headers.set('Cache-Control', 'no-store');
        serveHttpBytes(request, await _identityKey(media), 'application/octet-stream');
        return;
      }
      if (slash < 0 && path.endsWith('.hls.vtt')) {
        // Map native probes and seeks to the decoded subtitle text. Signed
        // subtitle endpoints can reject ranges or cap even an ordinary GET.
        final generation = _generation;
        final cached = await _cachedBlock('${_key(media, 0)}-vtt');
        if (cached != null) {
          serveHttpBytes(request, cached.data, 'text/vtt');
          return;
        }
        var upstream = await _request(media, null);
        if (const [400, 403, 405, 416].contains(upstream.statusCode)) {
          await upstream.listen(null).cancel();
          upstream = await _request(media, 'bytes=0-');
        }
        if (upstream.statusCode != 200 && upstream.statusCode != 206) {
          await upstream.listen(null).cancel();
          throw _UpstreamStatus(upstream.statusCode);
        }
        await _serveCompleteSegment(request, media, upstream, generation, subtitle: true);
        return;
      }
      if (slash < 0 && (path.endsWith('.init.mp4') || path.endsWith('.frag.m4s'))) {
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
            '.m4a',
          ].any(path.endsWith) ||
          _packedAudio(path);
      final cached = _files[_key(media, start ~/ blockBytes * blockBytes)];
      if (request.method == 'GET' &&
          canStream &&
          (rawRange == null || _isHlsAudioSegment(path) || !segment && !_loopback(media.uri)) &&
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
          if (!block.keepOriginHeaders || uri.origin != block.base.origin) {
            headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
          }
          return PlayerMedia(uri: uri, headers: headers);
        }

        final apple = path.endsWith('.apple.m3u8');
        final subtitles = path.endsWith('.subtitles.m3u8');
        Future<String> rewrite(
          String text,
          String fallback, {
          int? sequence,
        }) async {
          final child = childMedia(text);
          if (child == null) return text;
          var suffix = _mediaSuffix(child.uri);
          if (fallback == '.vtt') {
            suffix = '.hls.vtt';
          } else if (sequence != null || suffix.isEmpty || fallback.endsWith('.m3u8') ||
              fallback == '.identity.key') {
            suffix = fallback;
          }
          if (apple && suffix == '.m3u8') suffix = '.apple.m3u8';
          if (fallback == '.ts' && _packedAudio(suffix)) suffix = '.hls$suffix';
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
        final original = const LineSplitter().convert(manifestText).map((line) => line.trim()).toList();
        bool isResource(String line) =>
            line.isNotEmpty && !line.startsWith('#');
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
          final child = childMedia(first);
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
        var segmentSuffix = subtitles ? '.vtt' : '.ts';
        for (final line in original) {
          if (fragment && line == '#EXTM3U') {
            lines.addAll([
              line,
              '#EXT-X-VERSION:7',
              '#EXT-X-MAP:URI="${await rewrite(first!, '.init.mp4', sequence: 1)}"',
            ]);
          } else if (fragment && line.startsWith('#EXT-X-VERSION:')) {
            continue;
          } else if (isResource(line)) {
            if (fragment) {
              sequence++;
              lines.add(
                await rewrite(line, '.frag.m4s', sequence: sequence),
              );
            } else {
              lines.add(
                await rewrite(
                  line,
                  master ? '.m3u8' : segmentSuffix,
                ),
              );
            }
          } else {
            var result = line;
            for (final m in RegExp(
              r'URI="([^"]+)"',
            ).allMatches(line).toList().reversed) {
              final tag = line.split(':').first;
              var attributeSuffix = switch (tag) {
                '#EXT-X-KEY' || '#EXT-X-SESSION-KEY' => _keySuffix(line),
                '#EXT-X-MAP' => '.mp4',
                '#EXT-X-MEDIA' => hlsRawAttributes(line)['TYPE'] == 'SUBTITLES'
                    ? '.subtitles.m3u8'
                    : '.m3u8',
                '#EXT-X-I-FRAME-STREAM-INF' => '.m3u8',
                '#EXT-X-RENDITION-REPORT' => subtitles ? '.subtitles.m3u8' : '.m3u8',
                '#EXT-X-PART' => '.m4s',
                '#EXT-X-PRELOAD-HINT' => switch (hlsRawAttributes(line)['TYPE']) {
                  'PART' => '.m4s',
                  'MAP' => '.mp4',
                  _ => '',
                },
                _ => '',
              };
              if (tag == '#EXT-X-MAP') {
                segmentSuffix = '.m4s';
                if (subtitles) {
                  final child = childMedia(m[1]!);
                  if (child != null) {
                    final suffix = _mediaSuffix(child.uri);
                    final format = const {'.mp4', '.m4s', '.vtt', '.webvtt'}.contains(suffix)
                        ? suffix
                        : await _scriptFormat(child).timeout(const Duration(seconds: 3), onTimeout: () => '');
                    if (format == '.vtt' || format == '.webvtt') {
                      attributeSuffix = segmentSuffix = '.vtt';
                    }
                  }
                }
              }
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
      if (segment) block = await _probeTsPrefix(media, block);
      final prefixBytes = segment && block.encoding == null ? transportStreamImagePrefix(block.data) : 0;
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
      response.headers.set('Content-Type', _responseType(path, block.mime));
      response.headers.set('Accept-Ranges', 'bytes');
      if (match != null) {
        response.headers.set('Content-Range', 'bytes $start-$end/$mediaTotal');
      }
      if (block.encoding != null) {
        response.headers.set('Content-Encoding', block.encoding!);
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      final first = block;
      var validator = block.validator;
      start += prefixBytes;
      final physicalEnd = end + prefixBytes;
      if (start < block.start || start >= block.start + block.data.length) {
        block = await _read(media, start);
      }
      while (start <= physicalEnd) {
        if (!first.sameRepresentation(block, validator)) {
          await _discardChangedMedia(media);
          throw const HttpException('媒体已变化，请重新加载');
        }
        validator ??= block.validator;
        final offset = start - block.start;
        final length = min(block.data.length - offset, physicalEnd - start + 1);
        if (length <= 0) throw const HttpException('媒体代理没有返回后续数据');
        response.add(block.data.sublist(offset, offset + length));
        streaming = true;
        await response.flush();
        start += length;
        _positions[media.uri] = (next: start, total: first.total);
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
      if (upstream.statusCode ~/ 100 == 2) {
        response.headers.set('Content-Type', _responseType(request.uri.path, upstream.header('content-type')));
      }
      status = '该媒体使用内核缓冲';
      notifyListeners();
      if (request.method != 'HEAD') {
        await response.addStream(upstream);
      } else {
        await upstream.listen(null).cancel();
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
      var freed = 0;
      await _disk(() async {
        freed = bytes;
        for (final row in _files.values) {
          if (await row.file.exists()) await row.file.delete();
        }
        _files.clear();
        bytes = 0;
        _spaceChecked = null;
        _diskAvailable = _root != null;
        status = '播放磁盘缓存已清理';
      });
      return freed;
    } finally {
      _clearing = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    await _booting;
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
    this.encoding, {
    this.keepOriginHeaders = false,
  });
  final Uint8List data;
  final int start, total;
  final String mime;
  final String? validator;
  final Uri base;
  final String? encoding;
  final bool keepOriginHeaders;
  bool sameRepresentation(_Block other, String? knownValidator) =>
      base.removeFragment() == other.base.removeFragment() &&
      total == other.total && encoding == other.encoding &&
      (knownValidator == null || other.validator == null || knownValidator == other.validator);
  _Block withData(Uint8List data) =>
      _Block(data, start, total, mime, validator, base, encoding, keepOriginHeaders: keepOriginHeaders);
}
