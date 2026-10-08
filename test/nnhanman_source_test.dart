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

/// 鸟鸟韩漫（nnhanman）：用**真机抓下来的页面快照**跑生产调用链
/// （脚本载入 → HTTP 桥接 → 数据源适配 → 统一内容模型）。
///
/// 快照取自 2026-10-09 的真实响应（snapshots/nnhanman_*.html）。这里守的是四件
/// **不看真页面就发现不了**的事：
///   1. 列表条目形状（`a.ImgA` + `span.info` + `<picture>` 里的 `<img src>`）：
///      作品 slug 是拼音、大多没有数字，旧版「链接里要有 2 位以上数字」的猜法
///      一条列表只能认出 2 条、封面全是空；
///   2. 分页：`?page=N` 站点不认（回第 1 页），只有路径式 `/page/N` 有效；
///      hasMore 由 `.pagination-wrap` 里的页码决定——第 1 页有、末页（147）没有；
///   3. 目录：全局 chapter id 不是话数（86184 是第 28 話），必须按 `第N話` 文案
///      重排成升序；且要跳过「开始阅读」按钮（它的 href 就是第 1 话）与
///      「热门推荐」里的空占位 `/comic/<slug>/chapter-.html`；
///   4. 列表地址必须是**绝对地址**（宿主 fetch 不认相对路径），不然第一次翻分类
///      就是 404。
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

  test(
    '鸟鸟韩漫：列表 / 分页 / 首页板块 / 搜索（快照）',
    () async {
      final http = _SnapshotHttp(get: <String, String>{
        'https://nnhanman.net/comics': _read('nnhanman_catalog.html'),
        'https://nnhanman.net/': _read('nnhanman_home.html'),
        'https://nnhanman.net/comics/all/ob/time/st/all': _read('nnhanman_list.html'),
        'https://nnhanman.net/comics/all/ob/time/st/all/page/2': _read('nnhanman_list_p2.html'),
        'https://nnhanman.net/comics/all/ob/time/st/all/page/147': _read('nnhanman_list_last.html'),
        // 分类 id 是中文题材名：脚本必须把它百分号转义后拼进路径
        // （站点自己的分页链接就是 /comics/%E6%AD%A3%E5%A6%B9/… 这个形状；
        //   原始中文字节会让站点回一张乱码空页，实测 0 条）。
        'https://nnhanman.net/comics/%E6%AD%A3%E5%A6%B9/ob/time/st/all':
            _read('nnhanman_list.html'),
        'https://nnhanman.net/update': _read('nnhanman_update.html'),
        'https://nnhanman.net/ranking': _read('nnhanman_ranking.html'),
        'https://nnhanman.net/search/%E5%A5%B3': _read('nnhanman_search.html'),
        'https://nnhanman.net/search/%E5%A5%B3/page/2': _read('nnhanman_search_p2.html'),
      });
      final source = await _boot(
        _script('nnhanman_comic.js'),
        section: Section.comic,
        http: http,
      );
      addTearDown(source.dispose);

      // 分类：站点自己的「全部」+ 中文题材名（id 就是题材名）。
      final categories = await source.data.categories();
      expect(categories.length, 21);
      expect(categories.first.id, 'all');
      expect(categories.first.title, '全部');
      expect(
        categories.map((category) => category.id),
        contains('正妹'),
        reason: '/comics 的题材链接是 /comics/正妹/ob/time/st/all，id 要原样收下',
      );

      // 列表第 1 页：18 条，每条都要有封面与 /comic/… 的 id。
      final page1 = await source.data.list(categoryId: 'all', page: 1);
      expect(page1.items.length, greaterThanOrEqualTo(15));
      for (final item in page1.items) {
        expect(item.id, contains('/comic/'), reason: '条目 id 是作品页地址');
        expect(item.id, endsWith('.html'));
        expect((item.cover ?? ''), isNotEmpty, reason: '封面不能为空（旧版每条都空）');
        expect(
          item.cover!.startsWith('https://'),
          isTrue,
          reason: 'iOS 禁明文 http，封面必须是 https',
        );
        expect(item.title, isNotEmpty);
      }
      expect(page1.items.first.title, '慾債');
      expect(page1.items.first.subtitle, isNotEmpty, reason: '分类页副标题是更新时间');
      expect(page1.hasMore, isTrue, reason: '第 1 页的分页器里有 /page/2 与 尾页 147');

      // 第 2 页：地址必须是路径式 /page/2（`?page=2` 站点会回第 1 页），内容不同。
      final page2 = await source.data.list(categoryId: 'all', page: 2);
      expect(page2.items.length, greaterThanOrEqualTo(15));
      final firstIds = page1.items.map((item) => item.id).toSet();
      expect(
        page2.items.any((item) => firstIds.contains(item.id)),
        isFalse,
        reason: '第 2 页必须真的是下一页（`?page=` 会被站点忽略，回第 1 页）',
      );

      // 末页（147）：分页器里最大的页码就是当前页 → 没有下一页。
      final last = await source.data.list(categoryId: 'all', page: 147);
      expect(last.items.length, greaterThanOrEqualTo(15));
      expect(last.hasMore, isFalse, reason: '末页分页器最大只到 146，不能报「还有下一页」');

      // 分类 id 原样落进路径：命中快照即证明地址拼对了（拼错会 404）。
      final genre = await source.data.list(categoryId: '正妹', page: 1);
      expect(genre.items.length, greaterThanOrEqualTo(15));

      // 整表页：/update、/ranking 是另一套 .itemBox 标记，且**没有分页器**。
      final update = await source.data.list(categoryId: 'update', page: 1);
      expect(update.items.length, greaterThanOrEqualTo(40));
      expect(update.items.first.cover, isNotEmpty);
      expect(update.hasMore, isFalse, reason: '/update 没有分页器，不去猜一个 404 地址');
      final ranking = await source.data.list(categoryId: 'ranking', page: 1);
      expect(ranking.items.length, greaterThanOrEqualTo(90));
      expect(ranking.hasMore, isFalse);
      final updatePage2 = await source.data.list(categoryId: 'update', page: 2);
      expect(updatePage2.items, isEmpty);
      expect(
        http.seen.contains('https://nnhanman.net/update/page/2'),
        isFalse,
        reason: '整表页的第 2 页不该发请求（站点上就是 404）',
      );

      // 搜索：站点的表单是 GET /catalog.php?key=，它渲染的正是 /search/<kw> 这一页
      // （实测逐条相同）；站点自己的分页链接写的是 /search/<kw>/page/N，所以走 /search。
      final search = await source.data.list(keyword: '女', page: 1);
      expect(search.items.length, greaterThanOrEqualTo(15));
      expect(search.hasMore, isTrue);
      final searchPage2 = await source.data.list(keyword: '女', page: 2);
      expect(searchPage2.items.length, greaterThanOrEqualTo(15));
      expect(
        searchPage2.items.any((item) => item.id == search.items.first.id),
        isFalse,
      );

      // 首页：站点自己的五块（最近更新 / 新书发布 / 热门漫画 / 推荐漫画 / 已完结），
      // 每块 9 条，封面同样要有。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 5);
      expect(home.boards.first.title, '最近更新');
      expect(home.boards.first.items.length, greaterThanOrEqualTo(6));
      expect(home.boards.first.items.first.title, '慾債');
      expect(home.boards.first.moreUrl, isNotNull, reason: '「更多」要能跳到可翻页的列表');
      for (final board in home.boards) {
        expect(board.items, isNotEmpty, reason: '板块「${board.title}」不该是空的');
        expect(board.items.first.cover, isNotEmpty);
      }

      // 宿主 fetch 只把字符串原样交给网络层：脚本发的地址必须都是绝对地址
      // （相对路径在真机上就是「拉取失败：HTTP 404 /comics/…」）。
      for (final url in http.seen) {
        expect(
          url.startsWith('https://'),
          isTrue,
          reason: '脚本请求了相对地址：$url',
        );
      }
    },
    skip: skipUnless(<String>[
      'nnhanman_comic.js',
      'nnhanman_catalog.html',
      'nnhanman_home.html',
      'nnhanman_list.html',
      'nnhanman_list_p2.html',
      'nnhanman_list_last.html',
      'nnhanman_update.html',
      'nnhanman_ranking.html',
      'nnhanman_search.html',
      'nnhanman_search_p2.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '鸟鸟韩漫：详情 / 目录升序 / 正文图片（快照）',
    () async {
      const slug = 'https://nnhanman.net/comic/yu-zhai.html';
      final http = _SnapshotHttp(get: <String, String>{
        slug: _read('nnhanman_detail.html'),
        // 章节页地址是 `/comic/<slug>/chapter-<id>.html`——不要把作品页的 `.html` 带进来。
        'https://nnhanman.net/comic/yu-zhai/chapter-86184.html':
            _read('nnhanman_chapter.html'),
      });
      final source = await _boot(
        _script('nnhanman_comic.js'),
        section: Section.comic,
        http: http,
      );
      addTearDown(source.dispose);

      // 详情：标题在 <h1>《慾債》</h1>（去书名号）；页面里没有 og: 标签，
      // 封面固定在 id="Cover" 里（站标 logo.png 与统计像素排在它前面，「第一张图」抓不得）。
      final detail = await source.data.detail(slug);
      expect(detail, isNotNull);
      expect(detail!.title, '慾債');
      expect(detail.cover, isNotNull);
      expect(detail.cover, contains('thumb.niaopic.com'));
      expect(detail.cover!.startsWith('https://'), isTrue);
      expect(detail.description, isNotNull);
      expect(detail.description!.length, greaterThan(50), reason: '简介在 p.txtDesc');
      expect(detail.subtitle, contains('Appeal'), reason: '作者在 p.txtItme 行里');

      // 目录：站点单页给全且**最新一话在前**（第 28 話 → 第 1 話），
      // App 期望升序——按 `第N話` 文案重排（地址里的 86184 是全局 id，不是话数）。
      final chapters = await source.data.chapters(slug);
      expect(chapters.length, 28);
      expect(chapters.map((chapter) => chapter.id).toSet().length, 28);
      expect(
        chapters.first.title,
        startsWith('第1話'),
        reason: '第 1 話要排在首位：站点把「开始阅读」按钮（href 就是第 1 话）'
            '排在目录之前，先到先得会把第 1 话占成「开始阅读」并挤到末尾',
      );
      expect(chapters.first.id, endsWith('chapter-83267.html'));
      expect(chapters.last.title, startsWith('第28話'));
      expect(chapters.last.id, endsWith('chapter-86184.html'));
      final numbers = chapters
          .map((chapter) => int.tryParse(
                RegExp(r'第(\d+)話').firstMatch(chapter.title)?.group(1) ?? '',
              ))
          .toList();
      expect(numbers, List<int>.generate(28, (index) => index + 1),
          reason: '目录必须严格升序 1..28（阅读器的「下一章」按这个顺序走）');
      expect(
        chapters.every((chapter) => !chapter.title.contains('开始阅读')),
        isTrue,
        reason: '「开始阅读」是按钮，不是一话',
      );

      // 正文：这一页没有分页（`next` 出现 0 次），211 张 data-src 去重后 209 张。
      // 用目录里升序后的**最后一话**（第 28 話 / chapter-86184）——快照就是它那一页。
      final content = await source.data.content(
        itemId: slug,
        chapterId: chapters.last.id,
      );
      expect(content, isA<ImageContent>());
      final images = (content! as ImageContent).images;
      expect(images.length, greaterThanOrEqualTo(20));
      expect(images.toSet().length, images.length, reason: '图片地址要去重');
      expect(
        images.every((url) => url.startsWith('https://')),
        isTrue,
        reason: '正文图片也必须升级到 https',
      );
      expect(images.first, contains('new.niaopic.com'));
    },
    skip: skipUnless(<String>[
      'nnhanman_comic.js',
      'nnhanman_detail.html',
      'nnhanman_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// 读一份缓存里的资产（脚本或站点快照）。
///
/// 用例的 skip 条件理应保证它存在；真缺了就抛一句点名的话——
/// 不要变成一句 `Null check operator used on a null value`（那种失败读不出问题）。
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

  /// 本次运行里收到过请求的地址（断言「地址拼对了 / 没多请求」用）。
  final Set<String> seen = <String>{};

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

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'home', 'list', 'detail', 'chapters', 'content'};

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
