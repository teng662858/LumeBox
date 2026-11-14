import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_models.dart';
import 'package:lume_box/core/util/lume_log.dart';

void main() {
  test('compatible comment reload bypasses empty cached replies without logging service tokens', () async {
    const token = 'private-route-token';
    final urls = <Uri>[];
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: 'https://worker.example/$token',
      ),
      client: MockClient((request) async {
        urls.add(request.url);
        expect(request.url.queryParameters['_'], isNotEmpty);
        return http.Response('{"comments":[]}', 200);
      }),
    );
    addTearDown(client.close);
    LumeLog.clear();
    await client.comments('episode');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await client.commentPayload(id: 'episode');
    expect(urls.map((url) => url.queryParameters['_']).toSet(), hasLength(2));
    expect(
      LumeLog.snapshot.map((e) => e.message).join('\n'),
      isNot(contains(token)),
    );
  });
  test('Cloudflare 无状态集数编号可从搜索结果直接读取弹幕', () async {
    const id =
        'lb1.aHR0cHM6Ly93d3cuaXFpeWkuY29tL3ZfZXhhbXBsZS5odG1s.signature_123';
    const token = 'private-service-token';
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: 'https://worker.example/$token',
      ),
      client: MockClient((request) async {
        expect(request.headers['User-Agent'], 'LumeBox/1.0');
        if (request.url.path.endsWith('/search/episodes')) {
          return http.Response(
            jsonEncode({
              'animes': [
                {
                  'animeTitle': '作品',
                  'episodes': [
                    {'episodeId': id, 'episodeTitle': '第1集'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.url.path, '/$token/api/v2/comment/$id');
        expect(request.url.queryParameters['format'], 'json');
        return http.Response(
          jsonEncode({
            'count': 1,
            'comments': [
              {'p': '1,1,16777215,1', 'm': '测试弹幕'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final episodes = await client.search('作品');
    expect(episodes.single.id, id);
    expect(await client.comments(episodes.single.id), hasLength(1));
  });

  for (final type in ['tv', 'movie']) {
    test('官方 TMDB $type 反查真实弹幕库，避免选入空映射', () async {
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          'app',
          'secret',
          baseUrl: DandanplayCredentials.officialBase,
        ),
        client: MockClient((r) async {
          if (r.url.queryParameters.containsKey('tmdbId')) {
            expect(r.url.queryParameters['tmdbId'], '123');
            expect(
              r.url.queryParameters['tmdbIdType'],
              type == 'tv' ? '0' : '1',
            );
            expect(r.url.queryParameters['episode'], '1');
            expect(r.url.queryParameters.containsKey('anime'), isFalse);
            return http.Response(
              jsonEncode({
                'animes': [
                  {
                    'animeTitle': '作品',
                    'episodes': [
                      {'episodeId': 42, 'episodeTitle': '第1集'},
                    ],
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (r.url.path.endsWith('/search/episodes')) {
            return http.Response('{"animes":[]}', 200);
          }
          expect(r.url.path, '/api/v2/search/tmdb');
          return http.Response(
            jsonEncode({
              'animes': [
                {'animeTitle': '作品', 'bangumiId': 'tmdb-$type-123'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      final results = await client.search('作品', episode: 1);
      expect(DandanplayClient.exactMatch(results, '作品', episode: 1)?.id, '42');
    });
  }
  test('上游把速通合集标成第1集时，不会被当成正片自动关联', () {
    const clip = DandanplayEpisode(
      id: 'clip',
      title: '花开锦绣',
      episode: '速通版 前4集高光合集',
      number: 1,
    );
    const normal = DandanplayEpisode(
      id: 'normal',
      title: '花开锦绣',
      episode: '第1集',
      number: 1,
    );
    expect(DandanplayClient.exactMatch([clip], '花开锦绣', episode: 1), isNull);
    expect(
      DandanplayClient.exactMatch([clip, normal], '花开锦绣', episode: 1),
      normal,
    );
    expect(clip.details, contains('附加内容'));
  });

  test('内置地址运行时解析，端口令牌不持久化且不发送官方签名', () async {
    var starts = 0;
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: DandanplayCredentials.builtinBase,
      ),
      localService: () async {
        starts++;
        return Uri.parse('http://127.0.0.1:9123/private-token');
      },
      client: MockClient((request) async {
        expect(request.url.host, '127.0.0.1');
        expect(
          request.headers.keys.any(
            (s) => s.toLowerCase().contains('signature'),
          ),
          false,
        );
        if (request.url.path.endsWith('/_health')) {
          return http.Response('{"ok":true}', 200);
        }
        expect(request.url.path, '/private-token/api/v2/search/episodes');
        return http.Response('{"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.checkConnection();
    expect(await client.search('测试'), isEmpty);
    expect(starts, 3);
    expect(client.credentials.baseUrl, DandanplayCredentials.builtinBase);
  });

  test('精确作品必须同时核对集数，支持中文集数和平台后缀编号', () {
    const first = DandanplayEpisode(
      id: 'ep1',
      title: '熔城(2026)【电视剧】from tencent',
      episode: '【qq】 熔城_01',
    );
    const second = DandanplayEpisode(id: 'ep2', title: '熔城', episode: '第2集');
    const unknown = DandanplayEpisode(
      id: 'unknown',
      title: '熔城',
      episode: '预告',
    );
    expect(
      DandanplayClient.exactMatch(
        [first, second, unknown],
        '熔城',
        episode: 1,
      )?.id,
      'ep1',
    );
    expect(
      DandanplayClient.exactMatch([second, unknown], '熔城', episode: 1),
      isNull,
    );
    expect(DandanplayClient.parsedEpisodeNumber('第二十三集'), 23);
    expect(DandanplayClient.parsedEpisodeNumber('第一集'), 1);
    expect(DandanplayClient.parsedEpisodeNumber('【qq】 熔城_01'), 1);
    expect(DandanplayClient.searchTitle('FROM'), 'FROM');
    expect(DandanplayClient.searchTitle('熔城【第二季】'), contains('第二季'));
  });
  test('兼容部署保留路径前缀，官方凭证不发给第三方', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'example-id',
        'example-secret',
        baseUrl: 'https://danmu.example/token/',
      ),
      client: MockClient((request) async {
        expect(request.url.path, '/token/api/v2/search/episodes');
        expect(request.url.queryParameters['anime'], '半步多·沧澜传');
        expect(request.url.queryParameters['episode'], '1');
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-appsecret')),
        );
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-signature')),
        );
        return http.Response(
          jsonEncode({
            'success': true,
            'animes': [
              {
                'animeTitle': '半步多·沧澜传',
                'episodes': [
                  {'episodeId': 'platform-123', 'episodeTitle': '第1集'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final items = await client.search('半步多·沧澜传', episode: 1);
    expect(items.single.id, 'platform-123');
  });

  test('官方请求使用签名，密钥不随请求发送', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        final headers = {
          for (final entry in request.headers.entries)
            entry.key.toLowerCase(): entry.value,
        };
        expect(headers['x-appid'], 'sample');
        expect(headers['x-appsecret'], isNull);
        final data =
            'sample${headers['x-timestamp']}${request.url.path}'
            'secret';
        expect(
          headers['x-signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"success":true,"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    expect(await client.search('作品'), isEmpty);
  });

  test('官方 TMDB 补充失败时保留原生搜索结果', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/search/episodes')) {
          return http.Response(
            jsonEncode({
              'success': true,
              'animes': [
                {
                  'animeTitle': '不相关动画',
                  'episodes': [
                    {'episodeId': 'native-1', 'episodeTitle': '第1集'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        // TMDB 补充是可选能力：没有权限/网络失败不能把已有结果丢掉。
        throw http.ClientException('tmdb unavailable', request.url);
      }),
    );
    addTearDown(client.close);
    final found = await client.search('作品', episode: 1);
    expect(found.map((episode) => episode.id), contains('native-1'));
  });

  test('内置服务返回的上游错误原因会被展示出来', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: DandanplayCredentials.builtinBase,
      ),
      localService: () async => Uri.parse('http://127.0.0.1:9123/token'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'success': false,
            'errorCode': 502,
            'errorMessage': '本机弹幕上游请求失败：fetch failed',
          }),
          502,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.search('作品'),
      throwsA(
        isA<DandanplayException>().having(
          (error) => error.message,
          'message',
          contains('本机弹幕上游请求失败'),
        ),
      ),
    );
  });

  test('官方动画搜索无同名结果时，查询 TMDB 作品再读取真实剧集 ID', () async {
    final paths = <String>[];
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.queryParameters.containsKey('tmdbId')) {
          return http.Response('{"animes":[]}', 200);
        }
        if (r.url.path.endsWith('/search/episodes')) {
          return http.Response(
            '{"success":true,"animes":[{"animeTitle":"不相关动画","episodes":[{"episodeId":1,"episodeTitle":"第1集"}]}]}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (r.url.path.endsWith('/search/tmdb')) {
          return http.Response(
            jsonEncode({
              'animes': [
                {'animeTitle': '大刑伺候', 'bangumiId': 'tmdb-tv-123'},
                {'animeTitle': '近似名称', 'bangumiId': 'tmdb-tv-456'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(r.url.path, '/api/v2/bangumi/tmdb-tv-123');
        return http.Response(
          jsonEncode({
            'bangumi': {
              'episodes': [
                {
                  'episodeId': 9000001,
                  'episodeTitle': '第1集',
                  'episodeNumber': '1',
                },
                {
                  'episodeId': 9000002,
                  'episodeTitle': '第2集',
                  'episodeNumber': '2',
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final found = await client.search('大刑伺候', episode: 1);
    final match = DandanplayClient.exactMatch(found, '大刑伺候', episode: 1);
    expect(match?.id, '9000001');
    expect(paths.length, 4);
    expect(found.any((e) => e.id == '9000002'), false);
  });

  test('官方缺少凭证时不发送无效网络请求', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((_) async {
        fail('缺少凭证不应联网');
      }),
    );
    addTearDown(client.close);
    await expectLater(client.search('作品'), throwsA(isA<DandanplayException>()));
  });

  test('弹幕时间按秒转毫秒，保留顶部底部颜色，忽略坏数据', () {
    final track = DandanplayClient.parseComments({
      'comments': [
        {'p': '12.34,5,16711680,user', 'm': '顶部'},
        {'p': '2.5,4,65280,user', 'm': '底部'},
        {'p': 'NaN,1,16777215,user', 'm': '坏数据'},
        {'p': '1e308,1,16777215,user', 'm': '时间超范围'},
        {'p': '-1,1,16777215,user', 'm': '负时间'},
      ],
    });
    expect(track.length, 2);
    expect(track.items.first.time, const Duration(milliseconds: 2500));
    expect(track.items.first.mode, DanmakuMode.bottom);
    expect(track.items.first.color, 65280);
    expect(track.items.last.time, const Duration(milliseconds: 12340));
    expect(track.items.last.mode, DanmakuMode.top);
  });

  test('只自动选择唯一精确作品，不把相近作品弹幕混入', () {
    const exact = DandanplayEpisode(
      id: '1',
      title: '半步多·沧澜传(2026)【电视剧】from imgo',
      episode: '第1集',
    );
    const other = DandanplayEpisode(
      id: '2',
      title: '半步多·沧澜传第二季',
      episode: '第1集',
    );
    expect(DandanplayClient.exactMatch([exact, other], '半步多·沧澜传')?.id, '1');
    expect(DandanplayClient.exactMatch([other], '半步多·沧澜传'), isNull);
    expect(DandanplayClient.exactMatch([exact, exact], '半步多·沧澜传'), isNull);
  });

  test('官方同时返回原生与 TMDB 条目时优先选原生条目', () {
    const native = DandanplayEpisode(
      id: 'native',
      title: '楚语者(2026)【国产剧】from tencent',
      episode: '第1集',
      number: 1,
      source: 'tencent',
    );
    const tmdb = DandanplayEpisode(
      id: 'tmdb',
      title: '楚语者',
      episode: '第1集',
      number: 1,
      source: 'TMDB',
    );
    expect(
      DandanplayClient.exactMatch([tmdb, native], '楚语者', episode: 1)?.id,
      'native',
    );
    expect(DandanplayClient.exactMatch([tmdb], '楚语者', episode: 1)?.id, 'tmdb');
  });

  test('清理裸年份、类型、平台、清晰度与语言后缀', () {
    expect(DandanplayClient.searchTitle('大刑伺候 2026·国产剧·tencent'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候 2026 国产剧 tencent'), '大刑伺候');
    expect(DandanplayClient.searchTitle('[国产剧] 大刑伺候 全40集 1080P'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候.2026.国产剧.tencent'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候.2026.1080P.WEB-DL'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候 国语'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候 2026年'), '大刑伺候');
    expect(DandanplayClient.searchTitle('大刑伺候 2026 第二季'), '大刑伺候 第二季');
    expect(DandanplayClient.searchTitle('大刑伺候 第二季 2026'), '大刑伺候 第二季');
    expect(
      DandanplayClient.searchTitle('亢奋 第三季(2026)【电视剧】from renren'),
      '亢奋 第三季',
    );
    expect(DandanplayClient.searchTitle('铁拳教育(2026)【韩剧】from hanjutv'), '铁拳教育');
  });

  test('保留可能改变作品身份的标题内容', () {
    expect(DandanplayClient.searchTitle('【我推的孩子】'), '【我推的孩子】');
    expect(
      DandanplayClient.searchTitle('Re:Zero(从零开始的异世界生活)'),
      'Re:Zero(从零开始的异世界生活)',
    );
    expect(DandanplayClient.searchTitle('大刑伺候 剧场版'), '大刑伺候 剧场版');
    expect(DandanplayClient.searchTitle('大刑伺候 OVA'), '大刑伺候 OVA');
    expect(
      DandanplayClient.searchTitle('2001 A Space Odyssey'),
      '2001 A Space Odyssey',
    );
    expect(DandanplayClient.searchTitle('2012'), '2012');
    expect(DandanplayClient.searchTitle('Spider-Man 1080P'), 'Spider-Man');
  });

  test('自动匹配能接受带裸年份/类型/平台后缀的服务标题', () {
    const decorated = DandanplayEpisode(
      id: 'ep1',
      title: '大刑伺候 2026·国产剧·tencent',
      episode: '【qq】 大刑伺候 第1集',
      number: 1,
      source: 'tencent',
    );
    expect(
      DandanplayClient.exactMatch(
        [decorated],
        '大刑伺候 2026·国产剧·tencent',
        episode: 1,
      )?.id,
      'ep1',
    );
    expect(
      DandanplayClient.exactMatch([decorated], '大刑伺候', episode: 1)?.id,
      'ep1',
    );
  });

  test('同一集空条目会换到非 TMDB 候选', () {
    const tmdb = DandanplayEpisode(
      id: 'tmdb',
      title: '大刑伺候 2026·国产剧·tencent',
      episode: '第1集',
      number: 1,
      source: 'TMDB',
    );
    const native = DandanplayEpisode(
      id: 'native',
      title: '大刑伺候(2026)【国产剧】from tencent',
      episode: '第1集',
      number: 1,
      source: 'tencent',
    );
    const otherEpisode = DandanplayEpisode(
      id: 'ep2',
      title: '大刑伺候',
      episode: '第2集',
      number: 2,
      source: 'tencent',
    );
    expect(
      DandanplayClient.alternatives([
        tmdb,
        native,
        otherEpisode,
      ], tmdb).map((item) => item.id),
      ['native'],
    );
  });

  test('自动匹配允许同名同集多个来源，原生排在 TMDB 前', () {
    const tmdb = DandanplayEpisode(
      id: 'tmdb',
      title: '铁拳教育(2026)【电视剧】from tencent',
      episode: '第1集',
      number: 1,
      source: 'TMDB',
    );
    const nativeA = DandanplayEpisode(
      id: 'renren',
      title: '铁拳教育',
      episode: '第1集',
      number: 1,
      source: 'renren',
    );
    const nativeB = DandanplayEpisode(
      id: 'hanjutv',
      title: '铁拳教育(2026)【韩剧】from hanjutv',
      episode: '第1集',
      number: 1,
      source: 'hanjutv',
    );
    const otherEpisode = DandanplayEpisode(
      id: 'ep2',
      title: '铁拳教育',
      episode: '第2集',
      number: 2,
      source: 'renren',
    );
    // 多个原生来源时 exactMatch 仍然保持“不猜”的严格口径。
    expect(
      DandanplayClient.exactMatch([tmdb, nativeA, nativeB], '铁拳教育', episode: 1),
      isNull,
    );
    final candidates = DandanplayClient.candidates(
      [tmdb, nativeA, nativeB, otherEpisode],
      '铁拳教育',
      episode: 1,
    );
    expect(candidates.map((item) => item.id), isNot(contains('ep2')));
    expect(candidates.last.id, 'tmdb');
    expect(candidates.take(2).map((item) => item.id).toSet(), {
      'renren',
      'hanjutv',
    });
  });

  test('自动搜索用清洗后的片名作为请求词', () async {
    final queries = <String>[];
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: 'https://danmu.example/custom',
      ),
      client: MockClient((request) async {
        queries.add(request.url.queryParameters['anime'] ?? '');
        return http.Response(
          '{"success":true,"animes":[]}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    expect(await client.search('大刑伺候 2026·国产剧·tencent', episode: 1), isEmpty);
    expect(queries, ['大刑伺候', '大刑伺候']);
  });

  test('签名前清理粘贴凭证的首尾空格，搜索清理年份与来源后缀', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        ' sample ',
        '\nsecret\n',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        expect(
          request.url.queryParameters[request.url.path.endsWith('/tmdb')
              ? 'keyword'
              : 'anime'],
          '作品',
        );
        expect(request.headers['X-AppId'], 'sample');
        final data =
            'sample${request.headers['X-Timestamp']}${request.url.path}secret';
        expect(
          request.headers['X-Signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"success":true,"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.search('作品(2026)【电视剧】 FROM qq');
  });

  test('官方弹幕 302 跳转 CDN 后解析弹幕，不转发鉴权头', () async {
    var requests = 0;
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        requests++;
        expect(request.followRedirects, isFalse);
        if (requests == 1) {
          expect(request.url.path, '/api/v2/comment/123450001');
          expect(request.url.queryParameters['withRelated'], 'true');
          expect(request.headers['X-Signature'], isNotEmpty);
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://comments.example/cached.json?token=cdn-token',
            },
          );
        }
        expect(request.url.host, 'comments.example');
        expect(request.url.queryParameters['token'], 'cdn-token');
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(
            anyOf(
              contains('x-appid'),
              contains('x-signature'),
              contains('x-timestamp'),
              contains('x-appsecret'),
            ),
          ),
        );
        return http.Response(
          jsonEncode({
            'comments': [
              {'p': '1.25,1,16777215,user', 'm': '弹幕'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final track = await client.comments('123450001');
    expect(track.items.single.text, '弹幕');
    expect(track.items.single.time, const Duration(milliseconds: 1250));
    expect(requests, 2);
  });

  test('同官方主机跳转时用新路径重新签名', () async {
    var requests = 0;
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        if (++requests == 1) {
          return http.Response(
            '',
            302,
            headers: {'location': '/cached/comments?format=json'},
          );
        }
        final data =
            'sample${request.headers['X-Timestamp']}/cached/comments'
            'secret';
        expect(
          request.headers['X-Signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"comments":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.comments('1');
    expect(requests, 2);
  });

  test('无效跳转与循环有限终止', () async {
    for (final location in [
      'http://comments.example/plain',
      'https://user:pass@comments.example/data',
      '/loop',
    ]) {
      var requests = 0;
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          'sample',
          'secret',
          baseUrl: DandanplayCredentials.officialBase,
        ),
        client: MockClient((_) async {
          requests++;
          return http.Response('', 302, headers: {'location': location});
        }),
      );
      await expectLater(
        client.comments('1'),
        throwsA(isA<DandanplayException>()),
      );
      expect(requests, lessThanOrEqualTo(6));
      client.close();
    }
  });

  for (final reason in {
    'Invalid Timestamp': '设备时间',
    'Invalid AppId': 'AppId 无效',
    'Invalid Signature': 'AppSecret 无效',
    'Missing Authentication Headers': '服务未收到',
  }.entries) {
    test('连接测试呈现官方鉴权原因：${reason.key}', () async {
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          'sample',
          'secret',
          baseUrl: DandanplayCredentials.officialBase,
        ),
        client: MockClient(
          (_) async =>
              http.Response('', 403, headers: {'x-error-message': reason.key}),
        ),
      );
      addTearDown(client.close);
      try {
        await client.checkConnection();
        fail('拒绝响应必须报错');
      } catch (error) {
        expect(DandanplayClient.describeError(error), contains(reason.value));
        expect(DandanplayClient.describeError(error), contains('HTTP 403'));
        expect(
          DandanplayClient.describeError(error),
          isNot(contains('secret')),
        );
      }
    });
  }

  test('连接测试区分业务失败、HTTP 失败和空搜索成功', () async {
    for (final status in [200, 429, 503]) {
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          '',
          '',
          baseUrl: 'http://localhost:1234/prefix',
        ),
        client: MockClient(
          (_) async => http.Response('{"success":false,"errorCode":1}', status),
        ),
      );
      await expectLater(
        client.checkConnection(),
        throwsA(isA<DandanplayException>()),
      );
      client.close();
    }
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      localService: () async => Uri.parse('http://localhost:1234/prefix'),
      client: MockClient(
        (r) async => http.Response(
          r.url.path.endsWith('/_health')
              ? '{"ok":true}'
              : '{"success":true,"animes":[]}',
          200,
        ),
      ),
    );
    addTearDown(client.close);
    await client.checkConnection();
  });

  test('缺失列表的响应不能误报连接成功或本集零弹幕', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      localService: () async => Uri.parse('http://localhost:1234/prefix'),
      client: MockClient((_) async => http.Response('{"success":true}', 200)),
    );
    addTearDown(client.close);
    await expectLater(
      client.checkConnection(),
      throwsA(isA<DandanplayException>()),
    );
    await expectLater(
      client.comments('1'),
      throwsA(isA<DandanplayException>()),
    );
  });

  test('按章节名称而非多线路列表位置推断集数，手动搜索可省略集数', () async {
    expect(DandanplayClient.episodeNumber('第07集', chapterIndex: 1), 7);
    expect(DandanplayClient.episodeNumber('S02E03', chapterIndex: 14), 3);
    expect(DandanplayClient.episodeNumber('EP04', chapterIndex: 15), 4);
    expect(DandanplayClient.episodeNumber('03', chapterIndex: 20), 3);
    expect(DandanplayClient.episodeNumber('1080P高清', chapterIndex: 2), 1);
    expect(DandanplayClient.episodeNumber('未知', chapterIndex: 2), 3);
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      localService: () async => Uri.parse('http://localhost:1234/prefix'),
      client: MockClient((request) async {
        expect(request.url.queryParameters.containsKey('episode'), isFalse);
        return http.Response('{"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.search('作品');
  });
}
