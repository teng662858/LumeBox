import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_stream.dart';

void main() {
  const config = DandanplayCredentials(
    '',
    '',
    baseUrl: 'https://service.test/token',
  );
  test('server matching preserves token prefix and file name; link lookup requests duration', () async {
    final client = DandanplayClient(
      credentials: config,
      client: MockClient((r) async {
        expect(r.url.path, startsWith('/token/api/v2/'));
        if (r.url.path.endsWith('/match')) {
          expect(r.method, 'POST');
          expect(jsonDecode(r.body)['fileName'], '剧名 S02E03');
          return http.Response(
            jsonEncode({
              'isMatched': true,
              'matches': [
                {
                  'episodeId': 'mapped',
                  'animeTitle': '映射后作品',
                  'episodeTitle': '第15集',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(r.url.queryParameters['url'], 'https://video.test/watch/1');
        expect(r.url.queryParameters['duration'], 'true');
        expect(r.url.queryParameters['segmentflag'], 'true');
        return http.Response('{"comments":[],"videoDuration":120}', 200);
      }),
    );
    expect((await client.match('剧名 S02E03'))?.id, 'mapped');
    expect(
      (await client.commentPayload(
        videoUrl: Uri.parse('https://video.test/watch/1'),
      ))['videoDuration'],
      120,
    );
    client.close();
  });
  test('POST bodies cannot follow cross-origin redirects', () async {
    var calls = 0;
    final client = DandanplayClient(
      credentials: config,
      client: MockClient((r) async {
        calls++;
        return http.Response(
          '',
          307,
          headers: {'location': 'https://other.test/receive'},
        );
      }),
    );
    await expectLater(
      client.updateFavorite('add', '作品'),
      throwsA(isA<DandanplayException>()),
    );
    expect(calls, 1);
    client.close();
  });
  test('segments load near position only, reuse data, deduplicate and load seek target', () async {
    final starts = <int>[];
    final client = DandanplayClient(
      credentials: config,
      client: MockClient((r) async {
        final start = jsonDecode(r.body)['segment_start'] as int;
        starts.add(start);
        return http.Response(
          jsonEncode({
            'comments': [
              {'p': '$start,1,16777215', 'm': 'part$start'},
              {'p': '$start,1,16777215', 'm': 'part$start'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final stream = DanmakuStream(client, {
      'duration': 1000,
      'segmentList': [
        for (final start in [0, 300, 600])
          {
            'type': 'qq',
            'segment_start': start,
            'segment_end': start + 299,
            'url': 'https://video.test/$start',
          },
      ],
    });
    await stream.loadAt(Duration.zero);
    expect(starts, [0]);
    expect(stream.track.length, 1);
    await stream.loadAt(const Duration(seconds: 10));
    expect(starts, [0]);
    await stream.loadAt(const Duration(seconds: 650));
    expect(starts, [0, 600]);
    expect(stream.track.length, 2);
    stream.close();
    await stream.loadAt(const Duration(seconds: 350));
    expect(starts, [0, 600]);
  });
}
