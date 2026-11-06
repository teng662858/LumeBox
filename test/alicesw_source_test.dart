import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  for (final challenge in [false, true]) {
    test('限流不会误报CF，真实挑战仍保留验证提示：challenge=$challenge', () async {
      expect(available, isTrue);
      enableEngineOnThisPlatform();
      final engine = await LumeJsEngine.create(
        sourceId: 'alice-challenge-$challenge',
        section: Section.comic,
        http: LumeHttp(
          client: MockClient(
            (_) async => http.Response(
              challenge ? '<title>Just a moment</title>' : 'Too many requests',
              challenge ? 403 : 429,
              headers: {'content-type': 'text/html; charset=utf-8'},
            ),
          ),
          source: 'alice-check',
        ),
      );
      try {
        expect(
          await engine.loadScript(
            File('sources/comic/alicesw.js').readAsStringSync(),
          ),
          isTrue,
        );
        final result = await engine.callResult('list', {'page': 1});
        expect(result.isOk, isFalse);
        expect(
          result.error!.message.contains('NEED_WEBVIEW_VERIFY'),
          challenge,
        );
      } finally {
        engine.dispose();
      }
    });
  }

  test('普通403自动选择已知镜像并在下次请求复用，不要求点网页视图', () async {
    expect(available, isTrue);
    enableEngineOnThisPlatform();
    var primary = 0;
    final engine = await LumeJsEngine.create(
      sourceId: 'alice-mirror',
      section: Section.comic,
      http: LumeHttp(
        client: MockClient((request) async {
          if (request.url.host == 'www.alicesw.com') {
            primary++;
            return http.Response('Access Denied'.padRight(500), 403);
          }
          final body = request.url.path.startsWith('/novel/')
              ? '<h1>测试</h1><div class="imgbox"><img src="https://images.test/a.webp"></div>'
              : '<li><span class="s2"><a href="/novel/123.html">测试</a></span></li>';
          return http.Response(
            body.padRight(500),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
        source: 'alice-mirror',
      ),
    );
    try {
      expect(
        await engine.loadScript(
          File('sources/comic/alicesw.js').readAsStringSync(),
        ),
        isTrue,
      );
      for (var i = 0; i < 2; i++) {
        final result = await engine.callResult('list', {'page': 1});
        expect(result.isOk, isTrue, reason: result.error?.message);
        expect(
          (((result.value as Map)['items'] as List).single as Map)['cover'],
          'https://www.alicesw1.homes/novel/123.html',
        );
      }
      expect(primary, 1);
    } finally {
      engine.dispose();
    }
  });

  test('真实QuickJS：列表不等待慢详情，封面使用按需定位页', () async {
    expect(available, isTrue);
    enableEngineOnThisPlatform();
    var details = 0;
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/novel/')) {
        details++;
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        return http.Response(
          '<h1>测试小说</h1><div class="imgbox extra"><a><img src="/placeholder.png" data-src="//images.test/book.webp"></a></div>'
              .padRight(500),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }
      return http.Response(
        '<li><span class="s2"><a href="/novel/123.html">测试小说</a></span><span class="s5">作者</span></li>'
            .padRight(500),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final engine = await LumeJsEngine.create(
      sourceId: 'alice-cover-test',
      section: Section.comic,
      http: LumeHttp(client: client, source: 'alice-test'),
    );
    try {
      expect(
        await engine.loadScript(
          File('sources/comic/alicesw.js').readAsStringSync(),
        ),
        isTrue,
      );
      final firstResult = await engine.callResult('list', {'page': 1});
      expect(firstResult.isOk, isTrue, reason: firstResult.error?.message);
      final first = firstResult.value as Map;
      final item = (first['items'] as List).single as Map;
      expect(item['cover'], 'https://www.alicesw.com/novel/123.html');
      expect(
        (item['coverHeaders'] as Map)['x-lume-image-page-selector'],
        '.imgbox img',
      );
      expect(
        (item['coverHeaders'] as Map)['Referer'],
        'https://www.alicesw.com/',
      );
      expect(details, 0, reason: '列表不能逐本请求详情');
      final detail = await engine.call('detail', {'id': '123'}) as Map;
      expect(detail['cover'], 'https://images.test/book.webp');
      final count = details;
      final again = await engine.call('list', {'page': 1}) as Map;
      expect(
        ((again['items'] as List).single as Map)['cover'],
        'https://www.alicesw.com/novel/123.html',
      );
      expect(
        (((again['items'] as List).single as Map)['coverHeaders']
            as Map)['Referer'],
        'https://www.alicesw.com/',
      );
      expect(details, count, reason: '已获取的封面复用缓存，不再逐条请求详情');
    } finally {
      engine.dispose();
    }
  });
}
