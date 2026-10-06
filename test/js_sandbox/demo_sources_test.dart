import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_home_page.dart';

import 'support/js_sandbox_support.dart';

/// 示例源脚本（小说 / 漫画 / 视频）的「导入 → 加载 → 展示」端到端验证。
///
/// 为什么要在本地起一个 HTTP 站点：这三份脚本是**真源**的写法（HTTP + 解析），
/// 而不是纯模拟数据。只有让它们真的去请求一个站点，才能证明整条链路是通的——
/// 脚本语法 → 沙箱桥接 → 宿主网络层 → 正则 / JSON 解析 → 适配器契约 → 页面渲染。
/// 站点由本文件的 [_DemoSite] 现场提供，端口随机，脚本里的 BASE_URL 在导入前
/// 被替换成它（等价于用户把自己的站点地址填进示例脚本）。
///
/// iOS 之外能跑的前提是 quickjs 原生桥可用（Windows 需先 `flutter build windows`），
/// 缺桥时整组跳过——与既有原生用例同一口径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  HttpOverrides? savedOverrides;
  late Directory root;
  late _DemoSite site;

  /// 读一份示例脚本，并把 BASE_URL 指到本地站点（等价于用户改示例脚本的地址）。
  String scriptFor(String file) => fixture(file).replaceFirst(
        "var BASE_URL = 'http://127.0.0.1:8080';",
        "var BASE_URL = '${site.baseUrl}';",
      );

  setUp(() async {
    enableEngineOnThisPlatform();
    // flutter_test 把进程内的 HttpClient 全量替换成「一律 400」的替身
    // （防单测意外联网）。本组用例**故意**要联网——连的是本机回环上的示例站，
    // 因此这里摘掉替身，测完再挂回去。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('lume_box_demo');
    await installTempSectionRoot(root);
    site = await _DemoSite.start();
    // 三份示例源先在**真实时钟**里导入好：`testWidgets` 的 fake-async 里
    // 等不到 sqlite / 原生编译这类真实异步（这是本仓库既有的测试口径）。
    for (final entry in <(String, Section)>[
      ('demo_novel_source.js', Section.novel),
      ('demo_comic_source.js', Section.comic),
      ('demo_video_source.js', Section.video),
    ]) {
      final (file, section) = entry;
      final result =
          await LumeSources.manager(section).importScript(scriptFor(file));
      if (!result.isSuccess) {
        throw StateError('示例源导入失败（${section.id}）：${result.message}');
      }
    }
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    await site.stop();
    HttpOverrides.global = savedOverrides;
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 导入示例脚本到指定板块，返回可直接驱动的数据源。
  ///
  /// 走**真实链路**：板块注册表落库 → 组合根打开引擎 → JS 数据源适配器。
  Future<DataSource> importAndOpen(String file, Section section) async {
    await ensureSectionScope(section);
    final manager = LumeSources.manager(section);
    final result = await manager.importScript(scriptFor(file));
    expect(result.isSuccess, isTrue, reason: result.message ?? '导入应成功');
    final source = await LumeSources.open(section, result.descriptor!.id);
    expect(source, isNotNull, reason: '导入后应能打开数据源');
    return source!;
  }

  group('小说示例源：JSON 接口 + 沙盒存储缓存', () {
    test(
      '分类（走缓存）/ 列表 / 搜索 / 详情 / 章节 / 正文 全链路',
      () async {
        final source = await importAndOpen('demo_novel_source.js', Section.novel);
        expect(source.name, contains('示例小说源'));
        expect(source.section, Section.novel);

        // 分类：第一次请求站点，第二次应命中沙盒存储（不再发请求）。
        final categories = await source.categories();
        expect(categories.map((item) => item.title), contains('分类一'));
        final requestsAfterFirst = site.requestsTo('/api/categories');
        expect(requestsAfterFirst, 1, reason: '首次取分类要请求站点');

        // 同一条数据源再取一次：走 LumeSource.fs 缓存。
        final again = await source.categories();
        expect(again.length, categories.length);
        expect(
          site.requestsTo('/api/categories'),
          1,
          reason: '第二次应命中沙盒存储缓存，不再打站点',
        );

        // 列表：分页 + hasMore。
        final page1 = await source.list(page: 1);
        expect(page1.items, isNotEmpty);
        expect(page1.hasMore, isTrue);
        expect(page1.items.first.title, contains('最新'));
        final page2 = await source.list(page: 2);
        expect(page2.items.first.title, contains('示例小说 2'),
            reason: '分页参数要真的传给站点（page=2）');

        // 分类过滤。
        final filtered = await source.list(categoryId: 'c1');
        expect(filtered.items.first.title, contains('分类：c1'));

        // 搜索：走 /api/search。
        final searched = await source.list(keyword: '剑');
        expect(searched.items.first.title, contains('搜索：剑'));
        expect(
          site.queries.any((query) => query['keyword'] == '剑'),
          isTrue,
          reason: '关键词要真的作为请求参数发到站点',
        );

        // 详情。
        final detail = await source.detail(page1.items.first.id);
        expect(detail?.title, isNotNull);
        expect(detail?.description, isNotNull);
        expect(detail?.cover, startsWith(site.baseUrl));

        // 章节。
        final chapters = await source.chapters('n-1');
        expect(chapters, hasLength(3));
        expect(chapters.first.title, '第一章');

        // 正文（小说板块：文本）。
        final content = await source.content(
          itemId: 'n-1',
          chapterId: chapters.first.id,
        );
        expect(content, isA<TextContent>());
        expect(
          (content! as TextContent).text,
          contains('ch-1'),
          reason: '正文按章节 id 取（脚本把 chapterId 传给了站点）',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '站点报错时抛出可读原因（不是静默空结果）',
      () async {
        final source = await importAndOpen('demo_novel_source.js', Section.novel);
        // 站点对未知章节返回 404 → 脚本抛「拉取失败：HTTP 404」。
        await expectLater(
          () => source.content(itemId: 'n-1', chapterId: 'missing'),
          throwsA(
            isA<SourceException>().having(
              (error) => error.message,
              'message',
              contains('404'),
            ),
          ),
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('漫画示例源：HTML 列表 + 图片正文', () {
    test(
      'HTML 正则解析列表 / 详情 / 章节 / 图片列表 全链路',
      () async {
        final source = await importAndOpen('demo_comic_source.js', Section.comic);
        expect(source.section, Section.comic);

        final categories = await source.categories();
        expect(categories, hasLength(3));

        final list = await source.list(page: 1);
        expect(list.items, hasLength(2), reason: '示例站列表页有两条');
        expect(list.hasMore, isTrue);
        expect(list.items.first.id, '12');
        expect(list.items.first.title, '示例漫画 A');
        expect(
          list.items.first.cover,
          startsWith(site.baseUrl),
          reason: 'HTML 里的相对地址要补成绝对地址',
        );

        final detail = await source.detail('12');
        expect(detail?.title, '示例漫画 12');
        expect(detail?.subtitle, contains('连载中'));

        final chapters = await source.chapters('12');
        expect(chapters, hasLength(2));
        expect(chapters.first.title, '第 1 话');

        final content = await source.content(
          itemId: '12',
          chapterId: chapters.first.id,
        );
        expect(content, isA<ImageContent>());
        final images = (content! as ImageContent).images;
        expect(images, hasLength(3), reason: '示例章节给了三张图');
        expect(images.first, startsWith(site.baseUrl));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('视频示例源：多线路 + 直链播放地址', () {
    test(
      '列表 / 搜索 / 选集 / 播放地址（含防盗链头）全链路',
      () async {
        final source = await importAndOpen('demo_video_source.js', Section.video);
        expect(source.section, Section.video);

        final list = await source.list(page: 1);
        expect(list.items, isNotEmpty);
        expect(list.items.first.title, contains('示例影片'));

        final searched = await source.list(keyword: '影片');
        expect(searched.items.first.title, contains('搜索：影片'));
        expect(
          site.queries.any((query) => query['keyword'] == '影片'),
          isTrue,
          reason: '搜索要打到视频自己的搜索接口',
        );
        expect(site.requestsTo('/api/vod-search'), 1);

        final chapters = await source.chapters(list.items.first.id);
        expect(chapters, hasLength(2));
        expect(chapters.first.title, contains('线路 1'));

        final content = await source.content(
          itemId: list.items.first.id,
          chapterId: chapters.first.id,
        );
        expect(content, isA<VideoContent>());
        final video = content! as VideoContent;
        expect(video.url.toString(), startsWith('https://'));
        expect(
          video.headers['Referer'],
          isNotNull,
          reason: '防盗链头要原样透传给播放内核',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('板块隔离：示例源脚本自带 category', () {
    test(
      '小说示例源导入漫画板块被拒（对照：导入小说板块成功）',
      () async {
        await ensureSectionScope(Section.comic);
        final comic = LumeSources.manager(Section.comic);
        final rejected = await comic.importScript(scriptFor('demo_novel_source.js'));
        expect(rejected.isSuccess, isFalse);
        expect(rejected.message, contains('跨板块'));
        expect(
          (await comic.list()).any((item) => item.id == 'demo-novel-json'),
          isFalse,
          reason: '被拒的源不落库（漫画板块里只有它自己的示例源）',
        );

        final novel = await importAndOpen('demo_novel_source.js', Section.novel);
        expect(novel.id, 'demo-novel-json');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('导入后在板块首页正常加载展示', () {
    /// 真实引擎 + 真实 HTTP 的调用链要经真实事件轮推进，`pumpAndSettle` 的假时钟
    /// 驱不动它：交替放行真实异步窗口与帧渲染，直到 [until] 成立（或轮数用尽）。
    Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
      for (var round = 0; round < 40; round++) {
        if (until != null && until()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
    }

    for (final entry in <(String, Section, String, String, String)>[
      // 文件、板块、首条条目文案、要点的分类、切换分类后应出现的文案
      ('demo_novel_source.js', Section.novel, '最新 · 示例小说 1', '分类一', '分类：c1'),
      // 漫画示例源的分类是「全部 / 连载中 / 已完结」，且列表走 HTML 抓取；
      // 点「连载中」而不是「全部」：页签自己也有一个「全部」（不过滤），会撞名。
      // 点的分类文案是「连载中」，脚本收到的 categoryId 是它在 categories()
      // 里声明的 'ongoing'——副标题把它带出来，正好证明分类真的传到了脚本。
      ('demo_comic_source.js', Section.comic, '示例漫画 A', '连载中',
          '示例漫画 · 第 1 页 · ongoing'),
      ('demo_video_source.js', Section.video, '最新 · 示例影片 1', '分类一', '分类：c1'),
    ]) {
      final (file, section, itemTitle, categoryLabel, afterTap) = entry;
      testWidgets(
        '${section.label}板块：源条显示已导入的源，列表渲染出条目并可按分类切换（$file）',
        (tester) async {
          await tester.binding.setSurfaceSize(const ui.Size(900, 1400));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: LumeTheme.build(),
              home: SourceHomePage(
                section: section,
                manager: LumeSources.manager(section),
              ),
            ),
          );

          // 首屏：源条 + 分类 + 列表条目（等待真实链路走完）。
          await settle(
            tester,
            until: () => find.text(itemTitle).evaluate().isNotEmpty,
          );
          expect(
            find.textContaining('示例'),
            findsWidgets,
            reason: '${section.label}：源条应显示示例源名称',
          );
          expect(
            find.text(itemTitle),
            findsOneWidget,
            reason: '${section.label}：列表应渲染出脚本从示例站取到的条目',
          );

          // 分类切换：同一条沙箱调用链再跑一次分类分支。
          expect(
            find.text(categoryLabel),
            findsOneWidget,
            reason: '${section.label}：分类来自脚本的 categories()',
          );
          await tester.tap(find.text(categoryLabel));
          await settle(
            tester,
            until: () => find.textContaining(afterTap).evaluate().isNotEmpty,
          );
          expect(
            find.textContaining(afterTap),
            findsWidgets,
            reason: '${section.label}：切分类后列表按所选分类重新解析',
          );

          // 收尾：先让在飞请求落地（否则连接会在关客户端之后才回到池里，又在假
          // 时钟上挂一个空转定时器），再关掉共享客户端收走那些 keep-alive 定时器。
          await settle(tester);
          LumeNet.closeSharedClientForTesting();
          await tester.pump();
        },
        skip: !available,
        timeout: const Timeout(Duration(seconds: 120)),
      );
    }
  });
}

/// 现场提供的示例站点：接口形状与三份示例脚本头部注释里写的约定一致。
class _DemoSite {
  _DemoSite._(this._server);

  final HttpServer _server;

  /// 关键路径的请求计数：用来证明「脚本真的去请求了站点」，以及缓存确实生效。
  final Map<String, int> _hits = <String, int>{};

  /// 收到过的查询参数（按到达顺序）：用来证明分页 / 搜索参数真的传到了站点。
  final List<Map<String, String>> queries = <Map<String, String>>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  int requestsTo(String path) => _hits[path] ?? 0;

  static Future<_DemoSite> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _DemoSite._(server);
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
