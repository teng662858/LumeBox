import 'playback_presentation.dart';

import 'dart:io';
import 'dart:math';

import '../net/lume_http.dart';
import '../net/network_settings.dart';

/// Select the highest HLS rendition before opening the native player.
/// A single-rendition master preserves separate audio and subtitle groups.
class HighestHls {
  HighestHls({this.inspectionTimeout = const Duration(milliseconds: 800)});

  /// Optional quality inspection must not hold native startup for several seconds.
  final Duration inspectionTimeout;
  HttpServer? _server;

  static String? singleRendition(
    String text,
    Uri base, {
    PlaybackPresentation? presentation,
  }) {
    final lines = text.split('\n').map((line) => line.trim()).toList();
    final variants =
        <({int index, int height, int bandwidth, bool hdr, bool dolby})>[];
    for (var i = 0; i + 1 < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      final height =
          int.tryParse(
            RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(lines[i])?.group(1) ??
                '',
          ) ??
          0;
      final bandwidth =
          int.tryParse(
            RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)')
                    .firstMatch(lines[i])
                    ?.group(1) ??
                '',
          ) ??
          0;
      if (lines[i + 1].isNotEmpty && !lines[i + 1].startsWith('#')) {
        final dolby = RegExp(
          r'(?:dvh1|dvhe)',
          caseSensitive: false,
        ).hasMatch(lines[i]);
        final hdr =
            dolby ||
            RegExp(
              r'VIDEO-RANGE=(PQ|HLG)',
              caseSensitive: false,
            ).hasMatch(lines[i]);
        variants.add((
          index: i,
          height: height,
          bandwidth: bandwidth,
          hdr: hdr,
          dolby: dolby,
        ));
      }
    }
    if (variants.length < 2) return null;
    final indices = variants.map((v) => v.index).toSet();
    final p = presentation;
    if (p != null) {
      // Prefer compatible alternatives, but retain single-format streams for tone mapping.
      if (!p.wantsHdr && variants.any((v) => !v.hdr)) {
        variants.removeWhere((v) => v.hdr);
      }
      if (!p.dolbyVision && variants.any((v) => !v.dolby)) {
        variants.removeWhere((v) => v.dolby);
      }
    }
    variants.sort((a, b) {
      if (p != null &&
          p.wantsHdr &&
          p.hdrPolicy == HdrPolicy.prefer &&
          a.hdr != b.hdr) {
        return a.hdr ? -1 : 1;
      }
      if (p != null &&
          p.wantsHdr &&
          p.dolbyVision &&
          a.height == b.height &&
          a.dolby != b.dolby) {
        return a.dolby ? -1 : 1;
      }
      final resolution = b.height.compareTo(a.height);
      return resolution != 0 ? resolution : b.bandwidth.compareTo(a.bandwidth);
    });
    final selected = variants.first.index;
    final result = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (indices.contains(i) && i != selected) {
        i++;
        continue;
      }
      var line = lines[i];
      if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;
      if (line.startsWith('#')) {
        line = line.replaceAllMapped(
          RegExp(r'URI="([^"]+)"'),
          (match) => 'URI="${base.resolve(match[1]!)}"',
        );
      } else if (line.isNotEmpty) {
        line = base.resolve(line).toString();
      }
      result.add(line);
    }
    return '${result.join('\n')}\n';
  }

  Future<Uri> resolve(
    Uri uri,
    Map<String, String>? headers, {
    PlaybackPresentation? presentation,
  }) async {
    await close();
    if (!['http', 'https'].contains(uri.scheme) ||
        !uri.path.toLowerCase().endsWith('.m3u8')) {
      return uri;
    }
    final http = LumeHttp(
      source: '起播画质选择',
      settings: NetworkSettings(timeout: inspectionTimeout, maxRetries: 0),
    );
    try {
      var base = uri;
      var requestHeaders = Map<String, String>.of(headers ?? {});
      final watch = Stopwatch()..start();
      late LumeHttpResponse response;
      for (var redirect = 0; redirect <= 3; redirect++) {
        final remaining = inspectionTimeout - watch.elapsed;
        if (remaining <= Duration.zero) return uri;
        response = await http
            .sendWithoutRedirects(
              url: base.toString(),
              headers: requestHeaders,
              maxBytes: 512 * 1024,
              timeout: remaining,
            )
            .timeout(remaining);
        if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
        final location = response.headers.entries
            .where((e) => e.key.toLowerCase() == 'location')
            .firstOrNull
            ?.value;
        if (location == null || redirect == 3) return uri;
        final next = base.resolve(location);
        if (!['http', 'https'].contains(next.scheme)) return uri;
        if (next.origin != base.origin) {
          requestHeaders.removeWhere(
            (key, _) => ['cookie', 'authorization'].contains(key.toLowerCase()),
          );
        }
        base = next;
      }
      if (response.statusCode != 200 ||
          !response.text.trimLeft().startsWith('#EXTM3U')) {
        return uri;
      }
      final master = singleRendition(
        response.text,
        base,
        presentation: presentation,
      );
      if (master == null) return uri;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      final key = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final path = '/$key/master.m3u8';
      server.listen((request) async {
        if (request.uri.path != path ||
            !['GET', 'HEAD'].contains(request.method)) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.set(
            'Content-Type',
            'application/vnd.apple.mpegurl',
          );
          request.response.headers.set('Cache-Control', 'no-store');
          if (request.method != 'HEAD') request.response.write(master);
        }
        await request.response.close();
      });
      return Uri.parse('http://127.0.0.1:${server.port}$path');
    } catch (_) {
      // Keep the original media usable if its manifest cannot be inspected.
      return uri;
    } finally {
      http.dispose();
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
