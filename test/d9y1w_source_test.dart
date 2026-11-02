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

/// 四色视频（www.y1c5w.top）：maomi 模板成人站，用真站点快照在 **QuickJS 沙箱**里跑。
///
/// 站点两层编码，本源全靠脚本自己解（沙箱没有 atob / Buffer / crypto）：
///   1. 标题 / 分类名 / 菜单链接是 AES-256-CBC（key、iv 在 `/assets/js/common/encrypt.js`，
///      iv 只有 10 字节 + 固定后缀 `883346`）——这个用例跑的是纯 JS AES-256 实现，
///      解出来必须是真中文，且首条要与快照一致；
///   2. 卡片 href 是 `/cYc` + base64(明文路径)，菜单 `data-link` 在 2026-10-30 又套了一层 AES
///      （解开仍是 `/cYc...`）；解出来的明文路径脚本只用来取 id/channel，
///      不再拼混淆链接；搜索打 `/search/<频道>-<词>-<页>.html` 三个频道各一次。
///
/// 还守着封面、线路与换域名自愈：
///   3. 封面不能用站点图片主机（`base4s.0827.la` 回的是 `data:image/...` 文本），
///      要落到媒体 CDN（2026-11-02 起是 4sv.0827.la / s4.dt188.site）上的真 JPEG；
///   4. 站点 play 页给的线路会换域名，`content()` 要探活后交回能播的那台，
///      用户点「线路二」也不能拿到死地址；
///   5. 站点 3 天换一次域名，旧域只剩「进入页」（302 到 /enter/index.html）。
///      脚本要认出这种页面形态并自动换镜像（见第二个用例）；
///   6. 全部已知域名都只剩进入页时，脚本去问站方跳转服务 good.0827.la，
///      读 `reply.url`（跟随 302 后的最终地址）拿到当前域名（见第三个用例）。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  String? skipUnless(List<String> names) => Qjs.isAvailable
      ? _skipUnless(names)
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  const assets = <String>[
    '四色视频.js',
    'd9y1w_home.html',
    'd9y1w_list.html',
    'd9y1w_play.html',
    'd9y1w_search_juqing.json',
    'd9y1w_search_shipin.json',
    'd9y1w_search_jingpin.json',
  ];

  // 媒体 CDN：站点 play 页里那条 m3u8 相对路径挂到实测可用的 s4.dt188.site 上
  // （内置顺序是 4sv.0827.la → s4.dt188.site，用例只给 s4 开路由，
  //  顺便验证第一台探不通时会继续往下走）
  const m3u8 =
      'https://s4.dt188.site/videos/202610/28/6ae0eb981d9e3a98b9e2a6d8/088d87/index.m3u8';

  test(
    '四色视频：AES 标题 / 分类 / 列表 / 搜索 / 详情 / 双线路（站点快照）',
    () async {
      final http = _RouteHttp(<String, String>{
        '/index/home.html': _read('d9y1w_home.html'),
        '/juqing/lists.html': _read('d9y1w_list.html'),
        '/juqing/play-438819.html': _read('d9y1w_play.html'),
        // 只有实测能用的媒体 CDN 回视频；站点给的 www.0734.la / s5.sanheyiliao.xyz 一律 404，
        // 用来验证 content() 会探活并回落到能播的那台。
        'https://s4.dt188.site/videos/202610/28/6ae0eb981d9e3a98b9e2a6d8/088d87/index.m3u8':
            '#EXTM3U\n#EXT-X-VERSION:3\n',
        '/search/juqing-%E9%BA%BB%E8%B1%86-1.html':
            _read('d9y1w_search_juqing.json'),
        '/search/shipin-%E9%BA%BB%E8%B1%86-1.html':
            _read('d9y1w_search_shipin.json'),
        '/search/jingpin-%E9%BA%BB%E8%B1%86-1.html':
            _read('d9y1w_search_jingpin.json'),
      });
      final source = await _boot(
        _script('四色视频.js'),
        section: Section.video,
        http: http,
      );
      addTearDown(source.dispose);

      // ---- 首页：三个横滑板块，「更多」回自己的分类 id。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(
        home.boards.map((board) => board.title).toList(),
        <String>['最新剧情', '最新电影', '最新精选'],
      );
      expect(home.boards.every((board) => board.items.length == 10), isTrue);
      expect(
        home.boards.map((board) => board.moreUrl).toList(),
        <String>['juqing:', 'shipin:', 'jingpin:'],
      );
      final first = home.boards.first.items.first;
      expect(first.id, 'juqing-438819');
      expect(first.title, contains('VAGU-283-CN'), reason: 'AES-256 标题要解出真中文');
      expect(first.cover, startsWith('https://4sv.0827.la/videos/'),
          reason: '封面走媒体 CDN 的真 JPEG，不走站点 data URI 主机');

      // ---- 分类：三个「全部」+ 菜单里 24 个视频标签（实时抓 + AES 解名）。
      final categories = await source.data.categories();
      expect(categories.length, 27);
      expect(categories.take(3).map((category) => category.id).toList(),
          <String>['juqing:', 'shipin:', 'jingpin:']);
      expect(
        categories.map((category) => category.id),
        containsAll(<String>['juqing:麻豆传媒', 'shipin:日本av', 'jingpin:onlyfans']),
      );
      expect(
        categories.map((category) => category.title),
        containsAll(<String>['全部剧情', '剧情 · 麻豆传媒', '精品 · onlyfans']),
      );

      // ---- 列表：20 条/页，日期落在 subtitle。
      final page1 = await source.data.list(categoryId: 'juqing:', page: 1);
      expect(page1.items.length, 20);
      expect(page1.hasMore, isTrue);
      expect(page1.items.first.id, 'juqing-438819');
      expect(page1.items.first.subtitle, '2026-10-30');

      // ---- 搜索：三个频道各打一次，合并去重。
      final searched = await source.data.list(keyword: '麻豆', page: 1);
      expect(searched.items.length, 21);
      expect(searched.items.map((item) => item.id).toSet().length, 21);
      expect(
        http.paths.where((path) => path.contains('/search/')).length,
        3,
        reason: '剧情/视频/精品三个频道都要搜',
      );

      // ---- 详情：标题来自详情页 AES，封面/日期来自列表缓存。
      final detail = await source.data.detail('juqing-438819');
      expect(detail, isNotNull);
      expect(detail!.title, contains('VAGU-283-CN'));
      expect(detail.cover, startsWith('https://4sv.0827.la/videos/'));
      expect(detail.description, contains('剧情 · 中文字幕'));
      expect(detail.description, contains('收录：2026-10-30'));

      // ---- 选集：两条线路。
      final chapters = await source.data.chapters('juqing-438819');
      expect(chapters.map((chapter) => chapter.title).toList(),
          <String>['线路一', '线路二（备用）']);

      // ---- 播放：线路一直给；线路二是死域名，探不通要回落线路一。
      final content = await source.data.content(
        itemId: 'juqing-438819',
        chapterId: '1',
      );
      expect(content, isA<VideoContent>());
      final video = content! as VideoContent;
      expect(video.url.toString(), m3u8);
      expect(video.headers['Referer'], 'https://www.y1c5w.top/');

      final backup = await source.data.content(
        itemId: 'juqing-438819',
        chapterId: '2',
      );
      expect((backup! as VideoContent).url.toString(), m3u8,
          reason: '备用线路探不通时不能把死地址交出去');
      expect(
        http.paths.any((path) => path.contains('sanheyiliao.xyz')),
        isTrue,
        reason: '备用线路要先探一次再决定',
      );
    },
    skip: skipUnless(assets),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // 站点 3 天换一次域名：旧域还响应，但整站 302 到新域的 /enter/index.html。
  // 脚本先靠页面形态（enter-content / qrcodeSmall，且没有 video-item）认出「这台只剩进入页」，
  // 然后换 MIRRORS 里的下一台。这条用例就是拿两个域重演一次换域名。
  const gate =
      '<!DOCTYPE html><html><body class="enter-content">'
      '<div id="txt3">在吗</div>'
      '<div class="qrcode" id="qrcodeSmall"></div>'
      '<a href="/index/home.html">进入</a></body></html>';

  test(
    '四色视频：主域只剩「进入页」时自动换镜像取首页',
    () async {
      final http = _RouteHttp(<String, String>{
        // 顺序有意义：更具体的地址先匹配，主域直接被换成进入页
        'https://www.y1c5w.top/index/home.html': gate,
        'https://www.q5h7m.top/index/home.html': _read('d9y1w_home.html'),
      });
      final source = await _boot(
        _script('四色视频.js'),
        section: Section.video,
        http: http,
      );
      addTearDown(source.dispose);

      final home = await source.data.home();
      expect(home.isBoards, isTrue, reason: '进入页不能被当成首页内容');
      expect(home.boards.length, 3);
      expect(http.paths.first, contains('https://www.y1c5w.top/'),
          reason: '先试主站（mirrors[0]）');
      expect(
        http.paths.any((path) => path.startsWith('https://www.q5h7m.top/')),
        isTrue,
        reason: '主域只剩进入页时要自动换到下一台镜像',
      );
    },
    skip: skipUnless(assets),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // 全部已知域名都只剩「进入页」时（3 天换域的真实开销），脚本去问站方跳转服务
  // good.0827.la：它 302 到当前域名的进入页，宿主把跟随后的最终地址放进 reply.url，
  // 脚本取 origin 再探一次首页，能开就记下来用。这条用例把「已知域名全死」演一遍。
  test(
    '四色视频：已知域名全废时从站方跳转服务发现新域名',
    () async {
      final http = _RouteHttp(
        <String, String>{
          'https://www.y1c5w.top/index/home.html': gate,
          'https://www.q5h7m.top/index/home.html': gate,
          // 跳转服务：跟随 302 后落到新域名的「进入页」
          'good.0827.la': gate,
          'https://www.discovered.top/index/home.html': _read('d9y1w_home.html'),
        },
        urls: <String, String>{
          'good.0827.la': 'https://www.discovered.top/enter/index.html',
        },
      );
      final source = await _boot(
        _script('四色视频.js'),
        section: Section.video,
        http: http,
      );
      addTearDown(source.dispose);

      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 3);
      expect(
        http.paths.any((path) => path.contains('good.0827.la')),
        isTrue,
        reason: '已知域名全废时要问站方跳转服务',
      );
      expect(
        http.paths.any((path) => path.startsWith('https://www.discovered.top/')),
        isTrue,
        reason: '跳转服务回报的最终地址要被当成当前域名',
      );
    },
    skip: skipUnless(assets),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// 按路径（含查询串前缀）匹配快照；未命中的地址回 404（例如备用线路的死域名）。
///
/// [urls] 用来模拟「跟随重定向后的最终地址」：宿主把 `reply.url` 交给脚本，
/// 域名自发现就是靠它认出 302 最终落到哪台主机。
class _RouteHttp extends LumeHttp {
  _RouteHttp(this.routes, {this.urls = const <String, String>{}}) : super();

  final Map<String, String> routes;
  final Map<String, String> urls;

  /// 每次请求的地址（断言路由用）。
  final List<String> paths = <String>[];

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    int? maxBytes,
    Duration? timeout,
  }) async {
    paths.add(url);
    String? payload;
    String? matchedKey;
    for (final entry in routes.entries) {
      if (url.contains(entry.key)) {
        payload = entry.value;
        matchedKey = entry.key;
        break;
      }
    }
    if (payload == null) {
      return LumeHttpResponse(
        statusCode: 404,
        body: Uint8List.fromList(utf8.encode('not found: $url')),
        headers: const <String, String>{},
      );
    }
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(payload)),
      headers: const <String, String>{'content-type': 'text/html; charset=utf-8'},
      url: urls[matchedKey],
    );
  }
}

class _SandboxRuntime implements JsSourceRuntime {
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Set<String>> contractMethods() async => const <String>{
        'categories',
        'list',
        'detail',
        'chapters',
        'content',
        'home',
      };

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
}

String _read(String file) {
  final direct = File(file);
  if (direct.existsSync()) return direct.readAsStringSync();
  final path = sourceAssetPath(file);
  if (path == null) {
    throw StateError('缓存里没有 $file（先跑 `dart run tool/fetch_sources.dart`）');
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

Future<_BootedSource> _boot(
  String scriptPath, {
  required Section section,
  required LumeHttp http,
}) async {
  final script = _read(scriptPath);
  final host = LumeSourceHost(
    http,
    timeout: const Duration(seconds: 10),
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
