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
    var requests = 0;
    remote.listen((request) async {
      requests++;
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
    final uri = base.resolve('/start.m3u8');
    const headers = {'Referer': 'https://site.example/'};
    expect(await HighestHls.entryIsPortrait(uri, headers), isFalse);
    final selected = await resolver.resolve(uri, headers);
    expect(requests, 2, reason: '画质选择复用方向探测的请求及其跳转');
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
  test('只采用方向一致且声明完整的 HLS 主清单', () {
    const portrait =
        '#EXT-X-STREAM-INF:BANDWIDTH=10,RESOLUTION=720x1280\na.m3u8';
    const landscape =
        '#EXT-X-STREAM-INF:BANDWIDTH=10,RESOLUTION=1280x720\nb.m3u8';
    expect(HighestHls.manifestIsPortrait('#EXTM3U\n$portrait'), isTrue);
    expect(
      HighestHls.manifestIsPortrait('#EXTM3U\n$portrait\n$landscape'),
      isNull,
    );
    expect(
      HighestHls.manifestIsPortrait('#EXTM3U\n#EXTINF:4,\nsegment.ts'),
      isNull,
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

  test('audio fallback does not hide the orientation of the video variants', () {
    const audio = '#EXT-X-STREAM-INF:BANDWIDTH=400000,CODECS="mp4a.40.2"\naudio.m3u8';
    const unknown = '#EXT-X-STREAM-INF:BANDWIDTH=500000\nunknown.m3u8';
    const portrait = '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=720x1280\nvideo.m3u8';
    expect(HighestHls.manifestIsPortrait('#EXTM3U\n$audio\n$portrait'), isTrue);
    expect(HighestHls.manifestIsPortrait('#EXTM3U\n$portrait\n$audio\n$unknown'), isNull);
    expect(HighestHls.manifestIsPortrait('#EXTM3U\n$audio'), isNull);
  });

  test('video selection keeps an unlabelled variant over an explicit audio fallback', () {
    const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="mp4a.40.2"\naudio.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=600000\nmovie.m3u8';
    final chosen = HighestHls.singleRendition(master, Uri.parse('https://cdn.example/master.m3u8'));
    expect(chosen, contains('/movie.m3u8'));
    expect(chosen, isNot(contains('/audio.m3u8')));
  });

  test('起播前固定最高分辨率，保留独立音频、字幕和会话密钥', () {
    final result = HighestHls.singleRendition('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",URI="audio/main.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",URI="subs/main.m3u8"
# A comment mentioning URI="leave-this-alone"
#EXT-X-DATERANGE:ID="intro",START-DATE="2025-01-01T00:00:00Z",X-LABEL="文字,URI=metadata",X-ASSET-URI="break,a.json",X-ALT-URI="break,b.json"
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
    expect(result, contains('# A comment mentioning URI="leave-this-alone"'));
    expect(result, contains('X-LABEL="文字,URI=metadata",'
        'X-ASSET-URI="https://cdn.example/folder/break,a.json",'
        'X-ALT-URI="https://cdn.example/folder/break,b.json"'));
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
  test('画质选择忽略标签与地址之间的空行和注释', () {
    final selected = HighestHls.singleRendition(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\n# low\nlow.m3u8\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=20\n\n# high\nhigh.m3u8\n',
      Uri.parse('https://cdn.example/master.m3u8'),
    );
    expect(selected, contains('https://cdn.example/high.m3u8'));
    expect(selected, isNot(contains('low.m3u8')));
    expect(selected, isNot(contains('BANDWIDTH=10')));
  });

  test('未标分辨率的 HLS 视频不会因纯音频码率较高而丢失画面', () {
    final base = Uri.parse('https://example.test/master.m3u8');
    const audio = '#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="mp4a.40.2"\naudio.m3u8';
    final master = HighestHls.singleRendition(
      '#EXTM3U\n$audio\n#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.42e01e,mp4a.40.2"\nvideo.m3u8', base,
    );
    expect(master, contains('/video.m3u8'));
    expect(master, isNot(contains('/audio.m3u8')));
    final music = HighestHls.singleRendition(
      '#EXTM3U\n$audio\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"\nlow.m3u8', base,
    );
    expect(music, contains('/audio.m3u8'));
  });
}
