import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/source_import_input.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/source/kazumi_rule.dart';
import 'package:lume_box/core/source/source_package.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

const rule = {
  'api': '3',
  'name': 'Example',
  'version': '1',
  'baseURL': 'https://example.test/',
  'searchURL': 'https://example.test/search?q=@keyword',
  'searchList': '//article',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//li/a',
  'usePost': true,
  'referer': 'https://example.test/',
  'userAgent': 'Example UA',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  if (available) enableEngineOnThisPlatform();
  test('旧版已导入 Kazumi 适配自动更新，保留 ID、版本和用户脚本', () {
    final script = KazumiRule.convert(
      jsonEncode(rule),
      originUrl: 'https://rules.test/example.json',
    );
    final header = script.split('\n').first;
    final old =
        '$header\nconst kazumiRule = ${jsonEncode(rule)};\nLumeSource = {list: async () => ({items:[]})};';
    final upgraded = KazumiRule.upgradeAdapter(old);
    expect(upgraded, startsWith('$header\n'));
    expect(upgraded, contains("kazumiExtract('home')"));
    expect(KazumiRule.upgradeAdapter(upgraded), upgraded);
    expect(
      KazumiRule.upgradeAdapter('const userSource = {};'),
      'const userSource = {};',
    );
  });
  test('首页列表实际请求站点首页，第二页停止，搜索仍使用搜索接口', () async {
    final requests = <Map>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/source_web'),
      (call) async {
        final args = call.arguments as Map;
        requests.add(args);
        return {
          'url': args['url'],
          'html': '<html></html>',
          'result': [
            {
              'id': 'https://example.test/detail/1',
              'title': '真实首页作品',
              'cover': 'https://example.test/cover.jpg',
            },
          ],
          'media': [],
        };
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/source_web'),
        null,
      ),
    );
    final engine = await openEngine(
      sourceId: 'kazumi-home',
      script: KazumiRule.convert(jsonEncode(rule)),
    );
    addTearDown(engine.dispose);
    final home = await engine.call('list', {'page': 1}) as Map;
    expect((home['items'] as List).single['title'], '真实首页作品');
    expect(requests.single['url'], rule['baseURL']);
    expect(requests.single['includeHtml'], isFalse);
    expect(requests.single['script'], contains("mode = \"home\""));
    final next = await engine.call('list', {'page': 2}) as Map;
    expect(next['items'], isEmpty);
    expect(requests, hasLength(1));
  }, skip: available ? false : '本机没有 QuickJS 原生桥');
  for (final version in ['6', '7', '8', '9']) {
    test('API $version 的 XPath 规则保持原有搜索与目录契约', () {
      final script = KazumiRule.convert(
        jsonEncode({
          ...rule,
          'api': version,
          'searchMode': 'xpath',
          'chapterMode': 'xpath',
        }),
      );
      expect(SourceMetadata.parseHeader(script)!.category, 'kazumi');
    });
  }

  test('API9 搜索 JSON POST、模板编码与嵌套目录经过真实 JS 和 HTTP 桥接', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final received = <({Uri uri, String method, String body})>[];
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.add((uri: request.uri, method: request.method, body: body));
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/search'
              ? {
                  'data': {
                    'records': [
                      {'title': '测试作品', 'id': 'book / 一'},
                    ],
                  },
                }
              : {
                  'slug': '编号 / 一',
                  'roads': [
                    {
                      'name': '线路甲',
                      'episodes': [
                        {'name': '第一集', 'id': 'ep/1'},
                      ],
                    },
                    {
                      'name': '线路乙',
                      'episodes': [
                        {'name': '第二集', 'id': 2},
                      ],
                    },
                  ],
                },
        ),
      );
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final config = {
      'api': '9',
      'name': 'API9',
      'baseURL': '$base/',
      'searchMode': 'api',
      'chapterMode': 'api',
      'searchApiConfig': {
        'request': {
          'method': 'POST',
          'url': '$base/search',
          'headers': {'X-Fixture': 'test'},
          'bodyType': 'json',
          'body': {'keyword': '@keyword', 'enabled': true, 'limit': 24},
        },
        'listPath': r'$.data.records[*]',
        'namePath': r'$.title',
        'sourcePath': r'$.id',
      },
      'chapterApiConfig': {
        'request': {
          'url': '$base/chapter',
          'query': {'source': '@source'},
        },
        'format': 'nested',
        'variables': {'slug': r'$.slug'},
        'roadsPath': r'$.roads[*]',
        'roadNamePath': r'$.name',
        'episodesPath': r'$.episodes[*]',
        'episodeNamePath': r'$.name',
        'episodeUrlPath': r'$.id',
        'episodePage': {
          'url': '$base/anime/@slug/play/@episodeUrl',
          'query': {'road': '@roadNumber', 'ep': '@episodeNumber'},
        },
      },
    };
    final engine = await openEngine(
      sourceId: 'kazumi-api9-native',
      script: KazumiRule.convert(jsonEncode(config)),
    );
    addTearDown(engine.dispose);
    final result = await engine.callResult('list', {'keyword': '中文 & query'});
    expect(result.isOk, true, reason: result.error?.message);
    final item = ((result.value as Map)['items'] as List).single as Map;
    expect(item['id'], 'book / 一');
    expect(item['title'], '测试作品');
    expect(received.first.method, 'POST');
    expect(jsonDecode(received.first.body), {
      'keyword': '中文 & query',
      'enabled': true,
      'limit': 24,
    });
    final chapters = await engine.call('chapters', {'id': item['id']}) as List;
    expect(chapters.length, 2);
    expect(received.last.uri.queryParameters['source'], 'book / 一');
    expect(chapters[0]['title'], '线路甲 · 第一集');
    final url = Uri.parse(chapters[0]['id'] as String);
    expect(url.pathSegments, ['anime', '编号 / 一', 'play', 'ep/1']);
    expect(url.queryParameters, {'road': '1', 'ep': '1'});
    final detail = await engine.call('detail', {'id': item['id']}) as Map;
    expect(detail['title'], '测试作品');
  }, skip: available ? false : '本机没有 QuickJS 原生桥');

  test('API9 分隔目录保留线路顺序和含分隔字符的地址，直链交给原生播放器', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'info': {
            'from': r'线路甲$$$线路乙',
            'urls': r'第一集$https://cdn.test/1.m3u8?token=a$b#第二集$/play/2$$$第一集$https://cdn.test/alt.mp4',
          },
        }),
      );
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final config = {
      ...rule,
      'api': '9',
      'chapterMode': 'api',
      'useNativePlayer': true,
      'baseURL': '$base/',
      'chapterApiConfig': {
        'request': {
          'url': '$base/detail',
          'query': {'id': '@source'},
        },
        'format': 'delimited',
        'roadNamesPath': r'$.info.from',
        'roadEpisodesPath': r'$.info.urls',
        'roadSeparator': r'$$$',
        'episodeSeparator': '#',
        'fieldSeparator': r'$',
      },
    };
    final engine = await openEngine(
      sourceId: 'kazumi-delimited-native',
      script: KazumiRule.convert(jsonEncode(config)),
    );
    addTearDown(engine.dispose);
    final result = await engine.callResult('chapters', {'id': 'book'});
    expect(result.isOk, true, reason: result.error?.message);
    final chapters = result.value as List;
    expect(chapters.map((c) => c['title']), [
      '线路甲 · 第一集',
      '线路甲 · 第二集',
      '线路乙 · 第一集',
    ]);
    expect(chapters[0]['id'], r'https://cdn.test/1.m3u8?token=a$b');
    expect(chapters[1]['id'], '$base/play/2');
    final content = await engine.call('content', {
      'id': 'book',
      'chapterId': chapters[0]['id'],
    }) as Map;
    expect(content['kind'], 'video');
    expect(content['url'], chapters[0]['id']);
  }, skip: available ? false : '本机没有 QuickJS 原生桥');
  test('JSON 文件与粘贴识别为视频源，更新沿用规则地址身份', () {
    final json = jsonEncode(rule);
    expect(SourceImportInput.classify(json).isScript, true);
    final first = SourcePackage.prepare(
      json,
      originUrl: 'https://rules.test/Example.json',
    );
    final second = SourcePackage.prepare(
      jsonEncode({...rule, 'version': '2', 'baseURL': 'https://mirror.test/'}),
      originUrl: 'https://rules.test/Example.json',
    );
    expect(SourceMetadata.parseHeader(first)!.category, 'kazumi');
    expect(
      SourceMetadata.parseHeader(first)!.id,
      SourceMetadata.parseHeader(second)!.id,
    );
    expect(SourceMetadata.parseHeader(second)!.version, '2');
    expect(
      () => KazumiRule.convert(jsonEncode({...rule, 'deprecated': true})),
      throwsFormatException,
    );
    expect(
      () => KazumiRule.convert(jsonEncode({...rule, 'api': '99'})),
      throwsFormatException,
    );
  });

  test('索引订阅跳过失效规则，保留每个 JSON 的更新地址', () async {
    const origin = 'https://rules.test/index.json';
    final files = {
      origin: jsonEncode([
        {'name': 'Example', 'version': '1', 'useNativePlayer': true},
        {'name': 'Gone', 'version': '1', 'useNativePlayer': true},
      ]),
      'https://rules.test/Example.json': jsonEncode(rule),
    };
    final failures = <String>[];
    final subscription = SourceSubscription(
      fetch: (url) async {
        final text = files[url];
        if (text == null) throw StateError('HTTP 404');
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
      onSkip: (url, _) => failures.add(url),
    );
    final refs = await subscription.resolveRefs([origin]);
    expect(refs.single.url, 'https://rules.test/Example.json');
    expect(SourceMetadata.parseHeader(refs.single.script)!.name, 'Example');
    expect(subscription.complete, false);
    expect(failures, ['https://rules.test/Gone.json']);
  });

  test('真实 JS 引擎搜索发送 POST 与请求头，未捕获媒体时保留网页播放', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <Map>[];
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/source_web'),
      (call) async {
        if (call.method != 'render') return null;
        final args = call.arguments as Map;
        requests.add(args);
        return {
          'url': args['url'],
          'html': '<html></html>',
          'result': [],
          'media': [],
        };
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/source_web'),
        null,
      ),
    );
    final engine = await openEngine(
      sourceId: 'kazumi-fixture',
      script: SourcePackage.prepare(jsonEncode(rule)),
    );
    addTearDown(engine.dispose);
    final list = await engine.call('list', {
      'keyword': '中文 & query',
      'page': 1,
    });
    expect((list as Map)['items'], isEmpty);
    expect(
      requests.first['includeHtml'],
      isFalse,
      reason: '仅提取结构化数据，不把大页面HTML送过原生通道',
    );
    expect(requests.first['method'], 'POST');
    expect(requests.first['url'], 'https://example.test/search');
    expect(requests.first['body'], 'q=${Uri.encodeComponent('中文 & query')}');
    expect(
      (requests.first['headers'] as Map)['Referer'],
      'https://example.test/',
    );
    final content = await engine.call('content', {
      'id': 'https://example.test/title',
      'chapterId': 'https://example.test/play',
    });
    expect((content as Map)['kind'], 'webplayer');
    expect(content['pageUrl'], 'https://example.test/play');
  }, skip: available ? false : '本机没有 QuickJS 原生桥');
}
