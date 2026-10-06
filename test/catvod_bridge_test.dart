import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/cat_engines.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/util/lume_log.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

/// 自建聚合服务桥接（CatVod / TVBox）的端到端验证。
///
/// 背景（用户实测）：订阅 `9280.kstore.vip/cat/index.js.md5` 导入失败。
/// 拉下来逐字节核对过 MD5（订阅链路本身正常），并**在本机把它真的跑了起来**：
/// 它是 **CatVodSpiderios** —— 一个自建 HTTP 服务端（167 条路由、监听 9988、
/// `/full-config` 返回 94 个站点），不是图源脚本。
///
/// 这类包在 iOS 上装不了（文档明令禁止 Node / 端口 / 进程），但架构文档给过
/// 出路：**远端 Node 代理模式** —— 服务跑在电脑 / NAS 上，App 侧用薄壳脚本
/// 经宿主网络层转发。本文件验证那份薄壳（`catvod_bridge_source.js`）。
///
/// 测试用一个**本地替身服务端**复刻 CatVod 的接口形状（`/full-config` +
/// `/spider/<key>/<type>/{home,category,detail,play,search}`），因此不需要真机
/// 也不需要联网，跑起来是确定性的。真实服务端的实测结论写在文档里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  HttpOverrides? savedOverrides;
  late Directory root;
  late _FakeCatVodServer server;

  setUp(() async {
    enableEngineOnThisPlatform();
    // 本组用例要连本机回环上的替身服务端：先摘掉 flutter_test 的「一律 400」替身。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('lume_box_catvod');
    await installTempSectionRoot(root);
    CatEngines.debugPlatformOverride = 'ios';
    server = await _FakeCatVodServer.start();
    LumeLog.clear();
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    await server.stop();
    HttpOverrides.global = savedOverrides;
    CatEngines.debugPlatformOverride = null;
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 把薄壳脚本的 BASE_URL 指到替身服务端（等价于用户填自己的电脑地址）。
  String scriptFor() => fixture('catvod_bridge_source.js').replaceFirst(
        "var BASE_URL = 'http://192.168.1.5:9988';",
        "var BASE_URL = '${server.baseUrl}';",
      );

  /// 走真实导入链路并打开数据源。
  Future<DataSource> importAndOpen() async {
    await ensureSectionScope(Section.cat);
    final manager = LumeSources.manager(Section.cat);
    final result = await manager.importScript(scriptFor());
    expect(result.isSuccess, isTrue, reason: result.message ?? '导入应成功');
    expect(result.descriptor!.id, 'catvod-bridge');
    final source = await LumeSources.open(Section.cat, 'catvod-bridge');
    expect(source, isNotNull, reason: '导入后应能打开数据源');
    return source!;
  }

  group('导入与身份', () {
    test(
      '薄壳脚本能导入猫源板块，板块自报为猫源',
      () async {
        await ensureSectionScope(Section.cat);
        final result =
            await LumeSources.manager(Section.cat).importScript(scriptFor());
        expect(result.isSuccess, isTrue, reason: result.message ?? '');
        expect(result.descriptor!.id, 'catvod-bridge');
        expect(result.descriptor!.name, contains('自建聚合服务桥接'));

        // 跨板块导入被拒（脚本自报 category=cat）。
        await ensureSectionScope(Section.novel);
        final rejected =
            await LumeSources.manager(Section.novel).importScript(scriptFor());
        expect(rejected.isSuccess, isFalse, reason: '猫源不该能进小说板块');
        expect(rejected.message, contains('跨板块'));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('契约：分类 / 列表 / 搜索 / 详情 / 选集', () {
    test(
      '分类来自「站点 · 栏目」两级拼接',
      () async {
        final source = await importAndOpen();
        final categories = await source.categories();

        expect(categories, isNotEmpty);
        // 站点名 + 栏目名拼成分类标题。
        expect(
          categories.map((item) => item.title),
          contains('玩偶|4K · 玩偶电影'),
        );
        expect(
          categories.map((item) => item.title),
          contains('玩偶|4K · 玩偶剧集'),
        );
        // 分类 id 是「站点key|栏目id」。
        expect(categories.first.id, 'wogg|1');

        // 服务端只暴露一个站点时，另一个站点的栏目不该混进来。
        expect(
          categories.every((item) => item.id.startsWith('wogg|')),
          isTrue,
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '列表：分页真的传给服务端，条目带站点前缀的 id',
      () async {
        final source = await importAndOpen();
        final page1 = await source.list(categoryId: 'wogg|1', page: 1);

        expect(page1.items, isNotEmpty);
        expect(page1.items.first.title, '一瞬之间');
        expect(
          page1.items.first.id,
          'wogg@/voddetail/132285.html',
          reason: 'id 必须带站点，否则回查详情时不知道去哪个站点',
        );
        expect(page1.items.first.subtitle, '更新至HD');
        expect(page1.hasMore, isTrue, reason: 'pagecount=168，第 1 页后面还有');

        // 分页参数真的发到了服务端。
        expect(server.lastCategoryQuery['page'], '1');
        final page3 = await source.list(categoryId: 'wogg|1', page: 3);
        expect(server.lastCategoryQuery['page'], '3');
        expect(page3.items, isNotEmpty);

        // 末页没有下一页。
        final last = await source.list(categoryId: 'wogg|1', page: 168);
        expect(last.hasMore, isFalse);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '搜索：关键词与页码都传给服务端',
      () async {
        final source = await importAndOpen();
        final result = await source.list(keyword: '庆余年', page: 1);

        expect(result.items, hasLength(2));
        expect(result.items.first.title, '庆余年 第一季');
        expect(server.lastSearchQuery['wd'], '庆余年');
        expect(server.lastSearchQuery['page'], '1');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '详情：标题 / 封面 / 副标题 / 简介都对上',
      () async {
        final source = await importAndOpen();
        final detail = await source.detail('wogg@/voddetail/132285.html');

        expect(detail, isNotNull);
        expect(detail!.title, '一瞬之间');
        expect(detail.cover, contains('gimg0.baidu.com'));
        expect(detail.subtitle, '更新至HD');
        expect(detail.description, isNotNull);
        // 详情请求打到的是正确的站点前缀。
        expect(server.lastDetailPath, '/spider/wogg/3/detail');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '选集：线路与剧集摊平成章节，标题带线路名',
      () async {
        final source = await importAndOpen();
        final chapters = await source.chapters('wogg@/voddetail/132285.html');

        expect(chapters, isNotEmpty);
        // 服务端给了两条线路，各自的剧集都要在。
        expect(
          chapters.first.title,
          startsWith('夸克原画 · '),
          reason: '第一条线路是「夸克原画」',
        );
        expect(
          chapters.map((item) => item.title).any((t) => t.startsWith('夸克极速 · ')),
          isTrue,
          reason: '第二条线路也要出现（线路 × 剧集全部摊平）',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('播放地址与错误提示', () {
    test(
      '播放：线路名与剧集 id 都正确回传给服务端',
      () async {
        final source = await importAndOpen();
        final chapters = await source.chapters('wogg@/voddetail/132285.html');
        final content = await source.content(
          itemId: 'wogg@/voddetail/132285.html',
          chapterId: chapters.first.id,
        );

        expect(content, isA<VideoContent>());
        expect(
          (content! as VideoContent).url.toString(),
          'https://cdn.example.com/play.m3u8',
        );
        // play 请求带的是线路**名**（服务端要 flag，不是下标）。
        expect(server.lastPlayBody['flag'], '夸克原画');
        expect(server.lastPlayBody['ep'], 'quark-ep-1');
        expect(server.lastPlayBody['id'], '/voddetail/132285.html');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '服务端返回 500（网盘未登录）：提示指向「去服务端配置中心登录」',
      () async {
        server.failPlay = true;
        final source = await importAndOpen();
        final chapters = await source.chapters('wogg@/voddetail/132285.html');

        await expectLater(
          () => source.content(
            itemId: 'wogg@/voddetail/132285.html',
            chapterId: chapters.first.id,
          ),
          throwsA(
            isA<SourceException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('网盘'),
                contains('配置中心'),
              ),
            ),
          ),
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '服务端不可达：提示说清「确认服务端已启动 / 同一局域网」',
      () async {
        final source = await importAndOpen();
        // 把服务端停掉，再取分类。
        await server.stop();

        await expectLater(
          () => source.categories(),
          throwsA(
            isA<SourceException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('连不上自建服务'),
                contains('同一局域网'),
              ),
            ),
          ),
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}

/// CatVod / TVBox 自建聚合服务端的**替身**：接口形状照实测的真实服务端复刻。
///
/// 真实服务端（CatVodSpiderios）实测形状：
/// - `GET  /full-config` → `{video:{sites:[{key,name,type,api,searchable,...}]}}`
/// - `POST /spider/<key>/<type>/home`     → `{class:[{type_id,type_name}]}`
/// - `POST /spider/<key>/<type>/category` → `{page,pagecount,list:[{vod_id,vod_name,vod_pic,vod_remarks}]}`
/// - `POST /spider/<key>/<type>/detail`   → `{list:[{vod_play_from,vod_play_url,...}]}`
/// - `POST /spider/<key>/<type>/play`     → `{url}`（网盘未登录时真实服务端返回 500）
/// - `POST /spider/<key>/<type>/search`   → `{page,pagecount,list:[...]}`
class _FakeCatVodServer {
  _FakeCatVodServer._(this._server);

  final HttpServer _server;

  /// 让 play 返回 500（模拟「网盘未登录」）。
  bool failPlay = false;

  Map<String, String> lastCategoryQuery = <String, String>{};
  Map<String, String> lastSearchQuery = <String, String>{};
  Map<String, Object?> lastPlayBody = <String, Object?>{};
  String lastDetailPath = '';

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeCatVodServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeCatVodServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await _readBody(request);

    if (path == '/full-config') {
      return _json(request, <String, Object?>{
        'video': <String, Object?>{
          'sites': <Object?>[
            <String, Object?>{
              'key': 'wogg',
              'name': '玩偶|4K',
              'type': 3,
              'api': '/spider/wogg/3',
              'enable': true,
              'searchable': 1,
            },
            // 一个「已停用」的站点：不该出现在分类里。
            <String, Object?>{
              'key': 'disabled',
              'name': '停用站',
              'type': 3,
              'api': '/spider/disabled/3',
              'enable': false,
              'searchable': 0,
            },
          ],
        },
      });
    }

    if (path == '/spider/wogg/3/home') {
      return _json(request, <String, Object?>{
        'class': <Object?>[
          <String, Object?>{'type_id': '1', 'type_name': '玩偶电影'},
          <String, Object?>{'type_id': '2', 'type_name': '玩偶剧集'},
        ],
      });
    }

    if (path == '/spider/wogg/3/category') {
      lastCategoryQuery = <String, String>{
        'id': '${body['id']}',
        'page': '${body['page']}',
      };
      final page = int.tryParse('${body['page']}') ?? 1;
      return _json(request, <String, Object?>{
        'page': page,
        'pagecount': 168,
        'list': <Object?>[
          <String, Object?>{
            'vod_id': '/voddetail/132285.html',
            'vod_name': '一瞬之间',
            'vod_pic': 'https://gimg0.baidu.com/img/a.webp',
            'vod_remarks': '更新至HD',
          },
          <String, Object?>{
            'vod_id': '/voddetail/132265.html',
            'vod_name': '大器晚成2025',
            'vod_pic': 'https://gimg0.baidu.com/img/b.webp',
            'vod_remarks': '更新至HD',
          },
        ],
      });
    }

    if (path == '/spider/wogg/3/search') {
      lastSearchQuery = <String, String>{
        'wd': '${body['wd']}',
        'page': '${body['page']}',
      };
      return _json(request, <String, Object?>{
        'page': 1,
        'pagecount': 1,
        'list': <Object?>[
          <String, Object?>{
            'vod_id': '/voddetail/76340.html',
            'vod_name': '庆余年 第一季',
            'vod_pic': 'https://gimg0.baidu.com/img/c.webp',
            'vod_remarks': '全46集',
          },
          <String, Object?>{
            'vod_id': '/voddetail/76341.html',
            'vod_name': '庆余年 第二季',
            'vod_pic': 'https://gimg0.baidu.com/img/d.webp',
            'vod_remarks': '全36集',
          },
        ],
      });
    }

    if (path == '/spider/wogg/3/detail') {
      lastDetailPath = path;
      return _json(request, <String, Object?>{
        'list': <Object?>[
          <String, Object?>{
            'vod_id': '/voddetail/132285.html',
            'vod_name': '一瞬之间',
            'vod_pic': 'https://gimg0.baidu.com/img/a.webp',
            'vod_remarks': '更新至HD',
            'vod_content': '阿根廷剧情片。',
            // 两条线路 × 各两集：验证摊平逻辑。
            'vod_play_from': '夸克原画\$\$\$夸克极速',
            'vod_play_url':
                '正片\$quark-ep-1#预告\$quark-ep-2\$\$\$正片\$fast-ep-1#预告\$fast-ep-2',
          },
        ],
      });
    }

    if (path == '/spider/wogg/3/play') {
      lastPlayBody = body;
      if (failPlay) {
        request.response.statusCode = HttpStatus.internalServerError;
        return _json(request, <String, Object?>{
          'statusCode': 500,
          'error': 'Internal Server Error',
          'message': "Unexpected token '\ufffd', \"\ufffd\ufffd\\u001du\ufffdZ\" is not valid JSON",
        });
      }
      return _json(request, <String, Object?>{'url': 'https://cdn.example.com/play.m3u8'});
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<Map<String, Object?>> _readBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (error) {
      // 非 JSON 体：按空处理（本组用例都发 JSON）。
    }
    return <String, Object?>{};
  }

  void _json(HttpRequest request, Object body) {
    request.response.headers.contentType = ContentType.json;
    request.response.add(Uint8List.fromList(utf8.encode(jsonEncode(body))));
    unawaited(request.response.close());
  }
}
