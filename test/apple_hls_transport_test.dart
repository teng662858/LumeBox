import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoDiskCache cache;
  late Directory dir;
  late HttpServer origin;
  late HttpClient client;
  late Uri base;
  final calls = <MethodCall>[];
  const channel = MethodChannel('lumebox/video_remux');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // A 188-byte TS packet with a PMT declaring HEVC and no descriptors.
  final packet = Uint8List(188)
    ..setAll(0, [
      0x47,
      0x50,
      0,
      0x10,
      0,
      2,
      0xb0,
      18,
      0,
      1,
      0xc1,
      0,
      0,
      0xe1,
      0,
      0xf0,
      0,
      0x24,
      0xe1,
      0,
      0xf0,
      0,
    ]);
  final init = [0, 0, 0, 8, ...ascii.encode('moov')];
  final body = [0, 0, 0, 8, ...ascii.encode('moof')];
  late List<int> expectedInput;

  setUp(() async {
    HttpOverrides.global = null;
    client = HttpClient();
    dir = await Directory.systemTemp.createTemp();
    cache = VideoDiskCache();
    await cache.boot(directory: dir);
    await cache.configure(enabled: false);
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${origin.port}/');
    origin.listen((request) async {
      final r = request.response;
      if (request.headers.value('user-agent') != 'source-agent') {
        r.statusCode = 403;
      } else {
        r.headers.set('Content-Type', 'image/png');
        if (request.uri.path.endsWith('.php') &&
            request.headers.value('range') != null) {
          r.statusCode = 416;
          await r.close();
          return;
        }
        switch (request.uri.path) {
          case '/p.jpg':
            r.add(packet);
          case '/gzip.ts':
            r.headers.set('Content-Encoding', 'gzip');
            r.add(gzip.encode(packet));
          case '/deflate.ts':
            r.headers.set('Content-Encoding', 'deflate');
            r.add(zlib.encode(packet));
          case '/get-only.ts':
            if (request.headers.value('range') != null) {
              r.statusCode = 416;
            } else {
              r.add(packet);
            }
          case '/gzip.m3u8':
          case '/deflate.m3u8':
          case '/get-only.m3u8':
            final segment = request.uri.path.replaceFirst('.m3u8', '.ts');
            r.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n'
                '#EXTINF:4,\n$segment\n#EXT-X-ENDLIST\n');
          case '/avc.jpg':
            r.add(Uint8List.fromList(packet)..[17] = 0x1b);
          case '/png.jpg':
            r.add(
              Uint8List(4096)..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]),
            );
            for (var i = 0; i < 4; i++) {
              r.add(packet);
            }
          case '/master':
            r.write(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nplain.php\n',
            );
          default:
            final encrypted = request.uri.path == '/encrypted';
            final avc = request.uri.path == '/avc';
            final png = request.uri.path == '/png';
            r.write(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n'
              '${encrypted ? '#EXT-X-KEY:METHOD=AES-128,URI="secret"\n' : ''}'
              '#EXTINF:4,\n${png
                  ? 'png'
                  : avc
                  ? 'avc'
                  : 'p'}.jpg\n#EXT-X-ENDLIST\n',
            );
        }
      }
      await r.close();
    });
    calls.clear();
    expectedInput = packet;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      expect(call.method, 'fragment');
      expect(call.arguments['sequence'], 1);
      expect(call.arguments['input'], expectedInput);
      return Uint8List.fromList([...init, ...body]);
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    client.close(force: true);
    await cache.close();
    await origin.close(force: true);
    await dir.delete(recursive: true);
  });
  Future<(HttpClientResponse, List<int>)> read(Uri uri, [String? range]) async {
    final req = await client.getUrl(uri);
    if (range != null) req.headers.set('Range', range);
    final res = await req.close();
    return (res, await res.expand((e) => e).toList());
  }

  Future<String> manifest(String name, {bool apple = true}) async {
    final media = await cache.wrap(
      PlayerMedia(
        uri: base.resolve(name),
        headers: {'User-Agent': 'source-agent'},
      ),
      inspect: true,
      appleHls: apple,
    );
    expect(media.uri.path, endsWith('.m3u8'));
    return utf8.decode((await read(media.uri)).$2);
  }

  for (final name in [
    'plain.php',
    'no-extension',
    'normal.m3u8',
    'master',
    'gzip.m3u8',
    'deflate.m3u8',
    'get-only.m3u8',
  ]) {
    test(
      'Apple HEVC TS playback through $name keeps headers and converts once',
      () async {
        var text = await manifest(name);
        if (name == 'master') {
          text = utf8.decode(
            (await read(
              Uri.parse(
                text.split('\n').firstWhere((s) => s.startsWith('http')),
              ),
            )).$2,
          );
        }
        expect(text, contains('#EXT-X-VERSION:7'));
        final map = Uri.parse(
          RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(text)![1]!,
        );
        final fragment = Uri.parse(
          text.split('\n').firstWhere((s) => s.startsWith('http')),
        );
        final results = await Future.wait([
          read(map),
          read(fragment, 'bytes=4-7'),
        ]);
        expect(results.first.$2, init);
        expect(results.last.$1.statusCode, 206);
        expect(results.last.$2, ascii.encode('moof'));
        expect(calls, hasLength(1));
      },
    );
  }
  test('PNG 包装的 HEVC 分片先剥图片头再检测和重封装', () async {
    expectedInput = [for (var i = 0; i < 4; i++) ...packet];
    final text = await manifest('png');
    expect(text, contains('#EXT-X-MAP'));
    final fragment = Uri.parse(
      text.split('\n').firstWhere((s) => s.startsWith('http')),
    );
    expect((await read(fragment)).$2, body);
    expect(calls, hasLength(1));
  });

  test(
    'MDK and MPV receive recognizable TS addresses and MPEG-TS MIME',
    () async {
      final text = await manifest('plain.php', apple: false);
      final uri = Uri.parse(
        text.split('\n').firstWhere((s) => s.startsWith('http')),
      );
      expect(uri.path, endsWith('.ts'));
      final segment = await read(uri);
      expect(segment.$1.headers.contentType?.mimeType, 'video/mp2t');
      expect(segment.$2, packet);
      expect(calls, isEmpty);
    },
  );
  test('AVC and encrypted TS retain their native HLS layout', () async {
    expect(await manifest('avc'), isNot(contains('#EXT-X-MAP')));
    final encrypted = await manifest('encrypted');
    expect(encrypted, contains('.key"'));
    expect(encrypted, isNot(contains('#EXT-X-MAP')));
    expect(calls, isEmpty);
  });
}
