import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/source_scripts.dart';

/// 小说源的**列表封面 / 分类**回归（用户反馈：很多源「列表里封面空白」、「分类筛选不全」）。
///
/// 用 2026-10-16 真机（iPhone UA + 本地代理）抓下来的页面快照跑生产调用链，
/// 守的都是**不看真页面就发现不了**的事：
///   1. 中文成人小说网：列表封面原先取的是整块卡片容器的第一张 <img>（`n.parent`），
///      于是第 2 条起全都拿到同一条的封面 —— 这里断言 32 条封面各不相同；
///   2. 禁书阁：详情封面不能用「页面第一张图」兜底（那是站标 app_logo.png），
///      站点多数书本来没封面（empty.png 占位），要如实给 null；
///   3. 小黄书小说：分页必须走路径式（`?page=2` 站点会忽略、回第 1 页），
///      分类是站点 `/fiction-tag/N` 的整套题材（原先只给了 1 个「最新小说」）；
///   4. X小说：分类从站点导航实时读（原先写死 8 个，站点有 52 个）；
///   5. 夜读小说：分类补上只在工具条里出现的 `audio`（有声小说）；
///   6. 色文网：分类名后面站点自己拖的收录数（`都市激情 (22445)`）要抹掉。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言。
    Qjs.reclaimRuntime = false;
  }

  /// 引擎不可用 / 本机没拉脚本与快照缓存 → 跳过（不是失败）。
  String? skipUnless(List<String> names) => Qjs.isAvailable
      ? _skipUnless(names)
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '中文成人小说网：分类列表每条封面各不相同（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://www.aaccoo.com/': _read('novel_aaccoo_list.html'),
        'https://www.aaccoo.com/category/18':
            _read('novel_aaccoo_category.html'),
        'https://www.aaccoo.com/book/20091/':
            _read('novel_aaccoo_detail.html'),
      });
      final source = await _boot(_script('中文成人小说网.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 13, reason: '最新 + 站点导航里的 12 个分类');
      expect(categories[1].id, '/category/18');

      final page = await source.data.list(categoryId: '/category/18', page: 1);
      expect(page.items.length, 32);
      final covers = page.items.map((item) => item.cover).toList();
      expect(
        covers.where((c) => c == null || c!.isEmpty),
        isEmpty,
        reason: '分类页每条都有封面（旧版取容器第一张，除首条外全被覆盖成同一张）',
      );
      expect(
        covers.toSet().length,
        covers.length,
        reason: '32 条封面必须两两不同 —— 有重复就说明又退回「取容器第一张」了',
      );
      expect(
        covers.every((c) => c!.startsWith('https://')),
        isTrue,
        reason: 'iOS 禁明文 http',
      );
      expect(page.items.first.title, '我也要觉醒血脉开后宫吗');
      expect(
        page.items.first.coverHeaders['Referer'],
        'https://www.aaccoo.com/',
        reason: '封面要带站点 Referer',
      );

      final detail = await source.data.detail('/book/20091/');
      expect(detail, isNotNull);
      expect(
        detail!.cover,
        'https://static.aaccoo.com/file/cover/1168298369555238912.webp',
      );
    },
    skip: skipUnless(<String>[
      '中文成人小说网.js',
      'novel_aaccoo_list.html',
      'novel_aaccoo_category.html',
      'novel_aaccoo_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '禁书阁：分类 18 个栏目 / 占位封面不冒用站标（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://jinshuge.net/index.php/book/category/list/1?page=1':
            _read('novel_jinshuge_category.html'),
        'https://jinshuge.net/book?page=1': _read('novel_jinshuge_list.html'),
        'https://jinshuge.net/index.php/book/info/jinjizhilian':
            _read('novel_jinshuge_detail.html'),
      });
      final source = await _boot(_script('禁书阁.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 19, reason: '全部 + 站点书库 18 个栏目');
      expect(categories.first.id, '/book');
      expect(
        categories.map((c) => c.id),
        containsAll(<String>[
          '/index.php/book/category/list/1', // 穿越
          '/index.php/book/category/list/2', // 异能
          '/index.php/book/category/list/17', // 耽美
          '/index.php/book/category/list/18', // 职场
        ]),
        reason: '首页图标宫格只列 14 个，少了这 4 条（它们在首页只剩没文字的「更多」箭头）',
      );
      expect(categories[1].title, '穿越');

      // 分类列表：`.lazy` 图的真地址在 data-src，src 是 loading 占位；
      // 站点多数书没封面（empty.png 占位）→ 如实 null，别把占位图当封面。
      final page = await source.data.list(
        categoryId: '/index.php/book/category/list/1',
        page: 1,
      );
      expect(page.items.length, 20);
      expect(
        page.items.every((item) => item.cover == null || item.cover!.startsWith('https://')),
        isTrue,
      );

      // 首页「热门推荐」板块有真封面（图床 aabook.xyz），必须保留下来。
      final home = await source.data.list(page: 1);
      final real = home.items.where((item) => item.cover != null).toList();
      expect(real, isNotEmpty, reason: '首页有 10 条真封面（aabook.xyz），不能全丢');
      expect(
        real.every((item) => item.cover!.contains('aabook.xyz')),
        isTrue,
      );

      // 详情：站点没有 og:image，且 app_logo.png 排在封面之前——
      // 兜底「页面第一张图」会把站标当封面（实测踩过）。
      final detail =
          await source.data.detail('/index.php/book/info/jinjizhilian');
      expect(detail, isNotNull);
      expect(
        detail!.cover,
        isNull,
        reason: '这本书没有封面（empty.png 占位），不能拿站标 app_logo.png 顶上',
      );
    },
    skip: skipUnless(<String>[
      '禁书阁.js',
      'novel_jinshuge_category.html',
      'novel_jinshuge_list.html',
      'novel_jinshuge_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '小黄书小说：题材分类 23 个 + 路径式分页（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://xchina.co/fictions': _read('novel_xchina_list.html'),
        'https://xchina.co/fictions/2': _read('novel_xchina_list_p2.html'),
        'https://xchina.co/fiction-tag/1': _read('novel_xchina_tag.html'),
        'https://xchina.co/fiction/6ad1e7916d4b7':
            _read('novel_xchina_detail.html'),
        'https://xchina.co/fiction/6ad1e7916d4b7/1':
            _read('novel_xchina_chapter.html'),
      });
      final source = await _boot(_script('小黄书小说.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 24, reason: '最新小说 + `/fiction-tag/N` 23 个题材');
      expect(categories.first.id, '/fictions');
      expect(categories[1].id, '/fiction-tag/1');
      expect(categories[1].title, '人妻女友');

      final page1 = await source.data.list(page: 1);
      expect(page1.items.length, 20);
      expect(
        page1.items.any((item) => item.cover == null),
        isTrue,
        reason: '`upload.xchina.io/default/fiction.jpg` 是无封面占位，要如实给 null',
      );
      expect(
        page1.items.first.cover,
        'https://upload.xchina.io/fiction/6ad1e79977aa3.jpg',
      );
      expect(page1.hasMore, isTrue, reason: '分页器上有 rel="next"');

      // `?page=2` 站点会忽略、回第 1 页；只有 `/fictions/2` 是真的第 2 页。
      final page2 = await source.data.list(page: 2);
      expect(
        http.seen.contains('https://xchina.co/fictions/2'),
        isTrue,
        reason: '第 2 页必须走路径式 `/fictions/2`',
      );
      expect(
        page2.items.any((item) => item.id == page1.items.first.id),
        isFalse,
        reason: '第 2 页不能还是第 1 页的内容',
      );

      final tag = await source.data.list(categoryId: '/fiction-tag/1', page: 1);
      expect(
        http.seen.contains('https://xchina.co/fiction-tag/1'),
        isTrue,
      );
      expect(tag.items.length, 20);

      final detail = await source.data.detail('/fiction/6ad1e7916d4b7');
      expect(detail, isNotNull);
      expect(detail!.title, '少妇的肛鸣');
      expect(detail.cover, 'https://upload.xchina.io/fiction/6ad1e79977aa3.jpg');

      final chapters = await source.data.chapters('/fiction/6ad1e7916d4b7');
      expect(chapters.length, 30);
    },
    skip: skipUnless(<String>[
      '小黄书小说.js',
      'novel_xchina_list.html',
      'novel_xchina_list_p2.html',
      'novel_xchina_tag.html',
      'novel_xchina_detail.html',
      'novel_xchina_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'X小说：分类从导航实时读（52 个，不再写死 8 个）（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://book.xn--x-ny6am91b6ug0se.com/books':
            _read('novel_xxiaoshuo_list.html'),
        'https://book.xn--x-ny6am91b6ug0se.com/category/49':
            _read('novel_xxiaoshuo_category.html'),
      });
      final source = await _boot(_script('X小说.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 53, reason: '全部 + 站点导航里的 52 个分类');
      expect(categories.first.id, 'books');
      expect(categories[1].id, 'category-1');
      expect(categories[1].title, '短篇情色小说');
      expect(
        categories.map((c) => c.id),
        containsAll(<String>['category-23', 'category-48', 'category-52']),
        reason: '旧版写死的 8 个之外，导航里的分类都要在',
      );

      final list = await source.data.list(categoryId: 'books', page: 1);
      expect(list.items.length, greaterThanOrEqualTo(20));

      final category = await source.data.list(categoryId: 'category-49', page: 1);
      expect(
        http.seen.contains(
          'https://book.xn--x-ny6am91b6ug0se.com/category/49',
        ),
        isTrue,
        reason: 'category-N 要拼成站点的 /category/N',
      );
      expect(category.items.length, greaterThanOrEqualTo(20));
    },
    skip: skipUnless(<String>[
      'X小说.js',
      'novel_xxiaoshuo_list.html',
      'novel_xxiaoshuo_category.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '夜读小说：分类补上 audio（有声）（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://x-novel.com/': _read('novel_xnovel_home.html'),
        'https://x-novel.com/novels': _read('novel_xnovel_list.html'),
      });
      final source = await _boot(_script('夜读小说.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 15, reason: '全部 + 首页 13 个药丸 + audio');
      expect(categories.first.id, 'all');
      expect(
        categories.map((c) => c.id),
        contains('audio'),
        reason: '`audio` 只在顶部工具条/区块标题里，class 不是 home-tag-pill，按药丸抓会漏',
      );
      expect(categories.firstWhere((c) => c.id == 'audio').title, '有声');

      final list = await source.data.list(categoryId: 'all', page: 1);
      expect(list.items.length, greaterThanOrEqualTo(20));
      expect(
        list.items.every((item) => (item.cover ?? '').isNotEmpty),
        isTrue,
        reason: '封面取 img[src]（站点没用懒加载占位）',
      );
    },
    skip: skipUnless(<String>[
      '夜读小说.js',
      'novel_xnovel_home.html',
      'novel_xnovel_list.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '色文网：分类名去掉站点自带的收录数（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://www.book18.org/': _read('novel_book18_list.html'),
      });
      final source = await _boot(_script('色文网.js'), http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 29, reason: '最新 + 28 个分类');
      expect(categories[1].id, '/category/15');
      expect(
        categories[1].title,
        '都市激情',
        reason: '站点锚点文本是「都市激情 (22445)」，收录数不是分类名',
      );
      expect(
        categories.every((c) => !RegExp(r'[（(]\s*\d').hasMatch(c.title)),
        isTrue,
      );
    },
    skip: skipUnless(<String>['色文网.js', 'novel_book18_list.html']),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '未改动的源（爱丽丝书屋 / 少数派文库 / H图书馆 / CA小说）不回归（快照）',
    () async {
      // 这几个源的列表页站点本身就没有封面（列表是纯文字 .txt-list /
      // common-bookele，H图书馆整站无图，99xs 列表 article 里没有 <img>）——
      // 守住的是「别因为上游改动把列表解析改坏」，不是封面。
      final cases = <String, Map<String, String>>{
        '爱丽丝书屋.js': <String, String>{
          'https://www.alicesw.com/all/order/update_time+desc.html?page=1':
              'novel_alicesw_list.html',
          'https://www.alicesw.com/': 'novel_alicesw_home.html',
        },
        '少数派文库.js': <String, String>{
          // 不传分类时脚本退回「首页最新」，所以首页也要登记（否则 404）。
          'https://sspwk.vip/': 'novel_sspwk_home.html',
          'https://sspwk.vip/booksort/10/1.html': 'novel_sspwk_category.html',
        },
        'H图书馆.js': <String, String>{
          'https://hlib.cc/n': 'novel_hlib_list.html',
        },
        'CA小说.js': <String, String>{
          'https://99xs.sbs/enter': 'novel_99xs_list.html',
        },
      };
      for (final entry in cases.entries) {
        final http = _SnapshotHttp(get: <String, String>{
          for (final item in entry.value.entries) item.key: _read(item.value),
        });
        final source = await _boot(_script(entry.key), http: http);
        addTearDown(source.dispose);
        final categories = await source.data.categories();
        expect(categories, isNotEmpty, reason: '${entry.key} 分类不应为空');
        final page = await source.data.list(page: 1);
        expect(
          page.items,
          isNotEmpty,
          reason: '${entry.key} 列表第 1 页不应为空',
        );
      }
    },
    skip: skipUnless(<String>[
      '爱丽丝书屋.js',
      '少数派文库.js',
      'H图书馆.js',
      'CA小说.js',
      'novel_alicesw_list.html',
      'novel_alicesw_home.html',
      'novel_sspwk_category.html',
      'novel_hlib_list.html',
      'novel_99xs_list.html',
    ]),
    timeout: const Timeout(Duration(seconds: 180)),
  );
}

/// 读一份缓存里的资产（脚本或站点快照）。
String _read(String file) {
  final direct = File(file);
  if (direct.existsSync()) return direct.readAsStringSync();
  final path = sourceAssetPath(file);
  if (path == null) {
    throw StateError(
      '缓存里没有 $file：跳过条件漏了这个文件？'
      '（先跑 `dart run tool/fetch_sources.dart`）',
    );
  }
  return File(path).readAsStringSync();
}

String _script(String name) => sourceScriptPath(name)!;

String? _skipUnless(List<String> names) {
  for (final name in names) {
    if (sourceAssetPath(name) == null) return sourceScriptsSkipReason(name);
  }
  return null;
}

Future<_BootedSource> _boot(String scriptPath, {required LumeHttp http}) async {
  final script = _read(scriptPath);
  final host = LumeSourceHost(
    http,
    timeout: const Duration(seconds: 5),
    section: Section.novel,
    sourceId: 'snapshot',
  );
  final sandbox = LumeSandbox.create(
    id: host.expectedSandboxId,
    policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
    host: host,
    polyfills: LumeSourcePolyfills.forSection(Section.novel),
  );
  final loaded = await sandbox.load(script);
  expect(loaded.isOk, isTrue, reason: '脚本必须能载入: $scriptPath: ${loaded.error}');
  return _BootedSource(
    data: JsDataSource(
      id: 'snapshot',
      name: 'snapshot',
      section: Section.novel,
      runtime: _SandboxRuntime(sandbox),
    ),
    dispose: () {
      sandbox.dispose();
      host.dispose();
    },
  );
}

class _BootedSource {
  _BootedSource({required this.data, required this.dispose});

  final JsDataSource data;
  final void Function() dispose;
}

/// 只回快照里登记过的 GET 地址；未登记的返回 404（「请求到了别的地址」会
/// 以拉取失败的形式暴露出来，而不是静默返回空）。
class _SnapshotHttp extends LumeHttp {
  _SnapshotHttp({this.get = const <String, String>{}}) : super();

  final Map<String, String> get;

  final Set<String> seen = <String>{};

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    int? maxBytes,
    Duration? timeout,
  }) async {
    seen.add(url);
    final response = get[url];
    if (response == null) {
      return LumeHttpResponse(
        statusCode: 404,
        body: Uint8List.fromList(utf8.encode('not found: $url')),
        headers: const <String, String>{},
      );
    }
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(response)),
      headers: const <String, String>{'content-type': 'text/html'},
    );
  }
}

class _SandboxRuntime implements JsSourceRuntime {
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'home', 'list', 'detail', 'chapters', 'content'};

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
}

DynamicLibrary? _resolveBridge() {
  if (!Platform.isWindows) {
    try {
      return DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (!file.existsSync()) continue;
    try {
      return DynamicLibrary.open(file.absolute.path);
    } catch (_) {
      continue;
    }
  }
  return null;
}
