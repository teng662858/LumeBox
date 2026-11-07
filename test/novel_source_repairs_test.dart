import 'dart:convert';
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
  Future<LumeJsEngine> engine(String name, String Function(Uri) page) async {
    expect(available, isTrue);
    enableEngineOnThisPlatform();
    final runtime = await LumeJsEngine.create(
      sourceId: 'repair-$name',
      section: Section.comic,
      http: LumeHttp(
        source: 'repair-$name',
        client: MockClient(
          (r) async => http.Response(
            page(r.url),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      ),
    );
    addTearDown(runtime.dispose);
    final folder = name == 'miaobo' ? 'video' : 'comic';
    expect(
      await runtime.loadScript(
        File('sources/$folder/$name.js').readAsStringSync(),
      ),
      isTrue,
    );
    return runtime;
  }

  test('69书吧正文解码空格与数字实体，保留段落和正常标点', () async {
    final runtime = await engine(
      '69shuba',
      (_) =>
          '<div class="txtnav"><h1>测试</h1><div id="txtright">广告</div>'
          '&emsp;&emsp;第一段。<br><br>&amp;emsp;&amp;ensp;第二段&#x3002;<br>&#8195;&#8195;第三段 &amp; 标点。<div class="contentadv">广告</div></div>',
    );
    final result =
        await runtime.call('content', {'id': '1', 'chapterId': '1/2'}) as Map;
    expect(result['text'], '第一段。\n第二段。\n第三段 & 标点。');
  });

  test('次元姬推荐只取真实书籍，栏目和活动不冒充书籍', () async {
    final props = {
      'regionList': [
        {
          'regionId': 1,
          'id': 1,
          'name': '布局',
          'childList': [
            {
              'regionId': 2,
              'id': 2,
              'name': '推荐',
              'recomContentList': [
                {
                  'resourceType': '3',
                  'contentId': 9,
                  'contentName': '活动',
                  'imgUrl': '/banner.png',
                },
                {
                  'resourceType': '1',
                  'resourceId': 8476,
                  'contentName': '示例书',
                  'imgUrl': '//img.ciyuanji.com/cover.jpg',
                },
              ],
            },
          ],
        },
      ],
    };
    final runtime = await engine(
      'ciyuanji',
      (_) =>
          '<script id="__NEXT_DATA__" type="application/json">${jsonEncode({
            'props': {'pageProps': props},
          })}</script>',
    );
    final boards = await runtime.call('home') as List;
    final item = ((boards.single as Map)['items'] as List).single as Map;
    expect(item['id'], '8476');
    expect(item['cover'], 'https://img.ciyuanji.com/cover.jpg');
  });

  test('八叉书库 normal-image 封面卡不会只取第一本', () async {
    final runtime = await engine(
      '8csk',
      (_) =>
          '<div class="normal-image1 big-image1"><a href="/novel1/" title="示例一"><img src="https://img.8xsk.top/one.webp"></a></div>'
          '<div class="normal-image1 big-image2"><a href="/novel2/" title="示例二"><img src="https://img.8xsk.top/two.webp"></a></div>',
    );
    final result = await runtime.call('list', {'page': 1}) as Map;
    final items = result['items'] as List;
    expect(items.map((e) => (e as Map)['id']), ['1', '2']);
    expect(items.map((e) => (e as Map)['cover']), [
      'https://img.8xsk.top/one.webp',
      'https://img.8xsk.top/two.webp',
    ]);
  });

  test('月亮小说不把作者头像误作作品封面', () async {
    final runtime = await engine(
      'yueliang',
      (_) =>
          '<article class="novel-card"><a class="novel-card-cover" href="/novel/series/1"><span class="cover-placeholder"></span></a>'
          '<h3 class="novel-card-title"><a href="/novel/series/1">示例</a></h3><img class="avatar" src="/avatar.png"></article>',
    );
    final result = await runtime.call('list', {'page': 1}) as Map;
    expect(((result['items'] as List).single as Map)['cover'], '');
  });

  test('月亮小说复用详情目录首页，超过60页的长目录不截断', () async {
    var firstRequests = 0;
    String card(int id) =>
        '<article class="novel-card"><h3 class="novel-card-title">'
        '<a href="/novel/show/$id">第$id章</a></h3></article>';
    final runtime = await engine('yueliang', (uri) {
      final page = int.parse(uri.queryParameters['p'] ?? '1');
      if (page == 1) firstRequests++;
      return '<h1>长篇小说</h1>${card(page)}'
          '<a href="/novel/series/1?p=61">末页</a>';
    });
    await runtime.call('detail', {'id': 'series:1'});
    final chapters = await runtime.call('chapters', {'id': 'series:1'}) as List;
    expect(firstRequests, 1);
    expect(chapters, hasLength(61));
    expect((chapters.last as Map)['id'], 'show:61');
  });

  test('月亮小说目录分页失败明确报错，不悄悄丢章', () async {
    final runtime = await engine('yueliang', (uri) {
      if (uri.queryParameters['p'] == '2') throw StateError('offline');
      return '<article class="novel-card"><h3 class="novel-card-title">'
          '<a href="/novel/show/1">第1章</a></h3></article>'
          '<a href="/novel/series/1?p=2">末页</a>';
    });
    final result = await runtime.callResult('chapters', {'id': 'series:1'});
    expect(result.isOk, isFalse);
    expect(result.error?.message, contains('目录第 2 页加载失败'));
  });

  test('秒播真实QuickJS解开两层页面并传递封面解码与站点播放路径', () async {
    final html =
        '<a href="/index.php/vod/type/id/3.html">栏目甲</a><a href="/index.php/vod/type/id/4.html">栏目乙</a>'
        '<li class="content-item"><a href="/index.php/vod/detail/id/123.html"><img src="https://img.test/a.txt"><p>示例</p></a></li>'
        '<a href="/index.php/vod/type/id/3/page/2.html">下一页</a>'
        '<meta name="keywords" content="示例剧情介绍-重复">'
        '<a href="/index.php/vod/play/id/123/sid/1/nid/1.html">国内线路</a>';
    final wrapped = base64Encode(utf8.encode(base64Encode(utf8.encode(html))));
    final runtime = await engine(
      'miaobo',
      (_) =>
          "<script>var str = '$wrapped ';document.write(strDecode(str));</script>",
    );
    expect(await runtime.call('categories'), hasLength(2));
    final list =
        await runtime.call('list', {'page': 1, 'categoryId': '3'}) as Map;
    expect(list['hasMore'], isTrue);
    expect(
      (((list['items'] as List).single as Map)['coverHeaders']
          as Map)['x-lume-image-encoding'],
      'xor-base64',
    );
    final detail = await runtime.call('detail', {'id': '123'}) as Map;
    expect(detail['title'], '示例');
    final chapters = await runtime.call('chapters', {'id': '123'}) as List;
    final content = await runtime.call('content', {
      'chapterId': (chapters.single as Map)['id'],
    }) as Map;
    expect(content['kind'], 'webplayer');
    expect(
      content['url'],
      'https://edge-ov12.00h.quest/index.php/vod/play/id/123/sid/1/nid/1.html',
    );
  });
}
