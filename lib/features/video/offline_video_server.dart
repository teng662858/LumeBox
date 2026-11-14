import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/net/http_byte_range.dart';
import '../../core/player/hls_attributes.dart';

bool _isMp4Header(List<int> header) =>
    header.length >= 8 &&
    const {'ftyp', 'styp', 'moof', 'sidx', 'moov', 'emsg', 'prft'}
        .contains(String.fromCharCodes(header, 4, 8));

Future<bool> hasMp4BoxHeader(File file) async {
  final input = await file.open();
  try {
    return _isMp4Header(await input.read(8));
  } finally {
    await input.close();
  }
}

// Old downloads used .ts even for fragmented MP4 and packed Dolby audio.
// Seek over the optional HLS timestamp ID3 tag without reading its payload.
Future<String> _legacySegmentType(File file) async {
  final input = await file.open();
  try {
    var header = await input.read(10);
    if (_isMp4Header(header)) return 'video/mp4';
    if (header.length == 10 && String.fromCharCodes(header, 0, 3) == 'ID3' &&
        (header[3] == 3 || header[3] == 4) && header.skip(6).every((b) => b < 128)) {
      final size = header.skip(6).fold<int>(0, (n, b) => (n << 7) | b);
      final footer = header[3] == 4 && (header[5] & 0x10) != 0 ? 10 : 0;
      await input.setPosition(10 + size + footer);
      header = await input.read(7);
    }
    if (header.length >= 7 && header[0] == 0x0b && header[1] == 0x77) {
      final bitstreamId = header[5] >> 3;
      if (bitstreamId <= 10 && header[4] >> 6 != 3 && (header[4] & 63) <= 37) {
        return 'audio/ac3';
      }
      if (bitstreamId >= 11 && bitstreamId <= 16 && header[2] >> 6 != 3 &&
          (header[4] >> 4) != 15 && (((header[2] & 7) << 8) | header[3]) >= 3) {
        return 'audio/eac3';
      }
    }
    return 'video/mp2t';
  } finally {
    await input.close();
  }
}

/// A session-only loopback endpoint makes downloaded HLS playable by AVFoundation as well as FFmpeg.
class OfflineVideoServer {
  OfflineVideoServer._(this._server, this._root, this._token);
  final HttpServer _server;
  final String _root, _token;
  static const _extensions = {
    '.m3u8', '.ts', '.m4s', '.mp4', '.key', '.aac', '.ac3', '.ec3', '.eac3', '.mp3',
  };
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
  // Only called after playback fails. Keep ordinary startup independent of
  // the segment count, but avoid reopening a broken package on every retry.
  Future<bool> hasCompletePlaylist(Uri entry) async {
    final root = Directory(_root).uri;
    final segments = <String>{};
    final keys = <String>{};
    final verified = <Uri>{};
    Future<bool> checkPlaylist(Uri playlist, int depth) async {
      if (depth > 3) return false; // Same nesting limit as the downloader.
      if (verified.contains(playlist)) return true;
      final file = File.fromUri(playlist);
      if (!p.isWithin(_root, await file.resolveSymbolicLinks())) return false;
      final lines = await file.readAsLines();
      if (lines.isEmpty || lines.first.trim() != '#EXTM3U') return false;
      var hasMedia = false;
      var master = false;
      var ended = false;
      for (final raw in lines.skip(1)) {
        var path = raw.trim();
        if (path.isEmpty) continue;
        var key = false;
        if (path.startsWith('#')) {
          if (path.startsWith('#EXT-X-STREAM-INF:')) master = true;
          if (path == '#EXT-X-ENDLIST') ended = true;
          key = path.startsWith('#EXT-X-KEY:');
          final map = path.startsWith('#EXT-X-MAP:');
          if (!path.startsWith('#EXT-X-MEDIA:') && !key && !map) {
            continue;
          }
          final attributes = hlsRawAttributes(path);
          if (key && attributes['METHOD'] == 'NONE') continue;
          if (key && (attributes['METHOD'] != 'AES-128' ||
              hlsAttributeValue(attributes['KEYFORMAT'] ?? 'identity') != 'identity')) {
            return false;
          }
          final attribute = attributes['URI'];
          if ((key || map) && hlsAttributeValue(attribute ?? '').trim().isEmpty) return false;
          if (attribute == null) continue;
          path = hlsAttributeValue(attribute);
        } else {
          hasMedia = true;
        }
        final resource = playlist.resolve(path);
        if (resource.scheme != 'file' || resource.authority != root.authority ||
            !p.isWithin(_root, resource.toFilePath())) {
          return false;
        }
        final name = resource.toFilePath();
        final extension = p.extension(name);
        if (!_extensions.contains(extension)) return false;
        if (extension == '.m3u8') {
          if (key) return false;
          if (!await checkPlaylist(resource, depth + 1)) return false;
        } else {
          segments.add(name);
          if (key) keys.add(name);
        }
      }
      if (!hasMedia || !master && !ended) return false;
      verified.add(playlist);
      return true;
    }

    try {
      if (!await checkPlaylist(root.resolve(Uri.encodeComponent(entry.pathSegments.last)), 0)) {
        return false;
      }
      final paths = segments.toList();
      for (var i = 0; i < paths.length; i += 32) {
        final batch = paths.getRange(i, min(i + 32, paths.length));
        final valid = await Future.wait(batch.map((path) async {
          final file = File(path);
          if (!p.isWithin(_root, await file.resolveSymbolicLinks())) return false;
          final stat = await file.stat();
          return stat.type == FileSystemEntityType.file &&
              (keys.contains(path) ? stat.size == 16 : stat.size > 0);
        }));
        if (valid.contains(false)) return false;
      }
      return paths.isNotEmpty;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on UnsupportedError {
      return false;
    }
  }

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
      if (!p.isWithin(_root, path) || !_extensions.contains(p.extension(path))) {
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
        '.ac3' => 'audio/ac3',
        '.ec3' || '.eac3' => 'audio/eac3',
        '.mp3' => 'audio/mpeg',
        '.ts' => await _legacySegmentType(file),
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
