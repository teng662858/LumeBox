import 'playback_presentation.dart';
import 'hls_variants.dart';
import 'hls_attributes.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../net/lume_http.dart';
import '../net/http_header_scope.dart';
import '../net/network_settings.dart';

/// Select the highest HLS rendition before opening the native player.
/// A single-rendition master preserves separate audio and subtitle groups.
class HighestHls {
  HighestHls({this.inspectionTimeout = const Duration(milliseconds: 250)});

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
        <({int index, HlsVariantQuality quality, bool hdr, bool dolby, bool? hasVideo})>[];
    final pairs = hlsVariants(lines).toList();
    for (final pair in pairs) {
      final i = pair.tag;
      final attributes = hlsRawAttributes(lines[i]);
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
        quality: hlsVariantQuality(attributes),
        hdr: hdr,
        dolby: dolby,
        hasVideo: hlsVariantHasVideo(attributes),
      ));
    }
    if (variants.length < 2) return null;
    if (variants.any((v) => v.hasVideo != false)) {
      variants.removeWhere((v) => v.hasVideo == false);
    }
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
          a.quality.height == b.quality.height &&
          a.dolby != b.dolby) {
        return a.dolby ? -1 : 1;
      }
      return compareHlsQuality(a.quality, b.quality);
    });
    final selected = variants.first.index;
    final excluded = {
      for (final pair in pairs)
        if (pair.tag != selected) ...[pair.tag, pair.uri],
    };
    final result = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (excluded.contains(i)) continue;
      var line = lines[i];
      if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;
      if (line.startsWith('#')) {
        for (final ref in hlsUriAttributes(line).toList().reversed) {
          line = line.replaceRange(ref.start, ref.end, base.resolve(ref.value).toString());
        }
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
    if (!_isNetworkHls(uri)) return uri;
    try {
      _removeExpiredEntryInspections();
      final pending = _entryInspections.remove(_inspectionKey(uri, headers));
      final manifest = await (pending?.result ?? _inspect(uri, headers));
      if (manifest == null) return uri;
      final master = singleRendition(
        manifest.text,
        manifest.uri,
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
    }
  }

  static bool _isNetworkHls(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.path.toLowerCase().endsWith('.m3u8');

  // One-shot handoff to the kernel opening this same URL and header set.
  static final _entryInspections =
      <
        String,
        ({DateTime expires, Future<({Uri uri, String text})?> result})
      >{};

  static String _inspectionKey(Uri uri, Map<String, String>? headers) {
    final normalized = {
      for (final entry in (headers ?? const <String, String>{}).entries)
        entry.key.toLowerCase(): entry.value,
    };
    return jsonEncode([
      uri.toString(),
      for (final key in normalized.keys.toList()..sort())
        [key, normalized[key]],
    ]);
  }

  static void _removeExpiredEntryInspections() {
    final now = DateTime.now();
    _entryInspections.removeWhere((_, entry) => !entry.expires.isAfter(now));
  }

  static Future<bool?> entryIsPortrait(
    Uri uri,
    Map<String, String>? headers,
  ) async {
    if (!_isNetworkHls(uri)) return null;
    _removeExpiredEntryInspections();
    final key = _inspectionKey(uri, headers);
    if (_entryInspections.length >= 4 && !_entryInspections.containsKey(key)) {
      _entryInspections.remove(_entryInspections.keys.first);
    }
    final pending = _entryInspections.putIfAbsent(
      key,
      () => (
        expires: DateTime.now().add(const Duration(seconds: 1)),
        result: HighestHls()._inspect(uri, headers),
      ),
    );
    final manifest = await pending.result;
    return manifest == null ? null : manifestIsPortrait(manifest.text);
  }

  static bool? manifestIsPortrait(String manifest) {
    bool? portrait;
    final resolution = RegExp(r'^(\d+)x(\d+)$');
    for (final raw in manifest.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final attributes = hlsRawAttributes(line);
      if (hlsVariantHasVideo(attributes) == false) continue;
      final size = resolution.firstMatch(attributes['RESOLUTION'] ?? '');
      final width = int.tryParse(size?.group(1) ?? '');
      final height = int.tryParse(size?.group(2) ?? '');
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      final current = width < height;
      if (portrait != null && portrait != current) return null;
      portrait = current;
    }
    return portrait;
  }

  Future<({Uri uri, String text})?> _inspect(
    Uri uri,
    Map<String, String>? headers,
  ) async {
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
        if (remaining <= Duration.zero) return null;
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
        if (location == null || redirect == 3) return null;
        final next = base.resolve(location);
        if (!['http', 'https'].contains(next.scheme)) return null;
        if (next.origin != base.origin) {
          requestHeaders.removeWhere((key, _) => isOriginBoundHttpHeader(key));
        }
        base = next;
      }
      if (response.statusCode != 200 ||
          !response.text.trimLeft().startsWith('#EXTM3U')) {
        return null;
      }
      return (uri: base, text: response.text);
    } catch (_) {
      return null;
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
