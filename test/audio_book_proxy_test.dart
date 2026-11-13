import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/audio_book/audio_book_proxy.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';

void main() {
  test(
    'audio redirects and playlist children scope headers by scheme and port',
    () async {
      final requests = <http.Request>[];
      final proxy = AudioBookProxy(
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/start') {
            return http.Response(
              '',
              302,
              headers: {'location': 'http://origin.test/list.m3u8'},
            );
          }
          if (request.url.path == '/list.m3u8') {
            return http.Response(
              '#EXTM3U\n#EXTINF:1,\nhttps://origin.test:9443/song.aac\n#EXT-X-ENDLIST\n',
              200,
            );
          }
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      final client = http.Client();
      try {
        final urls = await proxy.prepare([
          AudioBookTrack(
            id: 'a',
            album: 'Book',
            episode: ResourceEpisode(
              id: 'a',
              title: 'A',
              url: Uri.parse('https://origin.test/start'),
              headers: const {
                'Cookie': 'session',
                'Authorization': 'user',
                'Proxy-Authorization': 'proxy',
                'Host': 'origin.test',
                'Referer': 'https://origin.test/',
              },
            ),
          ),
        ]);
        final manifest = await client.get(urls.single);
        final asset = manifest.body
            .split('\n')
            .firstWhere((line) => line.startsWith('http'));
        expect((await client.get(Uri.parse(asset))).bodyBytes, [1, 2, 3]);
        expect(requests, hasLength(3));
        for (final name in [
          'cookie',
          'authorization',
          'proxy-authorization',
          'host',
        ]) {
          expect(requests.first.headers[name], isNotNull);
          for (final request in requests.skip(1)) {
            expect(
              request.headers[name],
              isNull,
              reason: '$name sent to ${request.url}',
            );
          }
        }
        expect(
          requests.map((r) => r.headers['referer']),
          everyElement('https://origin.test/'),
        );
      } finally {
        client.close();
        await proxy.close();
      }
    },
  );
  test('audio server refusal is recorded and reset for a new queue', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });
    final proxy = AudioBookProxy();
    final client = http.Client();
    try {
      final urls = await proxy.prepare([
        AudioBookTrack(
          id: 'blocked',
          album: '书',
          episode: ResourceEpisode(
            id: 'blocked',
            title: '第一集',
            url: Uri.parse('http://127.0.0.1:${server.port}/audio.mp3'),
          ),
        ),
      ]);
      expect((await client.get(urls.single)).statusCode, 502);
      expect(proxy.lastError, contains('HTTP 403'));
      await proxy.prepare([]);
      expect(proxy.lastError, isNull);
    } finally {
      client.close();
      await proxy.close();
      await server.close(force: true);
    }
  });
  test(
    'audio relay preserves exact original bytes, file ranges and suffix seeks',
    () async {
      final root = await Directory.systemTemp.createTemp('lume-audio-range-');
      final file = File('${root.path}/book.mp3');
      final bytes = List.generate(1024, (i) => i % 256);
      await file.writeAsBytes(bytes);
      final proxy = AudioBookProxy();
      final client = http.Client();
      var resolves = 0;
      try {
        final urls = await proxy.prepare([
          AudioBookTrack(
            id: 'one',
            album: '书',
            episode: const ResourceEpisode(id: 'c', title: '第一集'),
            resolve: () async {
              resolves++;
              return ResolvedAudio(file.uri);
            },
          ),
        ]);
        final chunk = await client.get(
          urls.single,
          headers: {'Range': 'bytes=100-199'},
        );
        expect(chunk.statusCode, 206);
        expect(chunk.bodyBytes, bytes.sublist(100, 200));
        expect(chunk.headers['content-range'], 'bytes 100-199/1024');
        expect(
          (await client.get(
            urls.single,
            headers: {'Range': 'bytes=-10'},
          )).bodyBytes,
          bytes.sublist(1014),
        );
        final head = await client.head(urls.single);
        expect(head.headers['content-length'], '1024');
        expect(head.bodyBytes, isEmpty);
        expect(resolves, 1);
        expect(
          (await client.get(urls.single.replace(path: '/wrong'))).statusCode,
          404,
        );
      } finally {
        client.close();
        await proxy.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('audio HLS playlists rewrite segment and encryption-key URLs while preserving bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((request) async {
      seen.add(request.uri.path);
      expect(request.headers.value('Referer'), 'https://site.example');
      if (request.uri.path.endsWith('main.m3u8')) {
        request.response.headers.set(
          'Content-Type',
          'application/vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
        );
      } else if (request.uri.path.endsWith('key.bin')) {
        request.response.add(List.filled(16, 7));
      } else {
        request.response.add([10, 20, 30, 40]);
      }
      await request.response.close();
    });
    final proxy = AudioBookProxy();
    final client = http.Client();
    try {
      final urls = await proxy.prepare([
        AudioBookTrack(
          id: 'hls',
          album: '书',
          episode: const ResourceEpisode(id: 'c', title: '第一集'),
          resolve: () async => ResolvedAudio(
            Uri.parse('http://127.0.0.1:${server.port}/book/main.m3u8'),
            headers: {'Referer': 'https://site.example'},
          ),
        ),
      ]);
      final playlist = await client.get(urls.single);
      expect(playlist.statusCode, 200);
      expect(playlist.body, startsWith('#EXTM3U'));
      final segment = playlist.body
          .split('\n')
          .firstWhere((s) => s.startsWith('http'));
      expect(Uri.parse(segment).host, '127.0.0.1');
      expect((await client.get(Uri.parse(segment))).bodyBytes, [
        10,
        20,
        30,
        40,
      ]);
      final key = RegExp(r'URI="([^"]+)"').firstMatch(playlist.body)!.group(1)!;
      expect((await client.get(Uri.parse(key))).bodyBytes, List.filled(16, 7));
      expect(seen, ['/book/main.m3u8', '/book/segment.ts', '/book/key.bin']);
    } finally {
      client.close();
      await proxy.close();
      await server.close(force: true);
    }
  });
  test(
    'a late chapter resolution cannot overwrite a replaced playlist',
    () async {
      final pending = Completer<ResolvedAudio>();
      final proxy = AudioBookProxy();
      final client = http.Client();
      try {
        final old = await proxy.prepare([
          AudioBookTrack(
            id: 'old',
            album: '旧书',
            episode: const ResourceEpisode(id: 'old', title: '旧集'),
            resolve: () => pending.future,
          ),
        ]);
        final request = client.get(old.single);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await proxy.prepare([]);
        pending.complete(
          ResolvedAudio(Uri.parse('https://example.invalid/stale.mp3')),
        );
        expect((await request).statusCode, 502);
      } finally {
        client.close();
        await proxy.close();
      }
    },
  );
}
