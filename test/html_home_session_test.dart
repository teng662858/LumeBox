import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/web/html_home_import.dart';
import 'package:lume_box/core/web/html_home_sdk.dart';
import 'package:lume_box/core/web/html_home_session.dart';
import 'package:lume_box/core/web/web_home_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late WebHomeStore store;
  late HttpClient client;
  HttpOverrides? overrides;
  final sessions = <HtmlHomeSession>[];
  final opened = <HtmlHomePlayback>[];
  const html =
      '<!doctype html><html><head><title>直播 &amp; 聚合</title></head>'
      '<body><script>window.authorBoot=!!fm.req;</script></body></html>';
  final source = HtmlHomeImport.decode('直播.html', utf8.encode(html));

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('html-home-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    store = await WebHomeStore.open();
    store.upsert(source);
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    client = HttpClient();
    opened.clear();
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    client.close(force: true);
    HttpOverrides.global = overrides;
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    directory.deleteSync(recursive: true);
  });

  Future<HtmlHomeSession> start({
    WebHomeSource? home,
    Future<http.Response> Function(http.Request)? send,
  }) async {
    final session = await HtmlHomeSession.start(
      source: home ?? source,
      store: store,
      onPlay: (value) async => opened.add(value),
      onChrome: (options) async => {
        'chromeMode': options['mode'],
        'safeTop': 59,
      },
      http: LumeHttp(
        client: MockClient(send ?? (_) async => http.Response('ok', 200)),
      ),
    );
    sessions.add(session);
    return session;
  }

  Future<(int, String)> get(Uri uri, {String? host}) async {
    final request = await client.getUrl(uri);
    if (host != null) request.headers.set('host', host);
    final response = await request.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }

  Future<(int, Map)> rpc(
    HtmlHomeSession session,
    String method,
    Map args, {
    String? origin,
  }) async {
    final request = await client.postUrl(session.base.resolve('rpc'));
    request.headers.set('origin', origin ?? session.base.origin);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'method': method, 'args': args}));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode, text.isEmpty ? {} : jsonDecode(text) as Map);
  }

  test('导入的 HTML 自包含保存、去重稳定，旧网页地址照常读取', () {
    expect(source.name, '直播 & 聚合');
    expect(source.isLocal, true);
    final again = HtmlHomeImport.decode(
      'renamed.htm',
      utf8.encode('\uFEFF$html'),
    );
    expect(again.id, source.id);
    store.upsert(again);
    expect(store.items, hasLength(1));
    final library = ReadingLibrary.find(Section.video)!;
    final saved = jsonDecode(library.setting('video.web.homes.v1')!) as List;
    expect(WebHomeSource.fromJson(saved.single)?.html, html);
    expect(
      WebHomeSource.fromJson({
        'id': 'old',
        'name': '旧网页',
        'url': 'https://example.com',
      })?.isLocal,
      false,
    );
    expect(source.copyWith(name: '自定义名称').html, html);
  });

  test('用户听书合集完整文件可导入并注入宿主 SDK', () async {
    final imported = HtmlHomeImport.decode(
      '听书合集.html',
      File('sources/web/听书合集.html').readAsBytesSync(),
    );
    expect(imported.name, '听书');
    expect(imported.html, contains('name="lumebox-version" content="1.0.1"'));
    store.upsert(imported);
    final session = await start(home: imported);
    final page = await get(session.page);
    expect(page.$1, 200);
    expect(page.$2, contains('window.fm='));
  });

  test('拒绝损坏、非 HTML、错误编码和过大的导入文件', () {
    expect(
      () => HtmlHomeImport.decode('x.js', utf8.encode(html)),
      throwsFormatException,
    );
    expect(
      () => HtmlHomeImport.decode('x.html', utf8.encode('ordinary text')),
      throwsFormatException,
    );
    expect(
      () => HtmlHomeImport.decode('x.html', [255, 254, 0]),
      throwsFormatException,
    );
    expect(
      () => HtmlHomeImport.decode(
        'x.html',
        List.filled(HtmlHomeImport.maxBytes + 1, 32),
      ),
      throwsFormatException,
    );
    expect(
      WebHomeSource.fromJson({
        'id': 'x',
        'name': 'bad',
        'url': 'file:///etc/passwd',
      }),
      isNull,
    );
  });

  test('SDK 在作者脚本之前可用，缓存字符串不能闭合注入脚本', () async {
    store.writeLocalState(source.id, {
      'storage': {'theme': '</script><script>bad()</script>'},
    });
    final session = await start();
    final (status, body) = await get(session.page);
    expect(status, 200);
    expect(
      body.indexOf('window.fm='),
      lessThan(body.indexOf('window.authorBoot')),
    );
    expect(body, isNot(contains("'theme':'</script>")));
    final sdk = htmlHomeSdk('http://127.0.0.1/rpc', {'x': '</script>'}, {});
    expect(sdk, isNot(contains('</script>')));
    expect(sdk, contains(r'\u003c/script>'));
  });

  test('HTTP 请求保留方法、请求头、JSON 响应和真实 HTTP 错误', () async {
    final seen = <http.Request>[];
    final session = await start(
      send: (request) async {
        seen.add(request);
        return http.Response(
          '{"answer":42}',
          request.url.path == '/blocked' ? 403 : 200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    final (status, packet) = await rpc(session, 'request', {
      'url': 'https://fixture.invalid/api',
      'options': {
        'method': 'POST',
        'headers': {
          'Referer': 'https://site.invalid/',
          'User-Agent': 'test-agent',
        },
        'body': {'q': '中文'},
        'responseType': 'json',
      },
    });
    expect(status, 200);
    expect((packet['result'] as Map)['body'], {'answer': 42});
    expect(seen.single.method, 'POST');
    expect(seen.single.body, '{"q":"中文"}');
    expect(seen.single.headers['Referer'], 'https://site.invalid/');
    final failed = await session.dispatch('request', {
      'url': 'https://fixture.invalid/blocked',
    });
    expect((failed as Map)['ok'], false);
    expect(failed['status'], 403);
  });

  test('HTTP 请求兼容使用 options.data 的网页脚本', () async {
    late http.Request seen;
    final session = await start(
      send: (request) async {
        seen = request;
        return http.Response('ok', 200);
      },
    );
    final result = await session.dispatch('request', {
      'url': 'https://fixture.invalid/api',
      'options': {
        'method': 'POST',
        'data': {'q': '中文'},
      },
    }) as Map;
    expect(result['ok'], true);
    expect(seen.body, '{"q":"中文"}');
    expect(seen.headers['Content-Type'], 'application/json');
  });

  test('资源转发使用正确请求头，保留图片响应并限制访问协议', () async {
    final session = await start(
      send: (request) async {
        expect(request.headers['Referer'], 'https://live.invalid/');
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/png'},
        );
      },
    );
    final uri = session.base
        .resolve('resource')
        .replace(
          queryParameters: {
            'url': 'https://fixture.invalid/image.png',
            'headers': jsonEncode({'Referer': 'https://live.invalid/'}),
          },
        );
    final response = await (await client.getUrl(uri)).close();
    expect(response.headers.contentType?.mimeType, 'image/png');
    expect(
      await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      [1, 2, 3],
    );
    expect(
      () => session.dispatch('request', {'url': 'file:///private/data'}),
      throwsFormatException,
    );
    expect(
      () => htmlHomeHeaders({'x': 'a\r\nAuthorization: bad'}),
      throwsFormatException,
    );
  });

  test('RPC 校验来源、会话路径和 Host；远程网页没有原生接口', () async {
    final session = await start();
    expect(
      (await rpc(session, 'play', {
        'url': 'https://fixture.invalid/a.mp4',
      }, origin: 'https://other.invalid')).$1,
      403,
    );
    expect(opened, isEmpty);
    expect(
      (await get(session.page.replace(path: '/wrong/index.html'))).$1,
      404,
    );
    expect((await get(session.page, host: 'other.invalid')).$1, 404);
    expect(
      () => HtmlHomeSession.start(
        source: const WebHomeSource(
          id: 'r',
          name: 'remote',
          url: 'https://example.com',
        ),
        store: store,
        onPlay: (_) async {},
        onChrome: (_) async => {},
      ),
      throwsArgumentError,
    );
  });

  test('每个 HTML 的缓存和 localStorage 独立，重开能恢复，删除时清理', () async {
    final a = await start();
    final second = source.copyWith(name: '另一个');
    final different = WebHomeSource(
      id: 'another-id',
      name: second.name,
      url: '',
      html: second.html,
    );
    store.upsert(different);
    final b = await start(home: different);
    await a.dispatch('cache.set', {
      'scope': 'live',
      'key': 'theme',
      'value': 'green',
    });
    await a.dispatch('storage.set', {'key': 'history', 'value': '[1,2]'});
    expect(
      await b.dispatch('cache.get', {'scope': 'live', 'key': 'theme'}),
      isNull,
    );
    expect(
      await a.dispatch('cache.get', {'scope': '', 'key': 'theme'}),
      isNull,
    );
    await a.close();
    final reopened = await start();
    expect(
      await reopened.dispatch('cache.get', {'scope': 'live', 'key': 'theme'}),
      'green',
    );
    final page = (await get(reopened.page)).$2;
    expect(page, contains('"history":"[1,2]"'));
    store.remove(source.id);
    expect(store.readLocalState(source.id), isEmpty);
  });

  test('vod 播放参数的直链及请求头可交给播放器，分享和磁力不伪装成直链', () async {
    final session = await start();
    final packet = await rpc(session, 'play', {
      'url': 'https://fixture.invalid/live.m3u8',
      'title': '直播间',
      'options': {
        'headers': {'Referer': 'https://live.invalid/'},
      },
    });
    expect((packet.$2['result'] as Map)['opened'], true);
    expect(opened.single.uri.path, '/live.m3u8');
    expect(opened.single.headers['Referer'], 'https://live.invalid/');
    expect(
      HtmlHomePlayback.parse({'url': 'push://https://pan.invalid/s/abc'})
          .shareLink,
      true,
    );
    expect(
      HtmlHomePlayback.parse({'url': 'magnet:?xt=urn:btih:abcd'}).uri.scheme,
      'magnet',
    );
    expect(
      () => HtmlHomePlayback.parse({'url': 'javascript:alert(1)'}),
      throwsFormatException,
    );
    final chrome = await session.dispatch('chrome', {'mode': 'edge'});
    expect(chrome, {'chromeMode': 'edge', 'safeTop': 59});
  });

  test('关闭会话后拒绝调用，同时不影响其他网页的请求', () async {
    final a = await start(), b = await start();
    await a.close();
    expect(
      () => a.dispatch('play', {'url': 'https://fixture.invalid/a.mp4'}),
      throwsStateError,
    );
    expect(
      (await b.dispatch('request', {'url': 'https://fixture.invalid/'})
          as Map)['ok'],
      true,
    );
    expect(opened, isEmpty);
  });

  test('网页播放保留47集和选中位置，后续切集通过原网页解析', () async {
    final session = await start();
    await session.dispatch('play', {
      'url': 'https://fixture.invalid/12.m3u8',
      'title': '兰香如故',
      'options': {
        'playlist': {
          'id': 'playlist-1',
          'itemId': 'drama-47',
          'selected': 11,
          'episodes': List.generate(
            47,
            (i) => {'title': '第${i + 1}集', 'line': '4K'},
          ),
        },
      },
    });
    expect(opened.single.episodes, hasLength(47));
    expect(opened.single.selected, 11);
    expect(opened.single.itemId, 'drama-47');
    final next = await session.resolveEpisode('playlist-1', 12, (script) async {
      expect(script, 'window.__lumeResolveHomeEpisode(1,"playlist-1",12);');
      await session.dispatch('episode.result', {
        'job': 1,
        'value': {
          'url': 'https://fixture.invalid/13.m3u8',
          'options': {
            'headers': {'Referer': 'episode13'},
          },
        },
      });
    });
    expect(next.uri.path, '/13.m3u8');
    expect(next.headers['Referer'], 'episode13');
    expect(await session.dispatch('episode.result', {'job': 1}), false);
    await expectLater(
      session.resolveEpisode('playlist-1', 13, (_) async {
        await session.dispatch('episode.result', {'job': 2, 'error': '解析失败'});
      }),
      throwsStateError,
    );
    await expectLater(
      session.resolveEpisode('playlist-1', 14, (_) async {
        throw StateError('WebView disposed');
      }),
      throwsStateError,
    );
    final pending = session.resolveEpisode('playlist-1', 15, (_) async {
      await session.close();
    });
    await expectLater(pending, throwsStateError);
  });

  test('拒绝越界或损坏的网页选集', () {
    for (final index in [-1, 1]) {
      expect(
        () => HtmlHomePlayback.parse({
          'url': 'https://fixture.invalid/movie.mp4',
          'options': {
            'playlist': {
              'id': 'list',
              'selected': index,
              'episodes': [
                {'title': '一集'},
              ],
            },
          },
        }),
        throwsFormatException,
      );
    }
  });

  test('库关闭重开后保留 HTML 和用户状态，不再依赖原文件路径', () async {
    store.writeLocalState(source.id, {
      'storage': {'theme': 'dark'},
    });
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    store = await WebHomeStore.open();
    expect(store.items.single.html, html);
    expect(store.items.single.url, isEmpty);
    expect(store.readLocalState(source.id)['storage'], {'theme': 'dark'});
  });
}
