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

/// 18禁漫源：用**实时抓下来的页面快照**跑生产调用链（脚本载入 → HTTP 桥接 →
/// 数据源适配 → 统一内容模型）。站点临时不可达不会让契约回归失效。
///
/// 快照取自 2026-10-08 的真实响应（snapshots/jm18_*.html）。这里守的是几件
/// **不看真页面就发现不了**的事：
///   1. 列表 / 搜索 / 首页板块三套标记同源（li.hl-list-item），封面**只在
///      data-original 里**——读 src 会整列空封面；
///   2. 分页真的翻得动：第 2 页走 `/page/2`，两条 id 不重叠；
///   3. 目录里的章节 hash 是 20/22 位**混用**的（长目录那部 327 话），
///      按固定长度写死会少解析一半；章节 id 必须是完整章节地址（content 直接取）；
///   4. 详情页标题的收尾标签被站点写坏成 `</h2>`——按 `</h1>` 收尾会一条都解析不出；
///   5. 正文只认 data-original：页面里还有 yandex 统计像素与 JuicyAds 广告块，
///      整页抓 `<img>` 会把它们收进阅读器。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言。
    Qjs.reclaimRuntime = false;
  }

  /// 引擎不可用 / 本机没拉脚本与快照缓存 → 跳过（不是失败）。
  /// 脚本与快照都在 https://github.com/teng662858/LumeBox-Sources，
  /// 本机先跑 `dart run tool/fetch_sources.dart`。
  String? skipUnless(List<String> names) => Qjs.isAvailable
      ? _skipUnless(names)
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  /// 本用例登记过的地址就是「脚本应当请求的地址」：没登记的一律 404
  /// （地址拼错 = 拉取失败，一眼看得出来，不会静默返回空列表）。
  Map<String, String> snapshots() => <String, String>{
        'https://18jm18.com/': _read('jm18_home.html'),
        'https://18jm18.com/comic-lists/all/ob/time/st/all': _read('jm18_list.html'),
        'https://18jm18.com/comic-lists/all/ob/time/st/all/page/2':
            _read('jm18_list_p2.html'),
        'https://18jm18.com/cata.php?key=%E7%A7%98%E5%AF%86': _read('jm18_search.html'),
        'https://18jm18.com/read-comics/668691.html': _read('jm18_detail.html'),
        'https://18jm18.com/read-comics/668691/aCWTKFSGbSEDrAULSNdanS.html':
            _read('jm18_chapter.html'),
      };

  const assets = <String>[
    'jm18_comic.js',
    'jm18_home.html',
    'jm18_list.html',
    'jm18_list_p2.html',
    'jm18_search.html',
    'jm18_detail.html',
    'jm18_chapter.html',
  ];

  test(
    '18禁漫：首页板块 / 分类 / 列表翻页 / 搜索 / 详情 / 目录 / 正文（快照）',
    () async {
      final http = _SnapshotHttp(get: snapshots());
      final source = await _boot(
        _script('jm18_comic.js'),
        section: Section.comic,
        http: http,
      );
      addTearDown(source.dispose);

      // ---- 首页：站点自己的 5 个板块，每块 12 条，「更多」是站点自己的地址。
      final home = await source.data.home();
      expect(home.isBoards, isTrue, reason: '站点首页是横滑板块（不是平铺列表）');
      expect(home.boards.length, 5, reason: '首页板块（热门/最近更新/新上架/站长推荐/已完结）');
      expect(
        home.boards.map((board) => board.title).toList(),
        <String>['热门漫画', '最近更新', '新上架漫画', '站长推荐', '已完结漫画'],
      );
      expect(home.boards.every((board) => board.items.length == 12), isTrue);
      expect(home.boards.first.moreUrl, '/hot-comics');
      expect(
        home.boards.last.moreUrl,
        '/comic-lists/all/ob/time/st/completed',
        reason: '板块「更多」转发站点自己写的地址（这里站点写的是不带前导斜杠的相对路径）',
      );
      expect(
        home.boards.every((board) => board.items.every((item) =>
            item.cover != null && item.cover!.startsWith('https://'))),
        isTrue,
        reason: '封面只在 data-original 里（读 src 会整块空封面）',
      );

      // ---- 分类：从列表页自己的筛选条实时读（分类 / 进度 / 排序三组，按 id 去重）。
      final categories = await source.data.categories();
      expect(categories.length, 8);
      expect(categories.first.id, '/comic-lists/all/ob/time/st/all');
      expect(categories.first.title, '全部');
      expect(
        categories.firstWhere((category) => category.title == '韩漫').id,
        '/comic-lists/韩漫/ob/time/st/all',
        reason: 'id 是站点自己的路径（中文裸写），list() 里再自己百分号编码',
      );
      expect(
        categories.map((category) => category.title).toList(),
        <String>['全部', '韩漫', '日漫', '真人', '3D漫画', '连载中', '已完结', '按阅读'],
      );

      // ---- 列表：24 条/页，id 是作品路径，封面 https，副标题是日期。
      final page1 = await source.data.list(categoryId: 'all');
      expect(page1.items.length, 24);
      expect(page1.hasMore, isTrue, reason: '分页器里有 /page/2 … /page/128');
      final idPattern = RegExp(r'/read-comics/\d+\.html$');
      for (final item in page1.items) {
        expect(idPattern.hasMatch(item.id), isTrue, reason: '条目 id：${item.id}');
        expect(item.title, isNotEmpty);
        expect(
          item.cover,
          allOf(isNotNull, startsWith('https://')),
          reason: 'iOS 禁明文 http，封面必须是 https',
        );
      }
      expect(
        page1.items.map((item) => item.id).toSet().length,
        24,
        reason: '同页 id 不应重复',
      );

      // ---- 翻页：第 2 页走 /page/2，和第一页**不是同一批**（快照是两页真实响应）。
      final page2 = await source.data.list(categoryId: 'all', page: 2);
      expect(page2.items.length, 24);
      expect(page2.hasMore, isTrue);
      final first = page1.items.map((item) => item.id).toSet();
      final second = page2.items.map((item) => item.id).toSet();
      expect(
        first.intersection(second),
        isEmpty,
        reason: '第 1 页与第 2 页 id 不应重叠（重叠说明分页没真的翻）',
      );

      // ---- 搜索：走站点表单自己的 /cata.php?key=…（关键词按 UTF-8 百分号编码）。
      final search = await source.data.list(keyword: '秘密');
      expect(search.items.length, 24);
      expect(search.hasMore, isTrue, reason: '搜索结果 3 页（分页器 /comics-find/秘密/page/2、3）');
      expect(
        search.items.first.title,
        '大学女生宿舍的秘密',
        reason: '关键词真的传下去了（地址不对这里会是 404 或空列表）',
      );

      // ---- 详情：标题的收尾标签被站点写坏成 </h2>（只能匹配开始标签）。
      const comicPath = '/read-comics/668691.html';
      final detail = await source.data.detail(comicPath);
      expect(detail, isNotNull);
      expect(detail!.title, '秘密教学');
      expect(detail.cover, isNotNull);
      expect(detail.cover!.startsWith('https://'), isTrue);
      expect(detail.subtitle, '作者：美娜讚钢铁王');
      expect(detail.description, contains('阿姨与姊姊们决定给纯洁的子豪'));

      // ---- 目录：327 话（20 位与 22 位 hash 混用），按话数升序，id 是完整章节地址。
      final chapters = await source.data.chapters(comicPath);
      expect(chapters.length, 327);
      expect(
        chapters.map((chapter) => chapter.id).toSet().length,
        327,
        reason: '章节 id 不应重复',
      );
      expect(
        chapters.every((chapter) =>
            chapter.id.startsWith('https://18jm18.com/read-comics/668691/')),
        isTrue,
        reason: '章节 id 用完整章节地址（{hash} 只能从详情页解析出来，content 直接取）',
      );
      expect(chapters.first.title, startsWith('第1话'));
      expect(chapters.last.title, startsWith('第322話'));
      final numbers = <int>[];
      for (final chapter in chapters) {
        final match = RegExp(r'第\s*(\d+)\s*[话話]').firstMatch(chapter.title);
        if (match != null) numbers.add(int.parse(match.group(1)!));
      }
      expect(numbers.length, 322, reason: '另外 5 条是停刊/休刊公告（没有话数）');
      for (var i = 1; i < numbers.length; i++) {
        expect(
          numbers[i],
          greaterThan(numbers[i - 1]),
          reason: '目录必须按话数升序（站点里第250話排在第251話之后，已重排）',
        );
      }
      // 公告条目（没有话数）留在原位、不被丢掉：快照里是「停刊公告 / 停刊一周公告 /
      // 停刊公告0 / 休刊公告00」这 4 条。
      final announcements = chapters
          .where((chapter) => !RegExp(r'第\s*\d+\s*[话話]').hasMatch(chapter.title))
          .toList();
      expect(
        announcements.length,
        5,
        reason: '解析不出话数的公告条目保留（不是被丢掉）：'
            '${announcements.map((chapter) => chapter.title).toList()}',
      );

      // ---- 正文：只认 data-original（yandex 像素与 JuicyAds 广告不进正文）。
      final content = await source.data.content(
        itemId: comicPath,
        chapterId: chapters.first.id,
      );
      expect(content, isA<ImageContent>());
      final images = (content! as ImageContent).images;
      expect(images.length, 55);
      expect(
        images.every((url) => url.startsWith('https://')),
        isTrue,
        reason: '正文图片必须 https',
      );
      expect(
        images.any((url) => url.contains('yandex') || url.contains('jads')),
        isFalse,
        reason: 'yandex 统计像素 / JuicyAds 是裸 <img>/<ins>，只认 data-original 才不会收进来',
      );
      expect(images.toSet().length, 55, reason: '同一章不应出现重复图');
      expect(images.first, contains('20240506052219724.jpg'));
      expect(images.last, contains('20240506052247483.jpg'));

      // 宿主 fetch 只把字符串原样交给网络层：脚本发的地址必须都是绝对地址
      // （相对路径在真机上就是「拉取失败：HTTP 404 /comic-lists/…」）。
      for (final url in http.seenHeaders.keys) {
        expect(url.startsWith('https://'), isTrue, reason: '脚本请求了相对地址：$url');
      }
      expect(
        http.seenHeaders.keys.toSet(),
        unorderedEquals(<String>{
          'https://18jm18.com/',
          'https://18jm18.com/comic-lists/all/ob/time/st/all',
          'https://18jm18.com/comic-lists/all/ob/time/st/all/page/2',
          'https://18jm18.com/cata.php?key=%E7%A7%98%E5%AF%86',
          'https://18jm18.com/read-comics/668691.html',
          'https://18jm18.com/read-comics/668691/aCWTKFSGbSEDrAULSNdanS.html',
        }),
        reason: '本用例只需要这 6 个地址（中文题材路径按 UTF-8 转义，搜索走 cata.php）',
      );
    },
    skip: skipUnless(assets),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// 读一份缓存里的资产（脚本或站点快照）。
///
/// 用例的 skip 条件理应保证它存在；真缺了就抛一句点名的话——
/// 不要变成一句 `Null check operator used on a null value`（那种失败读不出问题）。
String _read(String file) {
  // 两种调用都认：传文件名（在缓存里找）或传已经解析好的路径（_script 的返回值）。
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

/// 脚本路径（本机没拉缓存时用例会被 skip，不会走到这里）。
String _script(String name) => sourceScriptPath(name)!;

/// 用例需要的资产（脚本 + 站点快照）都在本机才跑；缺哪个就点名哪一个。
String? _skipUnless(List<String> names) {
  for (final name in names) {
    if (sourceAssetPath(name) == null) return sourceScriptsSkipReason(name);
  }
  return null;
}

Future<_BootedSource> _boot(
  String scriptPath, {
  required Section section,
  required LumeHttp http,
}) async {
  final script = _read(scriptPath);
  final host = LumeSourceHost(
    http,
    timeout: const Duration(seconds: 5),
    section: section,
    sourceId: 'snapshot',
  );
  final sandbox = LumeSandbox.create(
    id: host.expectedSandboxId,
    policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
    host: host,
    polyfills: LumeSourcePolyfills.forSection(section),
  );
  final loaded = await sandbox.load(script);
  expect(loaded.isOk, isTrue, reason: '脚本必须能载入: $scriptPath: ${loaded.error}');
  return _BootedSource(
    data: JsDataSource(
      id: 'snapshot',
      name: 'snapshot',
      section: section,
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

/// 只回快照里登记过的 GET 地址；未登记的返回 404（于是「请求到了别的地址」
/// 会以拉取失败的形式暴露出来，而不是静默返回空）。
class _SnapshotHttp extends LumeHttp {
  _SnapshotHttp({this.get = const <String, String>{}}) : super();

  final Map<String, String> get;

  /// 本次运行里每个地址收到过的请求头（断言「该带的头带上了」用）。
  final Map<String, Map<String, String>> seenHeaders =
      <String, Map<String, String>>{};

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    // 宿主签名里的「读满上限就断开」（探测型请求用，见 network_queue 的 maxBytes）。
    int? maxBytes,
    Duration? timeout,
  }) async {
    seenHeaders[url] = headers ?? const <String, String>{};
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

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'list', 'detail', 'chapters', 'content', 'home'};
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

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
