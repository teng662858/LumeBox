import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/js/tvbox_source_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/tvbox_config.dart';
import 'package:lume_box/core/source/tvbox_live_playlist.dart';
import 'package:lume_box/features/source/tvbox_import_page.dart';

import 'support/fake_source_manager.dart';
import 'support/pump_io.dart';

String config() => jsonEncode({
  'spider': 'https://example.invalid/plugin.jar',
  'sites': [
    {
      'key': 'json',
      'name': '采集',
      'type': 1,
      'api': 'https://fixture.invalid/api.php?ac=list&token=keep',
    },
    {
      'key': 'xml',
      'name': 'XML',
      'type': 0,
      'api': 'https://fixture.invalid/xml',
    },
    {
      'key': 'py',
      'name': 'Python',
      'type': 3,
      'api': '/py/test.py',
      'ext': {'token': 'private'},
    },
    {'key': 'jar', 'name': 'CSP', 'type': 3, 'api': 'csp_DouDou'},
    {'key': 'bad', 'name': '错误', 'type': 1, 'api': ''},
  ],
  'lives': [
    {'name': '直播', 'url': 'https://fixture.invalid/channels.m3u'},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('config preserves types, relative Python/extend and reports unsupported entries', () {
    final parsed = TvBoxConfig.parse(
      config(),
      origin: 'https://fixture.invalid/config.json',
    );
    expect(parsed.entries.length, 6);
    expect(parsed.entries.where((e) => e.supported).length, 4);
    expect(parsed.entries[2].api, 'https://fixture.invalid/py/test.py');
    expect(parsed.entries[3].reason, contains('JAR/CSP'));
    expect(parsed.entries[4].supported, false);
    expect(parsed.notes.single, contains('spider'));
    expect(TvBoxConfig.resolve('', 'https://fixture.invalid'), '');
    final py = parsed.entries[2].pythonScript(
      Uint8List.fromList(utf8.encode('class Spider: pass')),
    );
    expect(py, contains('# LumePythonBytes:'));
    expect(TvBoxEntry.fromScript(py)?.ext, {'token': 'private'});
    expect(TvBoxConfig.parse(config()).entries[2].supported, false);
  });

  test('native engine JSON CMS: categories, filtering, pagination, search, details, all routes and playback', () async {
    final urls = <Uri>[];
    final entry = TvBoxConfig.parse(config()).entries.first;
    final engine = await SourceEngineRegistry.createForScript(
      script: entry.script,
      kind: CatEngineKind.quickjs,
      sourceId: entry.id,
      section: Section.video,
      http: LumeHttp(
        client: MockClient((request) async {
          urls.add(request.url);
          final data = request.url.queryParameters['ac'] == 'list'
              ? {
                  'class': [
                    {'type_id': 1, 'type_name': '电影'},
                    {'type_id': 2, 'type_name': '电视剧'},
                  ],
                }
              : {
                  'page': 1,
                  'pagecount': 2,
                  'list': [
                    {
                      'vod_id': 42,
                      'vod_name': '测试电影',
                      'vod_pic': '/cover.jpg',
                      'vod_content': '<p>真实简介</p>',
                      'vod_play_from': r'高清$$$备用',
                      'vod_play_url': r'一$https://media.invalid/one.m3u8#二$https://media.invalid/two.mp4$$$备用$https://media.invalid/page',
                    },
                  ],
                };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    expect(engine, isA<TvBoxSourceEngine>());
    addTearDown(engine!.dispose);
    expect(await engine.loadScript(entry.script), true);
    final cats = (await engine.callResult('categories')).value as List;
    expect(cats.map((e) => e['id']), ['1', '2']);
    final list =
        (await engine.callResult('list', {
              'categoryId': '2',
              'page': 2,
              'keyword': '剧',
            })).value
            as Map;
    expect(list['items'], hasLength(1));
    expect(urls.last.queryParameters, containsPair('token', 'keep'));
    expect(urls.last.queryParameters, containsPair('t', '2'));
    expect(urls.last.queryParameters, containsPair('pg', '2'));
    expect(urls.last.queryParameters, containsPair('wd', '剧'));
    expect(
      ((await engine.callResult('detail', {'id': '42'})).value
          as Map)['description'],
      '真实简介',
    );
    final chapters =
        (await engine.callResult('chapters', {'id': '42'})).value as List;
    expect(chapters, hasLength(3));
    final video =
        (await engine.callResult('content', {
              'id': '42',
              'chapterId': '0:1',
            })).value
            as Map;
    expect(video['url'], 'https://media.invalid/two.mp4');
    expect(
      ((await engine.callResult('content', {
            'id': '42',
            'chapterId': '1:0',
          })).value
          as Map)['kind'],
      'webplayer',
    );
    expect(
      urls.where((u) => u.queryParameters.containsKey('ids')),
      hasLength(1),
    );
  });

  test(
    'XML CMS parses CDATA, categories and separate playback flags',
    () async {
      final entry = TvBoxConfig.parse(config()).entries[1];
      final engine = TvBoxSourceEngine(
        LumeHttp(
          client: MockClient(
            (_) async => http.Response(
              '<rss><class><ty id="7">动漫</ty></class><list page="1" pagecount="3"><video><id>9</id><name><![CDATA[A & B]]></name><pic>https://fixture.invalid/a.jpg</pic><des><![CDATA[<p>简介</p>]]></des><dl><dd flag="高清"><![CDATA[第一集\$https://media.invalid/a.m3u8]]></dd><dd flag="备线"><![CDATA[第二集\$https://media.invalid/b.mp4]]></dd></dl></video></list></rss>',
              200,
              headers: {'content-type': 'text/xml; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(engine.dispose);
      await engine.loadScript(entry.script);
      expect(
        ((await engine.callResult('categories')).value as List).single['title'],
        '动漫',
      );
      expect(
        ((await engine.callResult('list', {'page': 2})).value
            as Map)['hasMore'],
        true,
      );
      expect(
        (await engine.callResult('chapters', {'id': '9'})).value,
        hasLength(2),
      );
      expect(
        ((await engine.callResult('content', {
              'id': '9',
              'chapterId': '1:0',
            })).value
            as Map)['url'],
        'https://media.invalid/b.mp4',
      );
    },
  );

  test('M3U/TXT channel groups, merged routes, headers, relative URLs and UDP rejection', () {
    final m3u = TvBoxLivePlaylist.parse(
      '#EXTM3U\n#EXTINF:-1 group-title="央视" tvg-logo="/c.jpg",CCTV1\n#EXTVLCOPT:http-user-agent=Player\n/live.m3u8|Referer=https%3A%2F%2Fref.invalid\n#EXTINF:-1 group-title="央视",CCTV1\nhttps://backup.invalid/live\n#EXTINF:-1,UDP\nudp://239.0.0.1:1234',
      origin: 'https://fixture.invalid/list.m3u',
    );
    expect(m3u.channels, hasLength(1));
    expect(m3u.skipped, 1);
    expect(m3u.channels.single.routes, hasLength(2));
    expect(m3u.channels.single.routes.first.headers, {
      'User-Agent': 'Player',
      'Referer': 'https://ref.invalid',
    });
    final txt = TvBoxLivePlaylist.parse(
      '地方台,#genre#\n频道,http://fixture.invalid/a#https://fixture.invalid/b',
      origin: 'https://fixture.invalid/live.txt',
    );
    expect(txt.channels.single.group, '地方台');
    expect(txt.channels.single.routes, hasLength(2));
    expect(
      () => TvBoxLivePlaylist.parse(
        '<html>错误页</html>',
        origin: 'https://fixture.invalid/',
      ),
      throwsFormatException,
    );
  });

  test(
    'live engine exposes real groups and routes through all five methods',
    () async {
      final entry = TvBoxConfig.parse(config()).entries.last;
      final engine = TvBoxSourceEngine(
        LumeHttp(
          client: MockClient(
            (_) async => http.Response(
              '央视,#genre#\nCCTV1,https://media.invalid/a.m3u8\n地方,#genre#\n地方台,https://media.invalid/b.m3u8',
              200,
              headers: {'content-type': 'text/plain; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(engine.dispose);
      await engine.loadScript(entry.script);
      final categories = (await engine.callResult('categories')).value as List;
      expect(categories, hasLength(2));
      final items =
          ((await engine.callResult('list', {
                    'categoryId': categories[1]['id'],
                  })).value
                  as Map)['items']
              as List;
      expect(items.single['title'], '地方台');
      final id = items.single['id'];
      expect((await engine.callResult('detail', {'id': id})).isOk, true);
      final eps =
          (await engine.callResult('chapters', {'id': id})).value as List;
      expect(
        ((await engine.callResult('content', {
              'id': id,
              'chapterId': eps.single['id'],
            })).value
            as Map)['url'],
        'https://media.invalid/b.m3u8',
      );
    },
  );

  test(
    'subscription resolves TVBox as typed entries and never downloads JAR',
    () async {
      final requests = <String>[];
      final subscription = SourceSubscription(
        fetch: (url) async {
          requests.add(url);
          final text = url.endsWith('.py') ? 'class Spider: pass' : config();
          return SourceFetchResult(
            text: text,
            bytes: Uint8List.fromList(utf8.encode(text)),
          );
        },
        section: 'video',
      );
      final refs = await subscription.resolveRefs([
        'https://fixture.invalid/config.json',
      ]);
      expect(refs, hasLength(4));
      expect(requests.any((u) => u.endsWith('.jar')), false);
      expect(
        refs.where((r) => r.script.contains('# LumePythonBytes:')),
        hasLength(1),
      );
    },
  );

  test('live channel identity survives list reorder after refresh', () async {
    var reordered = false;
    final entry = TvBoxConfig.parse(config()).entries.last;
    final engine = TvBoxSourceEngine(
      LumeHttp(
        client: MockClient(
          (_) async => http.Response(
            reordered
                ? '组,#genre#\nB,https://media.invalid/b.m3u8\nA,https://media.invalid/a.m3u8'
                : '组,#genre#\nA,https://media.invalid/a.m3u8\nB,https://media.invalid/b.m3u8',
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          ),
        ),
      ),
    );
    addTearDown(engine.dispose);
    await engine.loadScript(entry.script);
    final items =
        ((await engine.callResult('list')).value as Map)['items'] as List;
    final id = items.first['id'];
    reordered = true;
    await engine.applyScriptConfig({});
    expect(
      ((await engine.callResult('detail', {'id': id})).value as Map)['title'],
      'A',
    );
    expect(
      ((await engine.callResult('content', {'id': id, 'chapterId': '0'})).value
          as Map)['url'],
      'https://media.invalid/a.m3u8',
    );
  });

  testWidgets(
    'file preview shows incompatibility and imports selected subset with per-entry result',
    (tester) async {
      final manager = FakeSourceManager();
      await tester.pumpWidget(
        MaterialApp(
          home: TvBoxImportPage(
            manager: manager,
            readFile: () async => (name: '配置.json', text: config()),
            fetch: (url) async => throw const FormatException('下载失败'),
          ),
        ),
      );
      await tester.tap(find.text('选择本地 JSON 文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('可导入 3 项'), findsOneWidget);
      await tester.ensureVisible(find.text('取消全选'));
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('采集'));
      await tester.tap(find.text('采集'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导入所选 1 项'));
      await tester.tap(find.text('导入所选 1 项'));
      await pumpIoAndSettle(tester);
      expect(manager.imported, hasLength(1));
      await tester.scrollUntilVisible(
        find.text('导入成功 1 项 · 失败 0 项'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('导入成功 1 项 · 失败 0 项'), findsOneWidget);
    },
  );
}
