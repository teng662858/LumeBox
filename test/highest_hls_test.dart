import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/highest_hls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('跟随跳转后重写相对地址，单画质清单可读取且退出时释放', () async {
    HttpOverrides.global = null;
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://127.0.0.1:${remote.port}');
    remote.listen((request) async {
      if (request.uri.path == '/start.m3u8') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/folder/master.m3u8');
      } else {
        request.response.write(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10,RESOLUTION=640x360\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=20,RESOLUTION=1920x1080\nhigh.m3u8',
        );
      }
      await request.response.close();
    });
    final resolver = HighestHls();
    addTearDown(() async {
      await resolver.close();
      await remote.close(force: true);
    });
    final selected = await resolver.resolve(base.resolve('/start.m3u8'), {
      'Referer': 'https://site.example/',
    });
    expect(selected.port, isNot(remote.port));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(selected)).close();
    final text = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200);
    expect(text, contains(base.resolve('/folder/high.m3u8').toString()));
    expect(text, isNot(contains('low.m3u8')));
    await resolver.close();
    await expectLater(
      client.getUrl(selected).then((request) => request.close()),
      throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
    );
  });
  test('slow optional quality inspection yields to native playback within its budget', () async {
    HttpOverrides.global = null;
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    remote.listen((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        request.response.write('#EXTM3U\n#EXT-X-ENDLIST\n');
        await request.response.close();
      } catch (_) {}
    });
    final resolver = HighestHls(
      inspectionTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(() async {
      await resolver.close();
      await remote.close(force: true);
    });
    final uri = Uri.parse('http://127.0.0.1:${remote.port}/slow.m3u8');
    final watch = Stopwatch()..start();
    expect(await resolver.resolve(uri, null), uri);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 400)));
    expect(requests, 1);
  });

  test('起播前固定最高分辨率，保留独立音频、字幕和会话密钥', () {
    final result = HighestHls.singleRendition('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",URI="audio/main.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",URI="subs/main.m3u8"
#EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=1280x720,AUDIO="sound"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=3840x2160,AUDIO="sound",SUBTITLES="subs"
high.m3u8?token=abc
#EXT-X-STREAM-INF:BANDWIDTH=9500000,RESOLUTION=1920x1080,AUDIO="sound"
medium.m3u8
''', Uri.parse('https://cdn.example/folder/master.m3u8'))!;
    expect(result, contains('https://cdn.example/folder/high.m3u8?token=abc'));
    expect(result, isNot(contains('low.m3u8')));
    expect(result, isNot(contains('medium.m3u8')));
    expect(
      result,
      contains('URI="https://cdn.example/folder/audio/main.m3u8"'),
    );
    expect(result, contains('URI="https://cdn.example/folder/subs/main.m3u8"'));
    expect(result, contains('URI="https://cdn.example/folder/key.bin"'));
  });
  test('无分辨率按带宽选择，单线路与媒体清单不改写', () {
    final base = Uri.parse('https://cdn.example/master.m3u8');
    expect(
      HighestHls.singleRendition('#EXTM3U\n#EXTINF:5\nsegment.ts', base),
      isNull,
    );
    expect(
      HighestHls.singleRendition(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\na.m3u8',
        base,
      ),
      isNull,
    );
    final result = HighestHls.singleRendition(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=20\nb.m3u8',
      base,
    )!;
    expect(result, contains('https://cdn.example/b.m3u8'));
    expect(result, isNot(contains('/a.m3u8')));
  });
}
