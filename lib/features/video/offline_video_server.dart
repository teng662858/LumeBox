import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/net/http_byte_range.dart';

// Old downloads can have a .ts suffix on fragmented MP4 media from script URLs.
Future<bool> hasMp4BoxHeader(File file) async {
  final input = await file.open();
  try {
    final header = await input.read(8);
    if (header.length < 8) return false;
    return const {'ftyp', 'styp', 'moof', 'sidx', 'moov', 'emsg', 'prft'}
        .contains(String.fromCharCodes(header, 4, 8));
  } finally {
    await input.close();
  }
}

/// A session-only loopback endpoint makes downloaded HLS playable by AVFoundation as well as FFmpeg.
class OfflineVideoServer {
  OfflineVideoServer._(this._server, this._root, this._token);
  final HttpServer _server;
  final String _root, _token;
  static Future<OfflineVideoServer> open(Directory directory) async {
    final root = await directory.resolveSymbolicLinks();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final result = OfflineVideoServer._(server, root, token);
    server.listen(result._serve);
    return result;
  }

  Uri get uri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_token/index.m3u8',
  );
  Future<void> close() => _server.close(force: true);
  Future<void> _serve(HttpRequest request) async {
    try {
      final parts = request.uri.pathSegments;
      if (!['GET', 'HEAD'].contains(request.method) ||
          parts.isEmpty ||
          parts.first != _token) {
        request.response.statusCode = 403;
        return;
      }
      final path = p.normalize(p.joinAll([_root, ...parts.skip(1)]));
      if (!p.isWithin(_root, path) ||
          ![
            '.m3u8',
            '.ts',
            '.m4s',
            '.mp4',
            '.key',
            '.aac',
            '.mp3',
          ].contains(p.extension(path))) {
        request.response.statusCode = 403;
        return;
      }
      final file = File(path);
      if (!await file.exists()) {
        request.response.statusCode = 404;
        return;
      }
      if (!p.isWithin(_root, await file.resolveSymbolicLinks())) {
        request.response.statusCode = 403;
        return;
      }
      final length = await file.length();
      var start = 0, end = length - 1;
      final range = request.headers.value('range');
      if (range != null) {
        final offsets = parseHttpByteRange(range, length);
        if (offsets == null) {
          request.response.statusCode = 416;
          request.response.headers.set('Content-Range', 'bytes */$length');
          return;
        }
        start = offsets.start;
        end = offsets.end;
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/$length',
        );
      }
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.headers.contentType = ContentType.parse(switch (p
          .extension(path)) {
        '.m3u8' => 'application/vnd.apple.mpegurl',
        '.aac' => 'audio/aac',
        '.mp3' => 'audio/mpeg',
        '.ts' => await hasMp4BoxHeader(file) ? 'video/mp4' : 'video/mp2t',
        '.mp4' || '.m4s' => 'video/mp4',
        _ => 'application/octet-stream',
      });
      request.response.contentLength = length == 0 ? 0 : end - start + 1;
      if (request.method == 'GET' && length > 0) {
        await request.response.addStream(file.openRead(start, end + 1));
      }
    } catch (_) {
      /* Client cancellation must not terminate the offline server. */
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}
