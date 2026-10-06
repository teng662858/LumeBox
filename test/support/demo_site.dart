import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 测试用的「示例站点」：三份 LumeSource 示例脚本与 Venera 兼容层都用它。
///
/// 接口形状按各脚本头部注释里写的约定提供（小说 / 漫画 / 视频三个板块的数据
/// 分支由 id 前缀区分：`n-` 小说、`v-` 视频、其余当漫画）。放在 support 下是
/// 为了让「示例源脚本」与「Venera 兼容层」两组用例共用同一个站点，
/// 站点行为只有一处定义。
/// 现场提供的示例站点：接口形状与三份示例脚本头部注释里写的约定一致。
class DemoSite {
  DemoSite._(this._server);

  final HttpServer _server;

  /// 关键路径的请求计数：用来证明「脚本真的去请求了站点」，以及缓存确实生效。
  final Map<String, int> _hits = <String, int>{};

  /// 收到过的查询参数（按到达顺序）：用来证明分页 / 搜索参数真的传到了站点。
  final List<Map<String, String>> queries = <Map<String, String>>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  int requestsTo(String path) => _hits[path] ?? 0;

  static Future<DemoSite> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = DemoSite._(server);
    server.listen(site._handle);
    return site;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    _hits[path] = (_hits[path] ?? 0) + 1;
    queries.add(request.uri.queryParameters);
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
    final category = request.uri.queryParameters['category'] ?? '';
    final keyword = request.uri.queryParameters['keyword'] ?? '';
    final query = request.uri.queryParameters;

    if (path == '/api/categories') {
      return _json(request, <String, Object?>{
        'categories': <Object?>[
          <String, Object?>{'id': 'c1', 'title': '分类一'},
          <String, Object?>{'id': 'c2', 'title': '分类二'},
        ],
      });
    }

    if (path == '/api/list') {
      final scope = keyword.isNotEmpty
          ? '搜索：$keyword'
          : (category.isNotEmpty ? '分类：$category' : '最新');
      return _json(request, <String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'id': 'n-1',
            'title': '$scope · 示例小说 $page',
            'cover': '$baseUrl/img/n-1.jpg',
            'subtitle': '示例站 · 第 $page 页',
          },
          <String, Object?>{
            'id': 'n-2',
            'title': '$scope · 示例小说 $page-2',
            'cover': '$baseUrl/img/n-2.jpg',
            'subtitle': '示例站 · 第 $page 页',
          },
        ],
        'hasMore': page < 3,
      });
    }

    if (path == '/api/vod' || path == '/api/vod-search') {
      final scope = keyword.isNotEmpty
          ? '搜索：$keyword'
          : (category.isNotEmpty ? '分类：$category' : '最新');
      return _json(request, <String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'id': 'v-1',
            'title': '$scope · 示例影片 $page',
            'cover': '$baseUrl/img/v-1.jpg',
            'subtitle': '示例站 · 第 $page 页',
          },
        ],
        'hasMore': page < 3,
      });
    }

    if (path == '/api/search') {
      return _json(request, <String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'id': 'n-9',
            'title': '搜索：$keyword · 第 $page 页',
            'subtitle': '搜索命中',
          },
        ],
        'hasMore': false,
      });
    }

    if (path == '/api/detail') {
      final id = query['id'] ?? '';
      return _json(request, <String, Object?>{
        'item': <String, Object?>{
          'id': id,
          'title': id.startsWith('n-') ? '示例小说 $id' : '示例漫画 $id',
          'cover': '$baseUrl/img/$id.jpg',
          'subtitle': id.startsWith('n-') ? '连载中 · 示例站' : '连载中 · 示例站',
          'description': '由本地示例站点提供的 ${id.startsWith('n-') ? '小说' : '漫画'}详情。',
        },
      });
    }

    if (path == '/api/chapters') {
      final id = query['id'] ?? '';
      // 视频板块的「章节」是线路 + 集数；其余板块是章 / 话。
      final titles = id.startsWith('v-')
          ? <String>['线路 1 · 第 1 集', '线路 1 · 第 2 集']
          : (id.startsWith('n-')
              ? <String>['第一章', '第二章', '第三章']
              : <String>['第 1 话', '第 2 话']);
      return _json(request, <String, Object?>{
        'chapters': <Object?>[
          for (var index = 0; index < titles.length; index++)
            <String, Object?>{
              'id': '${id.startsWith('v-') ? 'ep' : 'ch'}-${index + 1}',
              'title': titles[index],
            },
        ],
      });
    }

    if (path == '/api/content') {
      final id = query['id'] ?? '';
      final chapterId = query['chapterId'] ?? '';
      if (chapterId == 'missing') {
        // 故意给一个「不存在」的章节，用于验证错误链路。
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (id.startsWith('v-')) {
        return _json(request, <String, Object?>{
          'url': 'https://cdn.example.com/$id/$chapterId.m3u8',
          'headers': <String, Object?>{'Referer': '$baseUrl/'},
        });
      }
      if (id.startsWith('n-')) {
        return _json(request, <String, Object?>{
          'text': '（$chapterId）示例正文：这一章由本地示例站点提供。',
        });
      }
      return _json(request, <String, Object?>{
        'images': <Object?>[
          for (var index = 1; index <= 3; index++)
            '$baseUrl/img/$id/$chapterId-$index.jpg',
        ],
      });
    }

    if (path == '/page/list.html') {
      // 漫画列表页：HTML 结构固定，等价于真实站点的列表页。
      final html = '''
<html><body><div class="list">
  <a class="item" href="/comic/12" data-id="12"><img src="/img/12.jpg" alt="示例漫画 A"/></a>
  <a class="item" href="/comic/13" data-id="13"><img src="/img/13.jpg" alt="示例漫画 B"/></a>
</div></body></html>''';
      request.response.headers.contentType = ContentType.html;
      request.response.write(html);
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _json(HttpRequest request, Object body) {
    request.response.headers.contentType = ContentType.json;
    request.response.add(Uint8List.fromList(utf8.encode(jsonEncode(body))));
    unawaited(request.response.close());
  }
}
