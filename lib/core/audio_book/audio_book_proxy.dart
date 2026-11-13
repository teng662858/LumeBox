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
/// HTTP content codings are removed before relaying playable audio bytes.
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
  static final _mediaExtension = RegExp(
    r'\.(?:m3u8|ts|m2ts|m4s|mp4|m4a|mp3|aac|ac3|ec3|flac|ogg|opus|wav|vtt|webvtt|key)$',
    caseSensitive: false,
  );

  static String _extension(Uri? uri) =>
      _mediaExtension.stringMatch(uri?.path ?? '')?.toLowerCase() ?? '';

  Uri _register(AudioBookTrack track, int port) {
    final id = sha256
        .convert(utf8.encode('$_generation:${track.id}'))
        .toString();
    final ticket =
        '$id${track.resolve == null ? _extension(track.episode.url) : ''}';
    _tracks[ticket] = track;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/$_token/$ticket',
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

  Uri _asset(int port, String id, Uri uri, {bool playlist = false}) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/$_token/$id/asset${playlist ? '.m3u8' : _extension(uri)}',
    queryParameters: {'asset': base64Url.encode(utf8.encode(uri.toString()))},
  );
  Future<void> _serve(HttpRequest request, {bool canRefresh = true}) async {
    http.Client? client;
    try {
      final path = request.uri.pathSegments;
      final port = request.connectionInfo!.localPort;
      final raw = request.uri.queryParameters['asset'];
      if (!(path.length == 2 || path.length == 3 && raw != null) ||
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
      final playlistAsset = path.length == 3 && path.last == 'asset.m3u8';
      client = _clientFactory();
      _clients.add(client);
      http.StreamedResponse? response;
      var fetchPlaylist = false;
      var ignoreRange = false;
      var redirects = 0;
      while (true) {
        final full =
            playlistAsset ||
            fetchPlaylist ||
            uri.path.toLowerCase().endsWith('.m3u8');
        final upstream = http.Request(full ? 'GET' : request.method, uri)
          ..headers.addAll(headers)
          ..followRedirects = false;
        if (full || ignoreRange) {
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
        // Offsets in an encoded response refer to compressed bytes. Request
        // the complete representation and stream the decoded audio from zero.
        final encoding = response.headers['content-encoding']
            ?.trim()
            .toLowerCase();
        final rejectedRange = const [400, 403, 405].contains(response.statusCode) ||
            response.statusCode == 416 && response.headers['content-range'] == null;
        if (upstream.headers.containsKey('range') &&
            (rejectedRange || [206, 416].contains(response.statusCode) &&
                encoding != null && encoding != 'identity')) {
          await response.stream.listen(null).cancel();
          ignoreRange = true;
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
        if (canRefresh && raw == null && track.resolve != null &&
            const [401, 403, 404, 410].contains(status)) {
          await response.stream.listen(null).cancel();
          if (generation != _generation) throw const HttpException('播放列表已更换');
          // Concurrent seeks can fail against the same expired URL. Keep any
          // newer resolution and let _resolve coalesce an in-flight refresh.
          if (identical(_resolved[track.id]?.audio, resolved)) {
            _resolved.remove(track.id);
          }
          _clients.remove(client);
          client.close();
          client = null;
          await _serve(request, canRefresh: false);
          return;
        }
        lastError = status == 401 || status == 403
            ? '音频服务器拒绝访问（HTTP $status），请在源网页确认能否播放'
            : '音频服务器请求失败（HTTP $status），请稍后重试或更换源';
        throw HttpException('音频服务器请求失败: HTTP $status');
      }
      final type =
          response.headers['content-type'] ?? 'application/octet-stream';
      final hls =
          playlistAsset ||
          uri.path.toLowerCase().endsWith('.m3u8') ||
          type.toLowerCase().contains('mpegurl');
      final encoding = response.headers['content-encoding']
          ?.trim()
          .toLowerCase();
      final encoded = encoding != null && encoding != 'identity';
      Stream<List<int>> body = response.stream;
      if (encoded) {
        final nativeDecoded =
            client is AudioBookHttpClient &&
            client.decodesContentEncoding &&
            const {'gzip', 'deflate', 'br'}.contains(encoding);
        if (response.statusCode == 206) {
          throw const FormatException('音频服务器未返回完整压缩响应');
        }
        if (!nativeDecoded) {
          body = switch (encoding) {
            'gzip' => body.transform(gzip.decoder),
            'deflate' => body.transform(zlib.decoder),
            _ => throw FormatException('不支持的音频内容编码：$encoding'),
          };
        }
      }
      if (hls) {
        final bytes = <int>[];
        await for (final chunk in body.timeout(const Duration(seconds: 20))) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const FormatException('播放清单过大');
          }
        }
        final manifest = utf8.decode(bytes);
        if (!manifest.trimLeft().startsWith('#EXTM3U')) {
          throw const FormatException('无效音频清单');
        }
        final lines = manifest.split('\n');
        final master = lines.any(
          (line) => line.trimLeft().startsWith('#EXT-X-STREAM-INF:'),
        );
        final rewritten = lines
            .map((line) {
              final value = line.trim();
              if (value.isEmpty) return line;
              if (value.startsWith('#')) {
                final tag = value.split(':').first;
                final playlistUri = const {
                  '#EXT-X-MEDIA',
                  '#EXT-X-I-FRAME-STREAM-INF',
                  '#EXT-X-RENDITION-REPORT',
                }.contains(tag);
                return line.replaceAllMapped(
                  RegExp(r'URI="([^"]+)"'),
                  (match) =>
                      'URI="${_asset(port, path[1], uri.resolve(match.group(1)!), playlist: playlistUri)}"',
                );
              }
              return _asset(
                port,
                path[1],
                uri.resolve(value),
                playlist: master,
              ).toString();
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
        request.response.headers.set('Content-Type', type);
        final length = response.contentLength;
        if (!encoded && response.statusCode == 200 && range != null && length != null) {
          final offsets = _responseRange(request, length);
          if (offsets == null || request.method == 'HEAD') {
            await response.stream.listen(null).cancel();
          } else {
            await request.response.addStream(_slice(body.timeout(const Duration(seconds: 30)),
                offsets.start, offsets.end));
          }
          await request.response.close();
          return;
        }
        if (!encoded) {
          for (final name in ['content-range', 'accept-ranges']) {
            final value = response.headers[name];
            if (value != null) request.response.headers.set(name, value);
          }
          if (response.contentLength != null) {
            request.response.contentLength = response.contentLength!;
          }
        }
        if (request.method == 'GET') {
          await request.response.addStream(
            body.timeout(const Duration(seconds: 30)),
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

  // Stream a requested range from a complete upstream response. Stop reading
  // as soon as the last requested byte has been sent.
  static Stream<List<int>> _slice(Stream<List<int>> body, int start, int end) async* {
    var offset = 0;
    await for (final chunk in body) {
      final next = offset + chunk.length;
      if (next > start && chunk.isNotEmpty) {
        yield chunk.sublist(max(0, start - offset), min(chunk.length, end - offset));
      }
      if (next >= end) return;
      offset = next;
    }
    throw const HttpException('音频响应未达到请求的字节范围');
  }

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
