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
  test('真实QuickJS：慢详情仍回填封面，懒加载图片被解析且详情结果复用', () async {
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
      expect(item['cover'], 'https://images.test/book.webp');
      expect(
        (item['coverHeaders'] as Map)['Referer'],
        'https://www.alicesw.com/',
      );
      expect(details, 1);
      final detail = await engine.call('detail', {'id': '123'}) as Map;
      expect(detail['cover'], 'https://images.test/book.webp');
      final count = details;
      final again = await engine.call('list', {'page': 1}) as Map;
      expect(
        ((again['items'] as List).single as Map)['cover'],
        detail['cover'],
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
