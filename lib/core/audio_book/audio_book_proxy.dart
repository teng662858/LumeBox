import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../net/http_byte_range.dart';
import '../net/http_header_scope.dart';
import 'audio_book_track.dart';
import 'audio_book_http_client.dart';
import '../util/lume_log.dart';

/// Loopback-only, authenticated-by-random-path byte relay. It lazily resolves
/// source chapters and preserves Range requests, including audio HLS playlists.
/// The bytes are never decoded or synthesized by this layer.
class AudioBookProxy {
  AudioBookProxy({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? AudioBookHttpClient.new;

  final http.Client Function() _clientFactory;

  String? lastError;
  Future<HttpServer>? _binding;
  final _tracks = <String, AudioBookTrack>{};
  final _clients = <http.Client>{};
  final _resolved = <String, ({DateTime time, ResolvedAudio audio})>{};
  final _resolving = <String, Future<ResolvedAudio>>{};
  final _token = base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<List<Uri>> prepare(List<AudioBookTrack> tracks) async {
    reset();
    final generation = _generation;
    final binding = _binding ??= _bind();
    final HttpServer server;
    try {
      server = await binding;
    } catch (_) {
      if (identical(_binding, binding)) _binding = null;
      rethrow;
    }
    if (generation != _generation) throw StateError('播放列表已更换');
    return [for (final track in tracks) _register(track, server.port)];
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
    return server;
  }

  int _generation = 0;
  Uri _register(AudioBookTrack track, int port) {
    final id = sha256
        .convert(utf8.encode('$_generation:${track.id}'))
        .toString();
    _tracks[id] = track;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/$_token/$id',
    );
  }

  void reset() {
    lastError = null;
    _generation++;
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
    _tracks.clear();
    _resolved.clear();
    _resolving.clear();
  }

  Future<void> close() async {
    reset();
    final binding = _binding;
    _binding = null;
    await (await binding)?.close(force: true);
  }

  Future<ResolvedAudio> _resolve(AudioBookTrack track) async {
    final cached = _resolved[track.id];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 2)) {
      return cached.audio;
    }
    final pending = _resolving[track.id];
    if (pending != null) return pending;
    final generation = _generation;
    final job = () async {
      final audio = track.resolve != null
          ? await track.resolve!()
          : track.episode.url != null
          ? ResolvedAudio(track.episode.url!, headers: track.episode.headers)
          : throw const FormatException('音频地址不可用');
      if (generation == _generation) {
        _resolved[track.id] = (time: DateTime.now(), audio: audio);
      }
      return audio;
    }();
    _resolving[track.id] = job;
    try {
      return await job;
    } finally {
      if (identical(_resolving[track.id], job)) _resolving.remove(track.id);
    }
  }

  Uri _asset(int port, String id, Uri uri) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/$_token/$id',
    queryParameters: {'asset': base64Url.encode(utf8.encode(uri.toString()))},
  );
  Future<void> _serve(HttpRequest request) async {
    http.Client? client;
    try {
      final path = request.uri.pathSegments;
      final port = request.connectionInfo!.localPort;
      if (path.length != 2 ||
          path[0] != _token ||
          !_tracks.containsKey(path[1]) ||
          !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final generation = _generation;
      final track = _tracks[path[1]]!;
      final resolved = await _resolve(track)
          .timeout(const Duration(seconds: 20));
      if (generation != _generation) throw const HttpException('播放列表已更换');
      final raw = request.uri.queryParameters['asset'];
      var uri = raw == null
          ? resolved.url
          : Uri.parse(utf8.decode(base64Url.decode(raw)));
      if (uri.scheme == 'file' && raw == null) {
        await _file(request, File.fromUri(uri));
        return;
      }
      if (!['http', 'https'].contains(uri.scheme)) {
        throw const FormatException('不支持的音频地址');
      }
      final headers = Map<String, String>.from(resolved.headers);
      if (uri.scheme != resolved.url.scheme ||
          uri.origin != resolved.url.origin) {
        headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
      }
      headers['Accept-Encoding'] = 'identity';
      final range = request.headers.value(HttpHeaders.rangeHeader);
      client = _clientFactory();
      _clients.add(client);
      http.StreamedResponse? response;
      var fetchPlaylist = false;
      var redirects = 0;
      while (true) {
        final full = fetchPlaylist || uri.path.toLowerCase().endsWith('.m3u8');
        final upstream = http.Request(full ? 'GET' : request.method, uri)
          ..headers.addAll(headers)
          ..followRedirects = false;
        if (full) {
          upstream.headers.remove('range');
        } else if (range != null) {
          upstream.headers['range'] = range;
        }
        response = await client
            .send(upstream)
            .timeout(const Duration(seconds: 20));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers['location'];
          await response.stream.listen(null).cancel();
          if (++redirects > 5) throw const FormatException('音频重定向过多');
          if (location == null) throw const FormatException('无效音频重定向');
          final next = uri.resolve(location);
          if (!['http', 'https'].contains(next.scheme)) {
            throw const FormatException('不支持的重定向');
          }
          if (next.origin != uri.origin) {
            headers.removeWhere((key, _) => isOriginBoundHttpHeader(key));
          }
          uri = next;
          fetchPlaylist = false;
          continue;
        }
        if (!full &&
            (upstream.method == 'HEAD' ||
                upstream.headers.containsKey('range')) &&
            (response.headers['content-type'] ?? '').toLowerCase().contains(
              'mpegurl',
            )) {
          await response.stream.listen(null).cancel();
          fetchPlaylist = true;
          continue;
        }
        break;
      }
      if (generation != _generation) throw const HttpException('播放列表已更换');
      if (response.statusCode == 416) {
        final size = response.headers['content-range'];
        await response.stream.listen(null).cancel();
        request.response.statusCode = 416;
        if (size != null) request.response.headers.set('content-range', size);
        request.response.contentLength = 0;
        await request.response.close();
        return;
      }
      if (![200, 206].contains(response.statusCode)) {
        final status = response.statusCode;
        lastError = status == 401 || status == 403
            ? '音频服务器拒绝访问（HTTP $status），请在源网页确认能否播放'
            : '音频服务器请求失败（HTTP $status），请稍后重试或更换源';
        throw HttpException('音频服务器请求失败: HTTP $status');
      }
      final type =
          response.headers['content-type'] ?? 'application/octet-stream';
      final hls =
          uri.path.toLowerCase().endsWith('.m3u8') ||
          type.toLowerCase().contains('mpegurl');
      if (hls) {
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 20),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const FormatException('播放清单过大');
          }
        }
        final body = utf8.decode(bytes);
        if (!body.trimLeft().startsWith('#EXTM3U')) {
          throw const FormatException('无效音频清单');
        }
        final rewritten = body
            .split('\n')
            .map((line) {
              final value = line.trim();
              if (value.isEmpty) return line;
              if (value.startsWith('#')) {
                return line.replaceAllMapped(
                  RegExp(r'URI="([^"]+)"'),
                  (match) =>
                      'URI="${_asset(port, path[1], uri.resolve(match.group(1)!))}"',
                );
              }
              return _asset(port, path[1], uri.resolve(value)).toString();
            })
            .join('\n');
        final output = utf8.encode(rewritten);
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        final offsets = _responseRange(request, output.length);
        if (offsets != null && request.method == 'GET') {
          request.response.add(output.sublist(offsets.start, offsets.end));
        }
      } else {
        request.response.statusCode = response.statusCode;
        for (final name in ['content-type', 'content-range', 'accept-ranges']) {
          final value = response.headers[name];
          if (value != null) request.response.headers.set(name, value);
        }
        if (response.contentLength != null) {
          request.response.contentLength = response.contentLength!;
        }
        if (request.method == 'GET') {
          await request.response.addStream(
            response.stream.timeout(const Duration(seconds: 30)),
          );
        } else {
          await response.stream.listen(null).cancel();
        }
      }
      await request.response.close();
    } catch (error, stack) {
      LumeLog.error('[audioBook] 音频转发失败: $error', stack);
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } catch (_) {
        /* Client cancelled a seek/load. */
      }
    } finally {
      if (client != null) {
        _clients.remove(client);
        client.close();
      }
    }
  }

  // Both local files and rewritten playlists support ranges of their served bytes.
  ({int start, int end})? _responseRange(HttpRequest request, int size) {
    var start = 0, end = size;
    request.response.headers.set('Accept-Ranges', 'bytes');
    final raw = request.headers.value(HttpHeaders.rangeHeader);
    if (raw != null) {
      final offsets = parseHttpByteRange(raw, size);
      if (offsets == null) {
        request.response.statusCode = 416;
        request.response.headers.set('Content-Range', 'bytes */$size');
        request.response.contentLength = 0;
        return null;
      }
      start = offsets.start;
      end = offsets.end + 1;
      request.response.statusCode = 206;
      request.response.headers.set(
        'Content-Range',
        'bytes $start-${end - 1}/$size',
      );
    }
    request.response.contentLength = end - start;
    return (start: start, end: end);
  }

  Future<void> _file(HttpRequest request, File file) async {
    final ext = file.path.toLowerCase().split('.').last;
    request.response.headers.set('Content-Type', switch (ext) {
      'm4a' || 'mp4' => 'audio/mp4',
      'wav' => 'audio/wav',
      'flac' => 'audio/flac',
      'ogg' || 'opus' => 'audio/ogg',
      'aac' => 'audio/aac',
      _ => 'audio/mpeg',
    });
    final offsets = _responseRange(request, await file.length());
    if (offsets != null && request.method == 'GET') {
      await request.response.addStream(
        file.openRead(offsets.start, offsets.end),
      );
    }
    await request.response.close();
  }
}
