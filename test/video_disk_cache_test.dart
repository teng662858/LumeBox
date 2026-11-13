import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/http_byte_range.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/playback_diagnostics.dart';
import 'package:lume_box/core/player/apple_hls_fragments.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  late Directory root;
  late VideoDiskCache cache;
  late HttpServer server;
  late HttpClient client;
  late Uri upstream;
  final data = Uint8List.fromList(List.generate(2500000, (i) => i % 251));
  final ts = Uint8List(188 * 7000);
  for (var i = 0; i < ts.length; i += 188) {
    ts.setAll(i, [0x47, 0x40, 0, 0x10]);
  }
  final pngPrefix = Uint8List(4096)
    ..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  final pngTs = Uint8List.fromList([...pngPrefix, ...ts]);
  var calls = 0;
  final paths = <String>[];
  var failures = 0;

  test(
    'reopening a video session preserves already buffered disk blocks',
    () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final response = await client.getUrl(wrapped.uri).then((r) => r.close());
      await response.drain<void>();
      final files = await Directory('${root.path}/video-buffer-v1')
          .list()
          .toList();
      expect(files, isNotEmpty);
      await cache.boot(directory: root);
      for (final file in files) {
        expect(await file.exists(), isTrue);
      }
    },
  );

  for (final throws in [false, true]) {
    test('缓存装载失败回退原始地址并保留请求头：throws=$throws', () async {
      final player = _TransportPlayer(throws);
      final media = PlayerMedia(
        uri: upstream,
        headers: {'Referer': 'https://example.test/'},
      );
      await cache.load(player, media);
      expect(player.loads, hasLength(2));
      expect(player.loads.last, same(media));
      expect(player.state.value.error, isNull);
      expect(await cache.wrap(media), same(media));
      expect(cache.status, contains('内核缓冲'));
      player.state.dispose();
      player.info.dispose();
    });
  }
  test('内核暂时隐藏错误进行重试时，等待终态后仍回退原地址', () async {
    final player = _TransportPlayer(false, delayed: true);
    final media = PlayerMedia(uri: upstream);
    await cache.load(player, media);
    expect(player.loads, hasLength(2));
    expect(player.loads.last, same(media));
    expect(player.state.value.error, isNull);
    player.state.dispose();
    player.info.dispose();
  });
  Completer<void>? pause;
  late Completer<void> slowBody;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('video-buffer-test-');
    cache = VideoDiskCache();
    cache.freeSpace = () async => 10 * 1024 * 1024 * 1024;
    await cache.boot(directory: root);
    client = HttpClient();
    calls = 0;
    paths.clear();
    failures = 0;
    pause = null;
    slowBody = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream = Uri.parse('http://127.0.0.1:${server.port}/movie.mp4');
    server.listen((request) async {
      calls++;
      paths.add(request.uri.path);
      if (request.uri.path.startsWith('/rotate/')) {
        if (request.uri.path.endsWith('.m3u8')) {
          final tag = request.uri.queryParameters['tag'] ?? 'KEY';
          final resource = request.uri.queryParameters['key'] ?? 'secret.mp4';
          request.response.write('#EXTM3U\n#EXT-X-$tag:METHOD=AES-128,URI="$resource?sig=fixture"\n'
              '#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n');
        } else if (request.headers.value('range') != null ||
            request.uri.query != 'sig=fixture' ||
            request.headers.value('authorization') != 'Bearer fixture') {
          request.response.statusCode = 403;
        } else {
          final version = paths.where((path) => path == request.uri.path).length;
          if (request.uri.path.endsWith('invalid') && version <= 2) {
            request.response.add(List.filled(version == 1 ? 15 : 17, 42));
          } else if (request.uri.path.endsWith('invalid')) {
            request.response.headers.set('Content-Encoding', 'gzip');
            request.response.add(gzip.encode(ascii.encode('<html>0123456789')));
          } else {
            request.response.add(List.filled(16, version));
          }
        }
        await request.response.close();
        return;
      }
      if (request.uri.path.startsWith('/audio-track/')) {
        if (request.uri.path.endsWith('.m3u8')) {
          final suffix = request.uri.queryParameters['ext'];
          final part = request.uri.queryParameters.containsKey('large') ? 'large' : 'part';
          request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n$part.$suffix?sig=A\n#EXT-X-ENDLIST\n');
        } else if (request.headers.value('range') != null) {
          request.response.statusCode = 403;
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(request.uri.path.contains('/large.') ? data : data.sublist(0, 128));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path.startsWith('/subtitles/')) {
        final type = request.uri.queryParameters['type'] ?? 'vtt';
        if (request.uri.path.endsWith('/master.m3u8')) {
          request.response.write('#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",LANGUAGE="zh",URI="track?type=$type"\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=10000,SUBTITLES="subs"\nvideo.m3u8\n');
        } else if (request.uri.path.endsWith('/track')) {
          request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
              '${type == 'mp4' ? '#EXT-X-MAP:URI="init?sig=A"\n' : ''}'
              '#EXTINF:1,\ncue?sig=B&type=$type\n#EXT-X-ENDLIST\n');
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(type == 'mp4'
              ? [0, 0, 0, 8, ...ascii.encode('moof')]
              : utf8.encode('WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:00.000 --> 00:00:01.000\n字幕\n'));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path == '/live/master.m3u8') {
        request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=50000\nvideo?sig=a%2Fb+z&tag=x&tag=y&_HLS_msn=7\n');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/live/video') {
        final sequence = request.uri.queryParameters['_HLS_msn'];
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:$sequence\n'
          '#EXT-X-PART-INF:PART-TARGET=0.5\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES\n'
          '#EXT-X-PART:DURATION=0.5,URI="part-$sequence.m4s"\n',
        );
        paths.add(request.uri.query);
        paths.add(request.headers.value('authorization') ?? '');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/live/hints.m3u8') {
        final first = paths.where((p) => p == '/live/hints.m3u8').length == 1;
        final mapTag = first ? '#EXT-X-PRELOAD-HINT:TYPE=MAP,' : '#EXT-X-MAP:';
        final partTag = first ? '#EXT-X-PRELOAD-HINT:TYPE=PART,' : '#EXT-X-PART:DURATION=0.5,';
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
            '#EXT-X-PART-INF:PART-TARGET=0.5\n'
            '${mapTag}URI="init?sig=A"\n${partTag}URI="chunk?sig=B"\n');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/live/chunk' || request.uri.path == '/live/init') {
        if (request.headers.value('range') != null) {
          request.response.statusCode = 403;
        } else {
          request.response.add(data.sublist(0, 256));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path.startsWith('/challenge/')) {
        request.response.headers.set('Content-Type', 'application/octet-stream');
        final payload = calls == 1
            ? utf8.encode('\uFEFF  <!DOCTYPE html><html>verify</html>')
            : data.sublist(0, 128);
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
        return;
      }
      if (request.uri.path.startsWith('/limited/')) {
        if (request.uri.path.endsWith('/start.m3u8')) {
          if (request.headers.value('range') != null) {
            request.response.statusCode = 403;
            await request.response.close();
            return;
          }
          await request.response.redirect(upstream.resolve('/limited/sub/index.m3u8').replace(query: request.uri.query));
          return;
        }
        if (request.uri.path.endsWith('key.bin') || request.uri.path.endsWith('part.ts')) {
          request.response.add(request.uri.path.endsWith('key.bin') ? List.filled(16, 7) : [1, 2, 3]);
          await request.response.close();
          return;
        }
        final limit = request.uri.queryParameters['encoding'] == 'gzip' ? 16 : 24;
        final plain = utf8.encode('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n');
        final compressed = request.uri.queryParameters['encoding'] == 'gzip';
        final content = compressed ? gzip.encode(plain) : plain;
        final raw = request.headers.value('range') ?? 'bytes=0-';
        final start = raw == 'bytes=-1' ? content.length - 1
            : int.parse(RegExp(r'^bytes=(\d+)-').firstMatch(raw)![1]!);
        final end = (start + limit).clamp(0, content.length);
        if (start >= content.length) {
          request.response.statusCode = 416;
          request.response.headers.set('Content-Range', 'bytes */${content.length}');
        } else {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes $start-${end - 1}/${compressed ? "*" : content.length}');
          request.response.headers.set('Content-Type', 'application/octet-stream');
          if (compressed) request.response.headers.set('Content-Encoding', 'gzip');
          request.response.add(content.sublist(start, end));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path == '/unknown-total.mp4') {
        final range = request.headers.value('range');
        final offsets = range == null ? null : parseHttpByteRange(range, data.length);
        final response = request.response;
        if (range != null && offsets == null) {
          response.statusCode = 416;
          response.headers.set('Content-Range', 'bytes */${data.length}');
        } else if (offsets != null) {
          response.statusCode = 206;
          response.headers.set('Content-Range', 'bytes ${offsets.start}-${offsets.end}/*');
          response.add(data.sublist(offsets.start, offsets.end + 1));
        } else {
          response.add(data);
        }
        await response.close();
        return;
      }
      if (request.uri.path == '/slow-redirect.mp4') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/movie.mp4');
        request.response.write('redirecting');
        await request.response.flush();
        await slowBody.future;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/encoded-script') {
        final codec = request.uri.queryParameters['codec'] == 'gzip' ? gzip : zlib;
        final manifest = utf8.encode('#EXTM3U\n#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n');
        request.response.headers.set('Content-Type', 'application/octet-stream');
        request.response.headers.set('Content-Encoding', request.uri.queryParameters['codec']!);
        request.response.add(codec.encode(manifest));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/error-body.mp4' && calls == 1) {
        final status = int.parse(request.uri.queryParameters['status']!);
        request.response.statusCode = status;
        if (status == 416) {
          request.response.headers.set('Content-Range', 'bytes */0');
        }
        request.response.write('error');
        await request.response.flush();
        await slowBody.future;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/large-nonseekable.mp4') {
        final response = request.response;
        final length = VideoDiskCache.blockBytes * 9;
        response.contentLength = length;
        if (request.headers.value('range') != null) {
          response.add(Uint8List(length));
        } else {
          response.add([0]);
          await response.flush();
          await slowBody.future;
        }
        await response.close().catchError((Object _) {});
        return;
      }
      if (request.uri.path == '/mislabelled.mp4') {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.write(
          '#EXTM3U\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
        return;
      }
      if (request.uri.path == '/slow-cache.mp4') {
        request.response.contentLength = data.length;
        request.response.add(data.sublist(0, VideoDiskCache.blockBytes));
        await request.response.flush();
        await pause!.future;
        request.response.add(data.sublist(VideoDiskCache.blockBytes));
        await request.response.close();
        return;
      }
      if (['/slow.ts', '/slow.mp4', '/slow.aac'].contains(request.uri.path)) {
        if (request.uri.path != '/slow.aac') request.response.contentLength = data.length;
        request.response.add(data.sublist(0, 16384));
        await request.response.flush();
        await pause!.future;
        request.response.add(data.sublist(16384));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/slow-probe.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nslow.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
        return;
      }
      if (request.uri.path.startsWith('/status/')) {
        request.response.statusCode = int.parse(request.uri.pathSegments.last);
        request.response.write('private upstream error body');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/cloud-download') {
        request.response.headers.set('Content-Type', 'video/mp4');
        request.response.add([0x1a, 0x45, 0xdf, 0xa3, ...List.filled(1024, 0)]);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/png-segment.ts') {
        final range = RegExp(r'bytes=(\d+)-(\d*)')
            .firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end =
            (range == null || range[2]!.isEmpty
                    ? pngTs.length - 1
                    : int.parse(range[2]!))
                .clamp(start, pngTs.length - 1);
        request.response.statusCode = 206;
        request.response.headers.set('Content-Type', 'image/png');
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${pngTs.length}',
        );
        request.response.add(pngTs.sublist(start, end + 1));
        await request.response.close();
        return;
      }
      if (pause != null) await pause!.future;
      if (request.uri.path == '/ads.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXTINF:1,\nmain.ts\n#EXT-X-CUE-OUT:1\n#EXTINF:1,\nad.ts\n#EXT-X-CUE-IN\n#EXTINF:1,\nnext.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
        return;
      }
      if (failures > 0) {
        failures--;
        request.response.statusCode = 502;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/nested/master.m3u8');
        await request.response.close();
        return;
      }
      if (request.uri.path.endsWith('/master.m3u8')) {
        if (request.uri.path.startsWith('/no-range/') &&
            request.headers.value('range') != null) {
          request.response.statusCode = 502;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        const playlist =
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n';
        if (request.uri.path.startsWith('/gzip/')) {
          request.response.headers.set('Content-Encoding', 'gzip');
          request.response.add(gzip.encode(utf8.encode(playlist)));
        } else {
          request.response.write(playlist);
        }
      } else {
        final match = RegExp(r'bytes=(\d+)-(\d*)')
            .firstMatch(request.headers.value('range') ?? '');
        final start = match == null ? 0 : int.parse(match[1]!);
        final replacement = request.uri.path == '/replaced.mp4';
        final lateTag = request.uri.query == 'late';
        final revisionRequest = paths.where((p) => p == '/replaced.mp4').length;
        final oldVersion = replacement && revisionRequest <= (lateTag ? 2 : 1);
        if (replacement && (!lateTag || revisionRequest > 1)) {
          request.response.headers.set('ETag', oldVersion ? '"old"' : '"new"');
        }
        if (request.uri.path == '/expires.mp4' &&
            start >= VideoDiskCache.blockBytes) {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/changes.mp4' &&
            start >= VideoDiskCache.blockBytes) {
          request.response.statusCode = 200;
          request.response.add(data);
          await request.response.close();
          return;
        }
        final requestedEnd = match == null || match[2]!.isEmpty
            ? data.length - 1
            : int.parse(match[2]!);
        if (start >= data.length) {
          request.response.statusCode = 416;
          request.response.headers.set(
            'Content-Range',
            'bytes */${data.length}',
          );
          await request.response.close();
          return;
        }
        final end = requestedEnd.clamp(start, data.length - 1);
        request.response.statusCode = 206;
        // Reproduce a cat proxy declaring the whole remainder while sending
        // only one capped block. The host must stitch all subsequent ranges.
        request.response.headers.set(
          'Content-Range',
          'bytes $start-${data.length - 1}/${data.length}',
        );
        request.response.headers.set('Content-Type', 'video/mp4');
        final body = data.sublist(start, end + 1);
        request.response.contentLength = body.length;
        request.response.add(oldVersion ? Uint8List(body.length) : body);
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await cache.close();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> get(Uri uri, [String? range]) async {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set('Range', range);
    final response = await request.close();
    return (response, await response.expand((b) => b).toList());
  }

  for (final apple in [true, false]) {
    test('signed WebVTT subtitle cues retain their media type during playback and seeking (apple=$apple)', () async {
      final master = await cache.wrap(PlayerMedia(uri: upstream.resolve('/subtitles/master.m3u8')), appleHls: apple);
      final manifest = utf8.decode((await get(master.uri)).$2);
      final track = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(manifest)![1]!);
      final playlist = utf8.decode((await get(track)).$2);
      final cue = Uri.parse(const LineSplitter().convert(playlist).firstWhere((line) => !line.startsWith('#')));
      expect(paths, isNot(contains('/subtitles/cue')), reason: 'listing subtitles should not probe cues for video codecs');
      final full = await get(cue);
      expect(full.$1.headers.contentType?.mimeType, 'text/vtt');
      expect(utf8.decode(full.$2), contains('字幕'));
      expect(cue.path, endsWith('.vtt'));
      final slice = await get(cue, 'bytes=0-5');
      expect(slice.$1.headers.contentType?.mimeType, 'text/vtt');
      expect(utf8.decode(slice.$2), 'WEBVTT');
    });
  }
  for (final (extension, type) in [('aac', 'audio/aac'), ('ac3', 'audio/ac3'), ('ec3', 'audio/eac3'), ('mp3', 'audio/mpeg')]) {
    test('HLS packed $extension audio can play from a server that rejects Range', () async {
      final track = await cache.wrap(PlayerMedia(uri: upstream.resolve('/audio-track/main.m3u8?ext=$extension')));
      final playlist = utf8.decode((await get(track.uri)).$2);
      final uri = Uri.parse(const LineSplitter().convert(playlist).firstWhere((line) => !line.startsWith('#')));
      final coldProbe = await get(uri, 'bytes=0-1');
      expect(coldProbe.$1.statusCode, 206);
      expect(coldProbe.$2, data.take(2));
      final initial = await get(uri);
      expect(initial.$1.contentLength, 128, reason: 'finite audio must have an unambiguous EOF');
      final probe = await get(uri, 'bytes=4-15');
      expect(probe.$1.statusCode, 206);
      expect(probe.$2, data.sublist(4, 16));
      final response = await get(uri);
      expect(response.$1.statusCode, 200);
      expect(response.$1.headers.contentType?.mimeType, type);
      expect(response.$2, data.take(128));
    });
  }
  test('chunked packed audio larger than a buffer block preserves byte ranges and EOF', () async {
    final track = await cache.wrap(PlayerMedia(uri: upstream.resolve('/audio-track/main.m3u8?ext=aac&large=1')));
    final manifest = utf8.decode((await get(track.uri)).$2);
    final uri = Uri.parse(const LineSplitter().convert(manifest).firstWhere((line) => !line.startsWith('#')));
    final partial = await get(uri, 'bytes=-64');
    expect(partial.$1.statusCode, 206);
    expect(partial.$1.headers.value('content-range'), 'bytes ${data.length-64}-${data.length-1}/${data.length}');
    expect(partial.$2, data.sublist(data.length-64));
    final complete = await get(uri);
    expect(complete.$1.contentLength, data.length);
    expect(complete.$2, data);
  });
  test('mapped fMP4 subtitles retain their initialization and fragment routes', () async {
    final master = await cache.wrap(PlayerMedia(
      uri: upstream.resolve('/subtitles/master.m3u8?type=mp4'),
    ), appleHls: true);
    final manifest = utf8.decode((await get(master.uri)).$2);
    final track = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(manifest)![1]!);
    final playlist = utf8.decode((await get(track)).$2);
    expect(playlist, matches(RegExp(r'#EXT-X-MAP:URI="[^"]+\.mp4"')));
    final cue = Uri.parse(const LineSplitter().convert(playlist).firstWhere((line) => !line.startsWith('#')));
    expect(cue.path, endsWith('.m4s'));
    expect((await get(cue)).$2, [0, 0, 0, 8, ...ascii.encode('moof')]);
  });
  for (final apple in [true, false]) {
    test('low latency reloads forward the requested live part through a signed variant (apple=$apple)', () async {
      final master = await cache.wrap(PlayerMedia(
        uri: upstream.resolve('/live/master.m3u8'),
        headers: const {'Authorization': 'fixture'},
      ), appleHls: apple);
      final manifest = utf8.decode((await get(master.uri)).$2);
      final variant = Uri.parse(const LineSplitter().convert(manifest).last);
      final results = await Future.wait([
        for (final sequence in [8, 9])
          get(variant.replace(query: '_HLS_msn=$sequence&_HLS_part=1&_HLS_skip=v2&sig=override&x=extra')),
      ]);
      for (var i = 0; i < results.length; i++) {
        final sequence = 8 + i;
        expect(utf8.decode(results[i].$2), contains('#EXT-X-MEDIA-SEQUENCE:$sequence\n'));
        expect(paths, contains('sig=a%2Fb+z&tag=x&tag=y&_HLS_msn=$sequence&_HLS_part=1&_HLS_skip=v2'));
      }
      expect(paths.where((p) => p == 'fixture'), hasLength(2));
    });
  }
  test('preload hints retain their local URL when signed parts and maps are published', () async {
    final media = await cache.wrap(PlayerMedia(uri: upstream.resolve('/live/hints.m3u8')));
    Future<List<String>> resources() async {
      final manifest = utf8.decode((await get(media.uri)).$2);
      return [for (final match in RegExp(r'URI="([^"]+)"').allMatches(manifest)) match[1]!];
    }
    final hints = await resources();
    for (final hint in hints) {
      final response = await get(Uri.parse(hint));
      expect(response.$1.statusCode, 200);
      expect(response.$2, data.take(256));
    }
    final published = await resources();
    expect(hints, published);
    expect(hints.first, endsWith('.mp4'));
    expect(hints.last, endsWith('.m4s'));
  });
  for (final (path, range) in [
    ('movie.mp4', null),
    ('movie.mp4', 'bytes=0-15'),
    ('part.ts', null),
    ('play', null),
  ]) {
    test('a temporary HTML challenge cannot poison media retries ($path, $range)', () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream.resolve('/challenge/$path')));
      final first = await get(wrapped.uri, range);
      final second = await get(wrapped.uri);
      expect(second.$2, data.sublist(0, 128));
      expect(first.$1.statusCode, 502);
      expect(first.$2, isEmpty);
      expect(second.$1.statusCode, 200);
      expect(calls, 2);
    });
  }

  for (final (path, encoding) in [
    ('start.m3u8', 'identity'), ('start.m3u8', 'gzip'), ('sub/label.mp4', 'identity'),
  ]) {
    test('complete a capped $encoding HLS playlist before rewriting $path', () async {
      final media = await cache.wrap(PlayerMedia(uri: upstream.resolve('/limited/$path?encoding=$encoding')));
      final result = await get(media.uri);
      expect(result.$1.statusCode, 200);
      final manifest = utf8.decode(result.$2);
      expect(manifest, contains('#EXT-X-ENDLIST'));
      final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(manifest)![1]!);
      final part = Uri.parse(LineSplitter.split(manifest).firstWhere((line) => line.startsWith('http')));
      expect((await get(key)).$2, List.filled(16, 7));
      expect((await get(part)).$2, [1, 2, 3]);
      expect(paths, containsAll(['/limited/sub/key.bin', '/limited/sub/part.ts']));
    });
  }

  test(
    'an MP4-labelled HLS manifest still rewrites relative children',
    () async {
      final wrapped = await cache.wrap(
        PlayerMedia(uri: upstream.resolve('/mislabelled.mp4')),
      );
      final result = await get(wrapped.uri);
      final manifest = utf8.decode(result.$2);
      expect(
        result.$1.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      expect(manifest, contains('http://127.0.0.1:'));
      expect(manifest, isNot(contains('\npart.ts\n')));
    },
  );

  for (final suffix in ['ts', 'mp4', 'aac']) {
    test(
      'slow $suffix delivers first bytes before the upstream finishes',
      () async {
        pause = Completer<void>();
        final wrapped = await cache.wrap(
          PlayerMedia(uri: upstream.resolve('/slow.$suffix')),
        );
        final request = await client.getUrl(wrapped.uri);
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        final chunks = StreamIterator(response);
        try {
          expect(
            await chunks.moveNext().timeout(const Duration(seconds: 2)),
            isTrue,
          );
          expect(chunks.current, isNotEmpty);
          expect(
            pause!.isCompleted,
            isFalse,
            reason: 'first bytes must not wait for a complete block',
          );
          pause!.complete();
          var bytes = chunks.current.length;
          while (await chunks.moveNext()) {
            bytes += chunks.current.length;
          }
          expect(bytes, data.length);
        } finally {
          if (!pause!.isCompleted) pause!.complete();
          await chunks.cancel();
        }
      },
    );
  }

  test('streaming persists completed blocks before EOF and reuses later blocks', () async {
    pause = Completer<void>();
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/slow-cache.mp4')),
    );
    final request = await client.getUrl(wrapped.uri);
    final response = await request.close();
    var received = 0;
    final completed = response.forEach((chunk) => received += chunk.length);
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (cache.bytes < VideoDiskCache.blockBytes &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, VideoDiskCache.blockBytes);
      expect(pause!.isCompleted, isFalse);
    } finally {
      pause!.complete();
      await completed;
    }
    expect(received, data.length);
    // A content-length reader can finish before the final optional disk write.
    final persisted = DateTime.now().add(const Duration(seconds: 2));
    while (cache.bytes < data.length && DateTime.now().isBefore(persisted)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(cache.bytes, data.length);
    final beforeSeek = calls;
    final seek = await get(wrapped.uri, 'bytes=1500000-1500030');
    expect(seek.$2, data.sublist(1500000, 1500031));
    expect(calls, beforeSeek, reason: 'later streamed blocks remain cached');
  });

  test(
    'Apple codec probe reads a prefix without waiting for the complete segment',
    () async {
      pause = Completer<void>();
      final wrapped = await cache.wrap(
        PlayerMedia(uri: upstream.resolve('/slow-probe.m3u8')),
        appleHls: true,
      );
      try {
        final result = await get(wrapped.uri)
            .timeout(const Duration(seconds: 2));
        expect(utf8.decode(result.$2), contains('#EXTM3U'));
        expect(pause!.isCompleted, isFalse);
      } finally {
        pause!.complete();
      }
    },
  );

  test('签名识别 MKV、DASH 和伪图片 HLS，普通数据不误判', () {
    expect(VideoDiskCache.detectFormat([0x1a, 0x45, 0xdf, 0xa3]), '.mkv');
    expect(
      VideoDiskCache.detectFormat(utf8.encode('\uFEFF #EXTM3U\n')),
      '.m3u8',
    );
    expect(
      VideoDiskCache.detectFormat(
        utf8.encode('<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash"/>'),
      ),
      '.mpd',
    );
    expect(
      VideoDiskCache.detectFormat(utf8.encode('<html>unavailable</html>')),
      '',
    );
  });

  test('PNG 前缀只剥离确认的 TS，分段和后缀 Range 仍对应媒体字节', () async {
    expect(transportStreamImagePrefix(pngTs), 4096);
    expect(transportStreamImagePrefix(ts), 0);
    expect(transportStreamImagePrefix([...pngPrefix, ...data.take(1000)]), 0);
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/png-segment.ts')),
    );
    expect((await get(wrapped.uri)).$2, ts);
    final first = await get(wrapped.uri, 'bytes=0-31');
    expect(first.$1.headers.value('content-range'), 'bytes 0-31/${ts.length}');
    expect(first.$1.headers.value('content-type'), 'video/mp2t');
    expect(first.$2, ts.sublist(0, 32));
    final tail = await get(wrapped.uri, 'bytes=-32');
    expect(tail.$2, ts.sublist(ts.length - 32));
    final cross = await get(wrapped.uri, 'bytes=1040000-1060000');
    expect(cross.$2, ts.sublist(1040000, 1060001));
  });

  test('无后缀且 MIME 错报 MP4 的 MKV 在 Apple 内核前识别并可交 MPV', () async {
    final media = PlayerMedia(uri: upstream.resolve('/cloud-download'));
    await expectLater(
      cache.wrap(media, inspect: true, appleHls: true),
      throwsUnsupportedError,
    );
    final wrapped = await cache.wrap(media, inspect: true);
    expect(wrapped.uri.path, endsWith('.mkv'));
    expect(
      calls,
      1,
      reason: 'confirmed format is reused across kernel switches',
    );
  });

  test('a redirect opens the media without waiting for the redirect body to finish', () async {
    final wrapped = await cache.wrap(PlayerMedia(uri: upstream.resolve('/slow-redirect.mp4')));
    try {
      final (response, bytes) = await get(wrapped.uri, 'bytes=0-31').timeout(const Duration(seconds: 2));
      expect(response.statusCode, 206);
      expect(bytes, data.take(32));
    } finally {
      slowBody.complete();
    }
  });

  for (final status in [502, 416]) {
    test('range playback handles HTTP $status before the error body ends', () async {
      final media = PlayerMedia(uri: upstream.resolve('/error-body.mp4?status=$status'));
      final wrapped = await cache.wrap(media);
      try {
        final (res, bytes) = await get(wrapped.uri, 'bytes=0-31').timeout(const Duration(seconds: 3));
        expect(res.statusCode, status == 502 ? 206 : 416);
        expect(bytes, status == 502 ? data.sublist(0, 32) : isEmpty);
        if (status == 416) expect(res.headers.value('content-range'), 'bytes */0');
      } finally {
        slowBody.complete();
      }
    });
  }

  test('HEAD passthrough returns metadata while the upstream GET is open', () async {
    final wrapped = await cache.wrap(PlayerMedia(uri: upstream.resolve('/large-nonseekable.mp4')));
    try {
      final head = await client.headUrl(wrapped.uri);
      final response = await head.close().timeout(const Duration(seconds: 3));
      expect(response.statusCode, 200);
      expect(response.contentLength, VideoDiskCache.blockBytes * 9);
      expect(await response.expand((bytes) => bytes).toList(), isEmpty);
    } finally {
      slowBody.complete();
    }
  });

  for (final path in ['/expires.mp4', '/changes.mp4']) {
    test('首块已发送后上游失败不再修改响应头：$path', () async {
      final wrapped = await cache.wrap(
        PlayerMedia(uri: upstream.resolve(path)),
      );
      final request = await client.getUrl(wrapped.uri);
      request.headers.set('Range', 'bytes=0-');
      final response = await request.close();
      var bytes = 0;
      try {
        await for (final chunk in response) {
          bytes += chunk.length;
        }
      } on HttpException {
        // A partial body must terminate instead of appending an error page.
      }
      expect(bytes, VideoDiskCache.blockBytes);
      expect(response.statusCode, 206);
      if (path == '/changes.mp4') {
        expect(
          PlaybackDiagnostics.snapshot.last['stage'],
          'cache-stream-interrupted',
        );
      }
    });
  }
  test('播放缓存遇到同标签的重定向替换会中断旧响应，重试读取完整新视频', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    var switched = false;
    source.listen((r) async {
      final range = r.headers.value('range') ?? '';
      final start = int.tryParse(RegExp(r'^bytes=(\d+)-').firstMatch(range)?[1] ?? '') ?? 0;
      if (r.uri.path == '/play.mp4') {
        if (start > 0) switched = true;
        await r.response.redirect(r.uri.resolve(switched ? '/b' : '/a'));
        return;
      }
      final end = (start + VideoDiskCache.blockBytes).clamp(start, data.length);
      r.response.statusCode = 206;
      r.response.headers.set('Content-Range', 'bytes $start-${end - 1}/${data.length}');
      r.response.headers.set('ETag', '"revision-1"');
      r.response.add(r.uri.path == '/a' ? Uint8List(end - start) : data.sublist(start, end));
      await r.response.close();
    });
    final wrapped = await cache.wrap(PlayerMedia(uri: Uri.parse('http://127.0.0.1:${source.port}/play.mp4')));
    final first = await client.getUrl(wrapped.uri);
    first.headers.set('Range', 'bytes=0-');
    final response = await first.close();
    var count = 0;
    try {
      await for (final chunk in response) {
        count += chunk.length;
      }
    } on HttpException {
      // The first block has already been sent with the original length.
    }
    expect(count, VideoDiskCache.blockBytes);
    expect((await get(wrapped.uri, 'bytes=0-')).$2, data);
  });

  for (final lateTag in [false, true]) {
    test('retry after an ETag change drops the old prefix and plays the replacement (lateTag=$lateTag)', () async {
      final other = await cache.wrap(PlayerMedia(uri: upstream));
      await get(other.uri, 'bytes=0-15');
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream.resolve(lateTag ? '/replaced.mp4?late' : '/replaced.mp4')));
      final first = await client.getUrl(wrapped.uri);
      first.headers.set('Range', 'bytes=0-');
      final interrupted = await first.close();
      var received = 0;
      try {
        await for (final chunk in interrupted) {
          received += chunk.length;
        }
      } on HttpException {
        // A changed representation cannot complete the existing response.
      }
      expect(received, VideoDiskCache.blockBytes * (lateTag ? 2 : 1));
      final retry = await get(wrapped.uri, 'bytes=0-');
      expect(retry.$1.statusCode, 206);
      expect(retry.$2, data);
      final previousCalls = calls;
      expect((await get(other.uri, 'bytes=0-15')).$2, data.take(16));
      expect(calls, previousCalls, reason: 'another video keeps its buffered data');
    });
  }

  test('HLS key assembly detects a rotation after a late ETag', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    var requests = 0;
    source.listen((r) async {
      if (r.uri.path == '/master.m3u8') {
        r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\ns.ts\n#EXT-X-ENDLIST\n');
      } else {
        requests++;
        final start = switch (r.headers.value('range')) {
          'bytes=4-' => 4,
          'bytes=8-' => 8,
          _ => 0,
        };
        final end = start == 8 ? 15 : start + 3;
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes $start-$end/16');
        if (requests != 1) {
          r.response.headers.set('ETag', requests == 2 ? '"old"' : '"new"');
        }
        r.response.add(List.filled(end - start + 1, requests < 3 ? 1 : 2));
      }
      await r.response.close();
    });
    final manifest = await cache.wrap(PlayerMedia(
      uri: Uri.parse('http://127.0.0.1:${source.port}/master.m3u8'),
    ));
    final text = utf8.decode((await get(manifest.uri)).$2);
    final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(text)![1]!);
    final mixed = await get(key);
    expect(mixed.$1.statusCode, 502);
    expect(mixed.$2, isEmpty);
    expect((await get(key)).$2, List.filled(16, 2));
  });

  test('分段 HLS 密钥重定向到另一文件时不会交给播放器', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    var switched = false;
    source.listen((r) async {
      if (r.uri.path == '/master.m3u8') {
        r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\ns.ts\n#EXT-X-ENDLIST\n');
      } else {
        final tail = r.headers.value('range') == 'bytes=8-';
        if (r.uri.path == '/key' && (tail || switched)) {
          switched = true;
          await r.response.redirect(r.uri.resolve('/replacement'));
          return;
        }
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', tail ? 'bytes 8-15/16' : 'bytes 0-7/16');
        r.response.headers.set('ETag', '"revision-1"');
        r.response.add(List.filled(8, switched ? 2 : 1));
      }
      await r.response.close();
    });
    final media = await cache.wrap(PlayerMedia(uri: Uri.parse('http://127.0.0.1:${source.port}/master.m3u8')));
    final text = utf8.decode((await get(media.uri)).$2);
    final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(text)![1]!);
    final mixed = await get(key);
    expect(mixed.$1.statusCode, 502);
    expect(mixed.$2, isEmpty);
    expect((await get(key)).$2, List.filled(16, 2));
  });

  test('未知长度的视频不会采用另一个文件的尾字节作为总长度', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    source.listen((r) async {
      if (r.uri.path == '/video.mp4' && r.headers.value('range') == 'bytes=-1') {
        await r.response.redirect(r.uri.resolve('/other'));
        return;
      }
      r.response.statusCode = 206;
      r.response.headers.set('ETag', '"rev-1"');
      if (r.uri.path == '/other') {
        r.response.headers.set('Content-Range', 'bytes 199-199/200');
        r.response.add([0]);
      } else {
        r.response.headers.set('Content-Range', 'bytes 0-31/*');
        r.response.add(List.filled(32, 1));
      }
      await r.response.close();
    });
    final media = await cache.wrap(PlayerMedia(
      uri: Uri.parse('http://127.0.0.1:${source.port}/video.mp4'),
    ));
    final response = await (await client.openUrl('HEAD', media.uri)).close();
    expect(response.statusCode, 502);
    expect(response.contentLength, isNot(200));
    await response.drain<void>();
  });

  test(
    'remote ranged MP4 delivers first bytes without filling a cache block',
    () async {
      final gate = Completer<void>();
      var nativeRequests = 0;
      Stream<List<int>> body() async* {
        yield data.sublist(0, 16384);
        await gate.future;
        yield data.sublist(16384);
      }

      final native = MockClient.streaming((request, outgoing) async {
        nativeRequests++;
        expect(request.headers['range'], 'bytes=0-');
        return http.StreamedResponse(
          body(),
          206,
          contentLength: data.length,
          headers: {
            'content-length': '${data.length}',
            'content-range': 'bytes 0-${data.length - 1}/${data.length}',
          },
        );
      });
      await cache.close();
      cache = VideoDiskCache(ipHttpsClient: native);
      await cache.boot(directory: root);
      cache.capacityMb = 1;
      final wrapped = await cache.wrap(
        PlayerMedia(uri: Uri.parse('https://192.0.2.1/movie.mp4')),
      );
      final request = await client.getUrl(wrapped.uri);
      request.headers.set('Range', 'bytes=0-');
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      final chunks = StreamIterator(response);
      try {
        expect(
          await chunks.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(response.statusCode, 206);
        expect(gate.isCompleted, isFalse);
        gate.complete();
        var received = chunks.current.length;
        while (await chunks.moveNext()) {
          received += chunks.current.length;
        }
        expect(received, data.length);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await chunks.cancel();
      }
      final tailBytes = data.length % VideoDiskCache.blockBytes;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (cache.bytes != tailBytes && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, tailBytes);
      final tailSeek = await get(wrapped.uri, 'bytes=2200000-2200030');
      expect(tailSeek.$2, data.sublist(2200000, 2200031));
      expect(
        nativeRequests,
        1,
        reason: 'seek hits cache after block zero was evicted',
      );
    },
  );

  test('IP HTTPS playlists use native transport, retain scoped headers and rewrite segments', () async {
    final requests = <http.Request>[];
    final native = MockClient((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      expect(request.headers['user-agent'], 'media-agent');
      if (request.url.path == '/resolve') {
        expect(request.headers['authorization'], 'test-only');
        expect(request.headers['proxy-authorization'], 'proxy-only');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://192.0.2.2/hls/index'},
        );
      }
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('proxy-authorization'), isFalse);
      if (request.url.path == '/hls/index') {
        return http.Response(
          '#EXTM3U\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n',
          200,
        );
      }
      expect(request.url.path, '/hls/part.ts');
      expect(
        request.headers['range'],
        isNull,
        reason: 'segments stream directly without a block-sized preload',
      );
      return http.Response.bytes(
        [1, 2, 3],
        206,
        headers: {'content-range': 'bytes 0-2/3'},
      );
    });
    await cache.close();
    cache = VideoDiskCache(ipHttpsClient: native);
    await cache.boot(directory: root);
    final media = PlayerMedia(
      uri: Uri.parse('https://192.0.2.1/resolve'),
      headers: {
        'Authorization': 'test-only',
        'Proxy-Authorization': 'proxy-only',
        'User-Agent': 'media-agent',
      },
    );
    final local = await cache.wrap(media, inspect: true);
    expect(local.uri.path, endsWith('.m3u8'));
    final (_, body) = await get(local.uri);
    final segment = LineSplitter.split(utf8.decode(body))
        .firstWhere((line) => line.startsWith('http'));
    final (response, bytes) = await get(Uri.parse(segment));
    expect(response.statusCode, 200);
    expect(bytes, [1, 2, 3]);
    expect(requests.last.url.host, '192.0.2.2');
  });

  test('seek and suffix requests recover an undisclosed video length', () async {
    final media = await cache.wrap(PlayerMedia(uri: upstream.resolve('/unknown-total.mp4')));
    final first = await get(media.uri, 'bytes=0-31');
    expect(first.$1.statusCode, 206);
    expect(first.$2, data.take(32));
    final tail = await get(media.uri, 'bytes=-16');
    expect(tail.$2, data.sublist(data.length - 16));
    expect(tail.$1.headers.value('Content-Range'), 'bytes ${data.length - 16}-${data.length - 1}/${data.length}');
  });

  test('concurrent seeks receive their own bytes from a capped origin', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    final firstRead = Completer<void>();
    final release = Completer<void>();
    source.listen((request) async {
      final range = parseHttpByteRange(request.headers.value('range')!, data.length)!;
      if (!firstRead.isCompleted) firstRead.complete();
      await release.future;
      final end = (range.start + 63).clamp(range.start, range.end);
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes ${range.start}-$end/${data.length}');
      request.response.add(data.sublist(range.start, end + 1));
      await request.response.close();
    });
    final media = await cache.wrap(PlayerMedia(
      uri: Uri.parse('http://127.0.0.1:${source.port}/movie.mp4'),
    ));
    final starts = [0, 384, 704, 960];
    final requests = await Future.wait(starts.map((start) async {
      final request = await client.getUrl(media.uri);
      request.headers.set('Range', 'bytes=$start-${start + 31}');
      return request;
    }));
    final results = Future.wait(requests.map((request) async {
      final response = await request.close();
      return (response.statusCode, await response.expand((b) => b).toList());
    }));
    await firstRead.future;
    release.complete();
    final replies = await results;
    for (var i = 0; i < starts.length; i++) {
      expect(replies[i].$1, 206);
      expect(replies[i].$2, data.sublist(starts[i], starts[i] + 32));
    }
  });

  test('remote bounded seeks stream exact ranges without requiring a total or caching a false EOF', () async {
    final ranges = <String?>[];
    final native = MockClient((request) async {
      final range = request.headers['range'];
      ranges.add(range);
      if (range != 'bytes=0-15' && range != 'bytes=48-63') {
        return http.Response('', 400);
      }
      final offsets = parseHttpByteRange(range!, data.length)!;
      return http.Response.bytes(data.sublist(offsets.start, offsets.end + 1), 206,
          headers: {'content-range': 'bytes ${offsets.start}-${offsets.end}/*'});
    });
    await cache.close();
    cache = VideoDiskCache(ipHttpsClient: native);
    await cache.boot(directory: root);
    final wrapped = await cache.wrap(PlayerMedia(uri: Uri.parse('https://192.0.2.1/seek.mp4')));
    for (final start in [0, 48]) {
      final (response, bytes) = await get(wrapped.uri, 'bytes=$start-${start + 15}');
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes $start-${start + 15}/*');
      expect(bytes, data.sublist(start, start + 16));
    }
    expect(ranges, ['bytes=0-15', 'bytes=48-63']);
    expect(cache.bytes, 0);
  });

  test('remote seeks repair a mismatched 206 and preserve the 416 length', () async {
    final native = MockClient((request) async {
      final range = request.headers['range'];
      if (range == 'bytes=90-') {
        return http.Response('', 416, headers: {'content-range': 'bytes */64'});
      }
      final wrong = range == 'bytes=33-35';
      return http.Response.bytes(data.sublist(0, wrong ? 3 : 64), 206, headers: {
        'content-range': wrong ? 'bytes 0-2/64' : 'bytes 0-63/64',
        'content-type': 'video/mp4',
      });
    });
    await cache.close();
    cache = VideoDiskCache(ipHttpsClient: native);
    await cache.boot(directory: root);
    final wrapped = await cache.wrap(
      PlayerMedia(uri: Uri.parse('https://192.0.2.1/movie.mp4')),
    );
    final (past, _) = await get(wrapped.uri, 'bytes=90-');
    expect(past.statusCode, 416);
    expect(past.headers.value('content-range'), 'bytes */64');
    final (seek, bytes) = await get(wrapped.uri, 'bytes=33-35');
    expect(seek.statusCode, 206);
    expect(seek.headers.value('content-range'), 'bytes 33-35/64');
    expect(bytes, data.sublist(33, 36));
  });

  for (final status in [400, 401, 403, 404, 429, 500, 502, 503]) {
    test(
      'upstream HTTP $status is preserved without leaking its body',
      () async {
        final wrapped = await cache.wrap(
          PlayerMedia(uri: upstream.resolve('/status/$status')),
        );
        final (response, body) = await get(wrapped.uri);
        expect(response.statusCode, status);
        expect(body, isEmpty);
        expect(calls, [502, 503].contains(status) ? 2 : 1);
      },
    );
  }

  test(
    'settings filesystem errors are reported without breaking UI actions',
    () async {
      await Directory('${root.path}/video_buffer.json.tmp').create();
      await cache.configure(capacityMb: 777);
      expect(cache.capacityMb, 777);
      expect(cache.status, contains('保存或清理失败'));
    },
  );

  test('播放缓存代理过滤 HLS 广告且支持关闭，开关重启可恢复', () async {
    final media = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('ads.m3u8')),
    );
    var result = await get(media.uri);
    expect(utf8.decode(result.$2), isNot(contains('ad.ts')));
    expect(RegExp('#EXTINF:').allMatches(utf8.decode(result.$2)).length, 2);
    await cache.configure(skipHlsAds: false);
    result = await get(media.uri);
    expect(RegExp('#EXTINF:').allMatches(utf8.decode(result.$2)).length, 3);
    final reloaded = VideoDiskCache();
    await reloaded.boot(directory: root);
    expect(reloaded.skipHlsAds, false);
    await reloaded.close();
  });

  test(
    'concurrent settings writes persist the final complete snapshot',
    () async {
      await Future.wait([
        for (var i = 0; i < 20; i++)
          cache.configure(capacityMb: 700 + i, enabled: i.isEven),
      ]);
      final saved = jsonDecode(
        await File('${root.path}/video_buffer.json').readAsString(),
      );
      expect(saved, {'enabled': false, 'skipHlsAds': true, 'capacityMb': 719});
    },
  );

  test(
    'capped local ranges stream to EOF without a false end or quality change',
    () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final (response, body) = await get(wrapped.uri, 'bytes=0-');
      expect(response.statusCode, 206);
      expect(response.contentLength, data.length);
      expect(body, data);
      expect(calls, 3);
      expect(cache.bytes, data.length);
      final (seekResponse, seek) = await get(wrapped.uri, 'bytes=100-399');
      expect(
        seekResponse.headers.value('content-range'),
        'bytes 100-399/${data.length}',
      );
      expect(seek, data.sublist(100, 400));
      expect(calls, 3, reason: 'overlapping seeks reuse cached blocks');
      expect(cache.hits, greaterThan(0));
    },
  );

  test(
    'capacity eviction and clear preserve playback and enforce bytes',
    () async {
      cache.capacityMb = 1;
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      expect((await get(wrapped.uri)).$2, data);
      for (var i = 0; i < 100 && cache.bytes == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, lessThanOrEqualTo(1024 * 1024));
      expect(await cache.clear(), greaterThan(0));
      expect(cache.bytes, 0);
      expect(
        await Directory('${root.path}/video-buffer-v1').list().toList(),
        isEmpty,
      );
      expect((await get(wrapped.uri, 'bytes=0-15')).$2, data.sublist(0, 16));
    },
  );

  test(
    'low free space falls back to kernel buffering without failing playback',
    () async {
      cache.freeSpace = () async => 1024;
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      expect((await get(wrapped.uri)).$2, data);
      for (var i = 0; i < 100 && !cache.status.contains('空间不足'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, 0);
      expect(cache.status, contains('空间不足'));
    },
  );

  test(
    'HEAD, suffix ranges and unsatisfiable offsets obey HTTP semantics',
    () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final head = await (await client.headUrl(wrapped.uri)).close();
      expect(head.contentLength, data.length);
      expect(await head.expand((e) => e).toList(), isEmpty);
      expect(
        (await get(wrapped.uri, 'bytes=-100')).$2,
        data.sublist(data.length - 100),
      );
      final (invalid, _) = await get(wrapped.uri, 'bytes=3000000-');
      expect(invalid.statusCode, 416);
      expect(invalid.headers.value('content-range'), 'bytes */${data.length}');
      expect((await get(wrapped.uri, 'bytes=0-3,10-12')).$1.statusCode, 416);
    },
  );

  test('temporary 502 retries once without a quality downgrade', () async {
    failures = 1;
    final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
    expect((await get(wrapped.uri, 'bytes=0-15')).$2, data.sublist(0, 16));
    expect(calls, 2);
    failures = 3;
    expect(
      (await get(wrapped.uri, 'bytes=1048576-1048591')).$1.statusCode,
      502,
    );
    expect(failures, 1, reason: 'bounded retry, no endless loop');
  });

  test(
    'clear invalidates an in-flight cache write without dropping its reader',
    () async {
      pause = Completer<void>();
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final reading = get(wrapped.uri, 'bytes=0-15');
      while (calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await cache.clear();
      pause!.complete();
      expect((await reading).$2, data.sublist(0, 16));
      expect(cache.bytes, 0);
    },
  );

  for (final bounce in [false, true]) {
    test('cross-origin HLS redirects cannot restore credentials on child resources (bounce: $bounce)', () async {
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => source.close(force: true));
      addTearDown(() => cdn.close(force: true));
      final base = Uri.parse('http://127.0.0.1:${source.port}/');
      final cdnBase = Uri.parse('http://127.0.0.1:${cdn.port}/');
      final seen = <(String, String?, String?)>[];
      final master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=160000\n${base.resolve('variant.m3u8')}\n';
      Future<void> serve(HttpRequest request) async {
        seen.add((request.uri.path, request.headers.value('authorization'), request.headers.value('referer')));
        switch (request.uri.path) {
          case '/entry.m3u8':
            await request.response.redirect(cdnBase.resolve('redirect'));
            return;
          case '/redirect' when bounce:
            await request.response.redirect(base.resolve('master.m3u8'));
            return;
          case '/redirect':
          case '/master.m3u8':
            request.response.write(master);
          case '/variant.m3u8':
            request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n');
          case '/key.bin':
            request.response.add(List.filled(16, 5));
          case '/part.ts':
            request.response.add([1, 2, 3]);
        }
        await request.response.close();
      }
      source.listen(serve);
      cdn.listen(serve);
      final wrapped = await cache.wrap(PlayerMedia(uri: base.resolve('entry.m3u8'),
          headers: const {'Authorization':'Bearer fixture', 'Referer':'https://example.test/'}));
      Uri firstChild(String body) => Uri.parse(LineSplitter.split(body).firstWhere((l) => l.startsWith('http')));
      final masterBody = utf8.decode((await get(wrapped.uri)).$2);
      final variant = utf8.decode((await get(firstChild(masterBody))).$2);
      final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(variant)![1]!);
      expect((await get(key)).$2, List.filled(16, 5));
      expect((await get(firstChild(variant))).$2, [1, 2, 3]);
      expect(seen.first.$2, 'Bearer fixture');
      expect(seen.skip(1).map((r) => r.$2), everyElement(isNull));
      expect(seen.map((r) => r.$3), everyElement('https://example.test/'));
    });
  }

  test('a playlist continuation redirect also limits credentials on the assembled playlist', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => source.close(force: true));
    addTearDown(() => cdn.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${source.port}/');
    final bytes = utf8.encode('#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n');
    final seen = <(String, String?)>[];
    source.listen((r) async {
      seen.add((r.uri.path, r.headers.value('cookie')));
      if (r.uri.path == '/part.ts') {
        r.response.add([9, 8, 7]);
      } else if (r.headers.value('range') == null) {
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes 0-7/${bytes.length}');
        r.response.add(bytes.sublist(0, 8));
      } else {
        await r.response.redirect(Uri.parse('http://127.0.0.1:${cdn.port}/rest'));
        return;
      }
      await r.response.close();
    });
    cdn.listen((r) async {
      seen.add((r.uri.path, r.headers.value('cookie')));
      r.response.statusCode = 206;
      r.response.headers.set('Content-Range', 'bytes 8-${bytes.length - 1}/${bytes.length}');
      r.response.add(bytes.sublist(8));
      await r.response.close();
    });
    final wrapped = await cache.wrap(PlayerMedia(uri: base.resolve('index.m3u8'),
        headers: const {'Cookie':'test=fixture'}));
    final body = utf8.decode((await get(wrapped.uri)).$2);
    final part = Uri.parse(LineSplitter.split(body).firstWhere((l) => l.startsWith('http')));
    expect((await get(part)).$2, [9, 8, 7]);
    expect(seen, [('/index.m3u8','test=fixture'),('/index.m3u8','test=fixture'),('/rest',null),('/part.ts',null)]);
  });

  test('HLS redirect base is used for relative segments and keys', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('redirect')),
    );
    final body = utf8.decode((await get(wrapped.uri)).$2);
    final segment = Uri.parse(
      const LineSplitter()
          .convert(body)
          .firstWhere((line) => line.startsWith('http')),
    );
    await get(segment, 'bytes=0-15');
    expect(calls, 3);
    expect(paths.last, '/nested/part.ts');
  });

  test(
    'extra disk read-ahead waits for playback reserve and is serial',
    () async {
      final media = PlayerMedia(uri: upstream);
      final wrapped = await cache.wrap(media);
      await get(wrapped.uri, 'bytes=0-15');
      cache.prefetch(media, const Duration(seconds: 60), allowed: false);
      expect(calls, 1);
      cache.prefetch(media, const Duration(seconds: 60), allowed: true);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (cache.bytes < data.length && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, data.length);
      expect(calls, 3);
      cache.prefetch(media, const Duration(seconds: 60), allowed: true);
      cache.stopPrefetch();
      expect(calls, 3);
    },
  );

  test('gzip HLS is decoded before rewriting and never cached', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/gzip/master.m3u8')),
    );
    final response = await get(wrapped.uri);
    expect(utf8.decode(response.$2), startsWith('#EXTM3U'));
    expect(utf8.decode(response.$2), isNot(contains('URI="key"')));
    expect(response.$1.headers.value('content-encoding'), isNull);
    expect(cache.bytes, 0);
  });

  for (final encoding in ['gzip', 'deflate']) {
    test('extensionless $encoding HLS with binary MIME rewrites relative segment URLs', () async {
      final media = PlayerMedia(uri: upstream.resolve('/encoded-script?codec=$encoding'));
      final wrapped = await cache.wrap(media, inspect: true, appleHls: true);
      expect(wrapped.uri.path, endsWith('.apple.m3u8'));
      final (response, body) = await get(wrapped.uri);
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
      final segment = Uri.parse(utf8.decode(body).split('\n').firstWhere((l) => l.endsWith('.ts')));
      expect(segment.port, wrapped.uri.port);
      expect(segment.host, '127.0.0.1');
      expect(cache.bytes, 0);
    });
  }

  test('HLS 清单按普通 GET 获取，兼容拒绝 Range 的服务器', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/no-range/master.m3u8')),
    );
    final (response, body) = await get(wrapped.uri);
    expect(response.statusCode, 200);
    expect(utf8.decode(body), startsWith('#EXTM3U'));
  });

  for (final tag in ['KEY', 'SESSION-KEY']) {
    test('HLS $tag returns the current key on each request without persisting it', () async {
      final wrapped = await cache.wrap(PlayerMedia(
        uri: upstream.resolve('/rotate/master.m3u8?tag=$tag'),
        headers: const {'Authorization': 'Bearer fixture'},
      ));
      final manifest = utf8.decode((await get(wrapped.uri)).$2);
      final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(manifest)![1]!);
      expect((await get(key)).$2, List.filled(16, 1));
      final next = await get(key, 'bytes=2-5');
      expect(next.$1.statusCode, 206);
      expect(next.$2, List.filled(4, 2));
      expect(next.$1.headers.value('cache-control'), contains('no-store'));
      expect(cache.bytes, 0);
      expect((await Directory('${root.path}/video-buffer-v1').list().toList()), isEmpty);
    });
  }
  test('HLS rejects short and oversized AES keys and recovers with exact decoded bytes', () async {
    final wrapped = await cache.wrap(PlayerMedia(
      uri: upstream.resolve('/rotate/master.m3u8?key=invalid'),
      headers: const {'Authorization': 'Bearer fixture'},
    ));
    final manifest = utf8.decode((await get(wrapped.uri)).$2);
    final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(manifest)![1]!);
    for (var attempt = 0; attempt < 2; attempt++) {
      final (response, body) = await get(key);
      expect(response.statusCode, 502);
      expect(body, isEmpty);
    }
    expect((await get(key)).$2, ascii.encode('<html>0123456789'));
    expect(cache.bytes, 0);
  });

  test('HLS rewrites keys and segments and never caches a playlist', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('master.m3u8')),
    );
    final body = utf8.decode((await get(wrapped.uri)).$2);
    expect(body, startsWith('#EXTM3U'));
    expect(body, isNot(contains('URI="key"')));
    expect(body, isNot(contains('\npart.ts\n')));
    expect(cache.bytes, 0);
    await get(wrapped.uri);
    expect(calls, 2);
  });

  test('range probes see bytes and length of the rewritten HLS playlist', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/no-range/master.m3u8')),
    );
    final (_, full) = await get(wrapped.uri);
    final (probe, bytes) = await get(wrapped.uri, 'bytes=0-1');
    expect(probe.statusCode, 206);
    expect(bytes, full.take(2));
    expect(probe.headers.value('content-range'), 'bytes 0-1/${full.length}');
    expect(probe.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    final head = await client.headUrl(wrapped.uri);
    head.headers.set('Range', 'bytes=-5');
    final response = await head.close();
    expect(response.statusCode, 206);
    expect(response.contentLength, 5);
    expect(await response.expand((e) => e).toList(), isEmpty);
    expect((await get(wrapped.uri, 'bytes=${full.length}-')).$1.statusCode, 416);
  });

  test('large numeric offsets do not break cached video range probes', () async {
    final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
    const huge = '999999999999999999999999999999999999';
    final (past, _) = await get(wrapped.uri, 'bytes=$huge-');
    expect(past.statusCode, 416);
    expect(past.headers.value('content-range'), 'bytes */${data.length}');
    final (tail, bytes) = await get(wrapped.uri, 'Bytes=${data.length - 3}-$huge');
    expect(tail.statusCode, 206);
    expect(bytes, data.sublist(data.length - 3));
  });

  test(
    'memory mode still repairs local cat ranges; credentials stay private',
    () async {
      await cache.configure(enabled: false);
      final wrapped = await cache.wrap(
        PlayerMedia(uri: upstream, headers: {'Authorization': 'private'}),
      );
      expect(wrapped.uri.toString(), isNot(contains('private')));
      expect(wrapped.headers, isNull);
      expect((await get(wrapped.uri)).$2, data);
      expect(cache.bytes, 0);
      expect(
        (await get(wrapped.uri.replace(path: '/unknown'))).$1.statusCode,
        404,
      );
      final remote = PlayerMedia(
        uri: Uri.parse('https://example.test/movie.mp4'),
      );
      expect(await cache.wrap(remote), same(remote));
    },
  );
}

class _TransportPlayer extends AbstractPlayer {
  _TransportPlayer(this.throws, {this.delayed = false});
  final bool throws;
  final bool delayed;
  final loads = <PlayerMedia>[];
  final state = ValueNotifier(const PlayerSnapshot());
  final info = ValueNotifier(const PlayerStats());
  @override
  ValueNotifier<PlayerSnapshot> get snapshot => state;
  @override
  ValueNotifier<PlayerStats> get stats => info;
  @override
  Future<void> load(PlayerMedia media) async {
    loads.add(media);
    if (loads.length == 1) {
      if (throws) throw StateError('local connection failed');
      if (delayed) {
        state.value = const PlayerSnapshot(buffering: true);
        Future<void>.delayed(const Duration(milliseconds: 20), () {
          state.value = const PlayerSnapshot(error: 'HTTP 502');
        });
        return;
      }
      state.value = const PlayerSnapshot(error: 'local connection failed');
    } else {
      state.value = const PlayerSnapshot();
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> applySettings(PlayerSettings settings) async {}
  @override
  Widget buildView() => const SizedBox();
  @override
  Future<void> dispose() async {}
}
