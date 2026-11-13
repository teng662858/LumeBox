import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/audio_book/audio_book_proxy.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';

void main() {
  AudioBookTrack queueTrack(String path) => AudioBookTrack(
    id: 'shared-chapter',
    album: 'Book',
    episode: ResourceEpisode(
      id: 'e',
      title: 'E',
      url: Uri.parse('https://fixture.test/$path'),
    ),
  );

  test(
    'replacing a queue invalidates old URLs even when chapter IDs match',
    () async {
      final proxy = AudioBookProxy(
        clientFactory: () =>
            MockClient((r) async => http.Response(r.url.path, 200)),
      );
      final client = http.Client();
      try {
        final old = (await proxy.prepare([queueTrack('first')])).single;
        final current = (await proxy.prepare([queueTrack('second')])).single;
        expect((await client.get(old)).statusCode, 404);
        expect((await client.get(current)).body, '/second');
        expect(current.port, old.port);
      } finally {
        client.close();
        await proxy.close();
      }
    },
  );

  test('overlapping first prepares only publish the newest queue', () async {
    final proxy = AudioBookProxy(
      clientFactory: () =>
          MockClient((r) async => http.Response(r.url.path, 200)),
    );
    final client = http.Client();
    try {
      final old = proxy.prepare([queueTrack('first')]);
      final newest = proxy.prepare([queueTrack('second')]);
      await expectLater(old, throwsStateError);
      final local = (await newest).single;
      expect((await client.get(local)).body, '/second');
    } finally {
      client.close();
      await proxy.close();
    }
  });

  test(
    'closing during initial bind cancels preparation and permits a fresh queue',
    () async {
      final proxy = AudioBookProxy(
        clientFactory: () =>
            MockClient((r) async => http.Response(r.url.path, 200)),
      );
      final client = http.Client();
      try {
        final pending = proxy.prepare([queueTrack('old')]);
        final closing = proxy.close();
        await expectLater(pending, throwsStateError);
        await closing;
        final current = (await proxy.prepare([queueTrack('new')])).single;
        expect((await client.get(current)).body, '/new');
      } finally {
        client.close();
        await proxy.close();
      }
    },
  );
  for (final entry in ['book.m3u8', 'signed']) {
    test(
      'audio HLS HEAD and ranges use the rewritten playlist for $entry',
      () async {
        const body = '#EXTM3U\n#EXTINF:3,\nbook.aac\n#EXT-X-ENDLIST\n';
        final proxy = AudioBookProxy(
          clientFactory: () => MockClient((request) async {
            final range = request.headers['range'];
            final headers = {'content-type': 'application/vnd.apple.mpegurl'};
            if (range != null) {
              return http.Response(
                'xx',
                206,
                headers: {
                  ...headers,
                  'content-range': 'bytes 8-9/${body.length}',
                },
              );
            }
            return http.Response(
              request.method == 'HEAD' ? '' : body,
              200,
              headers: headers,
            );
          }),
        );
        final client = http.Client();
        try {
          final local = (await proxy.prepare([
            AudioBookTrack(
              id: 'book',
              album: 'Book',
              episode: ResourceEpisode(
                id: 'e',
                title: 'E',
                url: Uri.parse('https://audio.test/$entry'),
              ),
            ),
          ])).single;
          if (entry.endsWith('.m3u8')) expect(local.path, endsWith('.m3u8'));
          final full = await client.get(local);
          expect(full.body, contains('127.0.0.1'));
          final segment = LineSplitter.split(full.body)
              .firstWhere((line) => line.startsWith('http'));
          expect(Uri.parse(segment).path, endsWith('.aac'));
          final length = full.bodyBytes.length;
          final partial = await client.get(
            local,
            headers: {'Range': 'bytes=8-9'},
          );
          expect(partial.statusCode, 206);
          expect(partial.headers['content-range'], 'bytes 8-9/$length');
          expect(partial.bodyBytes, full.bodyBytes.sublist(8, 10));
          final head = await client.head(local);
          expect(head.headers['content-length'], '$length');
          expect(head.bodyBytes, isEmpty);
          final suffix = await client.head(
            local,
            headers: {'Range': 'bytes=-4'},
          );
          expect(suffix.statusCode, 206);
          expect(
            suffix.headers['content-range'],
            'bytes ${length - 4}-${length - 1}/$length',
          );
          final invalid = await client.get(
            local,
            headers: {'Range': 'bytes=$length-'},
          );
          expect(invalid.statusCode, 416);
          expect(invalid.headers['content-range'], 'bytes */$length');
          expect(proxy.lastError, isNull);
        } finally {
          client.close();
          await proxy.close();
        }
      },
    );
  }
  test(
    'remote unsatisfiable audio range preserves the representation size',
    () async {
      final proxy = AudioBookProxy(
        clientFactory: () => MockClient(
          (_) async =>
              http.Response('', 416, headers: {'content-range': 'bytes */8'}),
        ),
      );
      final client = http.Client();
      try {
        final local = (await proxy.prepare([
          AudioBookTrack(
            id: 'a',
            album: 'A',
            episode: ResourceEpisode(
              id: 'a',
              title: 'A',
              url: Uri.parse('https://audio.test/audio.mp3'),
            ),
          ),
        ])).single;
        final result = await client.get(
          local,
          headers: {'Range': 'bytes=100-'},
        );
        expect(result.statusCode, 416);
        expect(result.headers['content-range'], 'bytes */8');
        expect(proxy.lastError, isNull);
      } finally {
        client.close();
        await proxy.close();
      }
    },
  );
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
  for (final encoding in ['gzip', 'deflate']) {
    test(
      'compressed $encoding audio and HLS return playable bytes and valid lengths',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final audio = List.generate(4096, (i) => i % 251);
        const manifest = '#EXTM3U\n#EXTINF:1,\nchapter.aac\n#EXT-X-ENDLIST\n';
        server.listen((request) async {
          final data = request.uri.path.endsWith('.m3u8')
              ? utf8.encode(manifest)
              : audio;
          final compressed = (encoding == 'gzip' ? gzip : zlib).encode(data);
          final r = request.response;
          r.headers.set('Content-Encoding', encoding);
          if (request.headers.value('range') != null) {
            r.statusCode = 206;
            r.headers.set('Content-Range', 'bytes 2-11/${compressed.length}');
            r.contentLength = 10;
            r.add(compressed.sublist(2, 12));
          } else {
            r.contentLength = compressed.length;
            if (request.method != 'HEAD') r.add(compressed);
          }
          await r.close();
        });
        final proxy = AudioBookProxy();
        final client = http.Client();
        try {
          final track = AudioBookTrack(
            id: 'encoded',
            album: 'Book',
            episode: ResourceEpisode(
              id: 'e',
              title: 'E',
              url: Uri.parse('http://127.0.0.1:${server.port}/book.m3u8'),
            ),
          );
          final url = (await proxy.prepare([track])).single;
          final playlist = await client.get(url);
          expect(playlist.statusCode, 200);
          final asset = Uri.parse(
            LineSplitter.split(playlist.body)
                .firstWhere((s) => s.startsWith('http')),
          );
          final head = await client.head(asset);
          expect(head.headers['content-length'], isNull);
          final result = await client.get(asset);
          expect(result.bodyBytes, audio);
          final seek = await client.get(
            asset,
            headers: {'Range': 'bytes=2-11'},
          );
          if (seek.statusCode == 206) {
            expect(seek.headers['content-range'], 'bytes 2-11/${audio.length}');
            expect(seek.bodyBytes, audio.sublist(2, 12));
          } else {
            expect(seek.statusCode, 200);
            expect(seek.headers['content-range'], isNull);
            expect(seek.bodyBytes, audio);
          }
        } finally {
          client.close();
          await proxy.close();
          await server.close(force: true);
        }
      },
    );
  }
  for (final denied in [403, 405, 501]) {
    test('仅允许 GET 的音频地址仍能响应播放器 HEAD 探测（HTTP $denied）', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      origin.listen((request) async {
        requests.add(request.method);
        if (request.method == 'HEAD') {
          request.response.statusCode = denied;
        } else {
          request.response.headers.contentType = ContentType('audio', 'mpeg');
          request.response.contentLength = 5;
          request.response.add([1, 2, 3, 4, 5]);
        }
        await request.response.close();
      });
      final proxy = AudioBookProxy();
      final client = http.Client();
      try {
        final media = (await proxy.prepare([
          AudioBookTrack(id: 'chapter', album: '测试书', episode: ResourceEpisode(
            id: 'chapter', title: '章节', url: Uri.parse('http://127.0.0.1:${origin.port}/signed'),
          )),
        ])).single;
        final head = await client.head(media);
        expect(head.statusCode, 200);
        expect(head.headers['content-length'], '5');
        expect(head.headers['content-type'], contains('audio/mpeg'));
        expect(head.bodyBytes, isEmpty);
        expect(requests, ['HEAD', 'GET']);
        final range = await client.head(media, headers: {'Range': 'bytes=1-3'});
        expect(range.statusCode, 206);
        expect(range.headers['content-range'], 'bytes 1-3/5');
        expect(range.headers['content-length'], '3');
        expect(range.bodyBytes, isEmpty);
        expect((await client.get(media)).bodyBytes, [1, 2, 3, 4, 5]);
        expect(proxy.lastError, isNull);
      } finally {
        client.close();
        await proxy.close();
        await origin.close(force: true);
      }
    });
  }

  for (final rangeStatus in [200, 403, 416]) {
    test('remote audio seek serves exact bytes when Range gets HTTP $rangeStatus', () async {
      final bytes = List<int>.generate(256, (i) => i);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = AudioBookProxy();
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await proxy.close();
        await origin.close(force: true);
      });
      origin.listen((request) async {
        if (request.headers.value('range') != null && rangeStatus != 200) {
          request.response.statusCode = rangeStatus;
        } else {
          request.response.headers.contentType = ContentType('audio', 'mpeg');
          request.response.contentLength = bytes.length;
          if (request.method == 'GET') {
            request.response.add(bytes.sublist(0, 100));
            await request.response.flush();
            request.response.add(bytes.sublist(100));
          }
        }
        await request.response.close();
      });
      final uri = (await proxy.prepare([AudioBookTrack(
        id: 'remote', album: 'Book', episode: ResourceEpisode(id: 'e', title: 'E',
          url: Uri.parse('http://127.0.0.1:${origin.port}/chapter.mp3')),
      )])).single;
      final part = await client.get(uri, headers: {'Range': 'bytes=90-109'});
      expect(part.statusCode, 206);
      expect(part.headers['content-range'], 'bytes 90-109/256');
      expect(part.bodyBytes, bytes.sublist(90, 110));
      final tail = await client.get(uri, headers: {'Range': 'bytes=-8'});
      expect(tail.bodyBytes, bytes.sublist(248));
      final head = await client.head(uri, headers: {'Range': 'bytes=100-'});
      expect(head.statusCode, 206);
      expect(head.headers['content-length'], '156');
      expect(head.bodyBytes, isEmpty);
      final invalid = await client.get(uri, headers: {'Range': 'bytes=256-'});
      expect(invalid.statusCode, 416);
      expect(invalid.headers['content-range'], 'bytes */256');
    });
  }

  test('a cached chapter URL that expires during playback is refreshed on the same seek', () async {
    var resolutions = 0;
    var expired = false;
    final proxy = AudioBookProxy(clientFactory: () => MockClient((request) async {
      if (request.headers['authorization'] != request.url.queryParameters['token']) {
        return http.Response('', 401);
      }
      if (expired && request.url.queryParameters['token'] == '1') {
        return http.Response('', 410);
      }
      return http.Response.bytes([11, 22, 33, 44], 200);
    }));
    final client = http.Client();
    addTearDown(() async { client.close(); await proxy.close(); });
    final url = (await proxy.prepare([AudioBookTrack(
      id: 'signed', album: 'Book', episode: const ResourceEpisode(id: 'e', title: 'E'),
      resolve: () async {
        final token = (++resolutions).toString();
        return ResolvedAudio(Uri.parse('https://audio.test/track.mp3?token=$token'),
            headers: {'Authorization': token});
      },
    )])).single;
    expect((await client.get(url)).bodyBytes, [11, 22, 33, 44]);
    expired = true;
    final seek = await client.get(url, headers: {'Range': 'bytes=2-'});
    expect(seek.statusCode, 206);
    expect(seek.bodyBytes, [33, 44]);
    expect((await client.get(url)).bodyBytes, [11, 22, 33, 44]);
    expect(resolutions, 2);
    expect(proxy.lastError, isNull);
  });

  test('concurrent expired seeks share one refresh and a denied replacement fails once', () async {
    var resolutions = 0, oldRequests = 0, deniedRequests = 0;
    final bothExpired = Completer<void>();
    final proxy = AudioBookProxy(clientFactory: () => MockClient((r) async {
      if (r.url.path == '/1') {
        if (++oldRequests == 2) bothExpired.complete();
        await bothExpired.future;
        return http.Response('', 410);
      }
      deniedRequests++;
      return http.Response('', 401);
    }));
    final client = http.Client();
    addTearDown(() async { client.close(); await proxy.close(); });
    final url = (await proxy.prepare([AudioBookTrack(
      id: 'e', album: 'Book', episode: const ResourceEpisode(id: 'e', title: 'E'),
      resolve: () async => ResolvedAudio(Uri.parse('https://audio.test/${++resolutions}')),
    )])).single;
    final responses = await Future.wait([
      client.get(url, headers: {'Range': 'bytes=2-'}),
      client.get(url, headers: {'Range': 'bytes=4-'}),
    ]);
    expect(responses.map((r) => r.statusCode), [502, 502]);
    expect([resolutions, oldRequests, deniedRequests], [2, 2, 2]);
    expect(proxy.lastError, contains('401'));
  });

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
  test('only audio HLS asset URLs issued for the current chapter reach upstream', () async {
    final requests = <http.Request>[];
    final proxy = AudioBookProxy(clientFactory: () => MockClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('.m3u8')) return http.Response('#EXTM3U\n#EXTINF:1,\nchunk.aac\n', 200);
      return http.Response.bytes([10, 20], 200);
    }));
    final client = http.Client();
    addTearDown(() async { client.close(); await proxy.close(); });
    final tracks = await proxy.prepare([
      for (final name in ['one', 'two'])
        AudioBookTrack(id: name, album: 'book', episode: ResourceEpisode(id: name, title: name,
          url: Uri.parse('https://book.test/$name.m3u8'), headers: {'Authorization': name})),
    ]);
    final manifest = await client.get(tracks.first);
    final asset = Uri.parse(LineSplitter.split(manifest.body).firstWhere((line) => line.startsWith('http')));
    final other = base64Url.encode(utf8.encode('https://book.test/account'));
    for (final changed in [
      asset.replace(queryParameters: {...asset.queryParameters, 'asset': other}),
      asset.replace(path: '${tracks.first.path}/public.aac'),
      tracks.first.replace(queryParameters: {'asset': other}),
      asset.replace(path: '${tracks.last.path}/${asset.pathSegments.last}'),
    ]) {
      expect((await client.get(changed)).statusCode, 404);
    }
    expect(requests, hasLength(1));
    expect((await client.get(asset)).bodyBytes, [10, 20]);
    expect(requests.last.headers['authorization'], 'one');
  });

  test('audio HLS redirected playlists cannot restore stripped credentials in a nested playlist', () async {
    final seen = <http.Request>[];
    final proxy = AudioBookProxy(clientFactory: () => MockClient((r) async {
      seen.add(r);
      return switch (r.url.path) {
        '/start.m3u8' => http.Response('', 302, headers: {'location':'https://cdn.test/master'}),
        '/master' => http.Response('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=96000\nhttps://book.test/list\n', 200),
        '/list' => http.Response('#EXTM3U\n#EXTINF:1,\npart.aac\n#EXT-X-ENDLIST\n', 200),
        _ => http.Response.bytes([2, 4], 200),
      };
    }));
    final client = http.Client();
    addTearDown(() async { client.close(); await proxy.close(); });
    var uri = (await proxy.prepare([AudioBookTrack(id:'a', album:'book', episode:ResourceEpisode(
      id:'e', title:'e', url:Uri.parse('https://book.test/start.m3u8'),
      headers: const {'Authorization':'fixture', 'Referer':'https://book.test/'}))])).single;
    for (var i = 0; i < 2; i++) {
      final playlist = await client.get(uri);
      uri = Uri.parse(LineSplitter.split(playlist.body).firstWhere((line) => line.startsWith('http')));
    }
    expect((await client.get(uri)).bodyBytes, [2, 4]);
    expect(seen.map((r) => r.headers['authorization']), ['fixture', null, null, null]);
    expect(seen.map((r) => r.headers['referer']), everyElement('https://book.test/'));
  });

  test('audio HLS keeps playlist handling after redirect to an extensionless binary endpoint', () async {
    final requests = <http.Request>[];
    final proxy = AudioBookProxy(clientFactory: () => MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/book.m3u8') {
        return http.Response('', 302, headers: {'location': 'https://cdn.test/chapter/manifest?sig=A'});
      }
      if (request.url.path == '/chapter/manifest') {
        if (request.method != 'GET' || request.headers.containsKey('range')) return http.Response('', 403);
        return http.Response('#EXTM3U\n#EXTINF:2,\npart.aac\n#EXT-X-ENDLIST\n', 200,
            headers: {'content-type': 'application/octet-stream'});
      }
      return http.Response.bytes([2, 4, 6], 200);
    }));
    final client = http.Client();
    addTearDown(() async { client.close(); await proxy.close(); });
    final root = (await proxy.prepare([queueTrack('book.m3u8')])).single;
    final manifest = await client.get(root);
    expect(manifest.headers['content-type'], contains('mpegurl'));
    final child = Uri.parse(LineSplitter.split(manifest.body).firstWhere((line) => line.startsWith('http')));
    expect((await client.get(child)).bodyBytes, [2, 4, 6]);
    expect(requests.last.url.toString(), 'https://cdn.test/chapter/part.aac');
    final probe = await client.head(root, headers: {'Range': 'bytes=0-6'});
    expect(probe.statusCode, 206);
    expect(probe.headers['content-range'], 'bytes 0-6/${manifest.bodyBytes.length}');
    expect(requests.last.url.query, 'sig=A');
  });

  test('signed audio HLS variants and alternate renditions rewrite their own children', () async {
    final originPaths = <String>[];
    final proxy = AudioBookProxy(
      clientFactory: () => MockClient((request) async {
        originPaths.add(request.url.path);
        if (request.url.path == '/master.m3u8') {
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="A",URI="audio?id=1"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=64000,AUDIO="a"\nvariant?id=2\n',
            200,
          );
        }
        if (request.url.path == '/audio' || request.url.path == '/variant') {
          expect(request.headers['range'], isNull);
          return http.Response(
            '#EXTM3U\n#EXTINF:1,\npart.aac\n#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/octet-stream'},
          );
        }
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    final client = http.Client();
    try {
      final url = (await proxy.prepare([queueTrack('master.m3u8')])).single;
      final master = (await client.get(url)).body;
      for (final child in [
        RegExp(r'URI="([^"]+)"').firstMatch(master)![1]!,
        LineSplitter.split(master)
            .firstWhere((line) => line.startsWith('http')),
      ]) {
        final uri = Uri.parse(child);
        final nested = await client.get(uri);
        expect(nested.headers['content-type'], contains('mpegurl'));
        final segment = LineSplitter.split(nested.body)
            .firstWhere((line) => line.startsWith('http'));
        expect((await client.get(Uri.parse(segment))).bodyBytes, [1, 2, 3]);
        final probe = await client.get(uri, headers: {'Range': 'bytes=0-6'});
        expect(probe.statusCode, 206);
        expect(probe.body, '#EXTM3U');
      }
      expect(
        originPaths,
        containsAll(['/master.m3u8', '/audio', '/variant', '/part.aac']),
      );
    } finally {
      client.close();
      await proxy.close();
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
