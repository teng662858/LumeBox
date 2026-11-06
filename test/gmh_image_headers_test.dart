import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/image_pipeline.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  for (final host in ['https://g-mh.org', 'https://m.g-mh.org']) {
    test('正文图片携带当前站点请求头，避免图床200提示图：$host', () async {
      expect(available, isTrue);
      enableEngineOnThisPlatform();
      final engine = await LumeJsEngine.create(
        sourceId: 'gmh-header-${host.contains("m.g-")}',
        section: Section.comic,
        http: LumeHttp(
          source: 'gmh-test',
          client: MockClient(
            (request) async => http.Response(
              request.url.path.startsWith('/manga/')
                  ? '<h1>元尊</h1><div id="mangachapters" data-mid="93"></div>'
                  : jsonEncode({
                      'code': 200,
                      'data': {
                        'info': {
                          'images': {'line': 2, 'images': 'fixture'},
                        },
                      },
                    }),
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(engine.dispose);
      // This regression isolates image headers; the real packed-page decoder is
      // covered separately by the snapshot test and live chapter comparison.
      final baseScript = File('sources/comic/gmh.js').readAsStringSync();
      final script =
          '$baseScript\n'
          'LumeSource.__decode = async function () { return [{url:"/comic/Y/test/1.webp"}]; };';
      expect(await engine.loadScript(script), isTrue);
      await engine.applySourceConfig({'domain': host});
      final result = await engine.callResult('content', {
        'id': 'yuanzun-weitianchuanmei',
        'chapterId': '1197418',
      });
      expect(result.isOk, isTrue, reason: result.error?.message);
      final content = ChapterContent.parse(result.value) as ImageContent;
      expect(content.imageHeaders[content.images.first]!['Referer'], '$host/');
      expect(
        content.imageHeaders[content.images.first]!['User-Agent'],
        contains('iPhone OS 18_0'),
      );
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final warning = Uint8List.fromList([9, 9]);
      final pipeline = SectionImagePipeline(
        cacheDir: '',
        diskCache: false,
        maxRetries: 0,
        requestSender: (request) async => NetworkResponse(
          statusCode: 200,
          body: request.headers['Referer'] == '$host/' ? original : warning,
          headers: const {},
        ),
      );
      addTearDown(pipeline.dispose);
      pipeline.configureImageHeaders(content.imageHeaders);
      expect(
        await pipeline.bytes(content.images.first),
        orderedEquals(original),
        reason: '不能把200状态的提示图当作正文',
      );
    });
  }
}
