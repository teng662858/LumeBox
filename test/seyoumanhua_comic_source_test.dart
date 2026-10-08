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

/// 色友漫画源：用**实时抓下来的页面快照**跑生产调用链（脚本载入 → HTTP 桥接 →
/// 数据源适配 → 统一内容模型）。站点临时不可达不会让契约回归失效。
///
/// 快照取自 2026-10-07 的真实响应（见仓库根目录的 seyoumanhua_*.html）。
/// 这里守的是三件**不看真页面就发现不了**的事：
///   1. 分类列表 / 详情 / 正文的解析规则对得上站点真实标记；
///   2. 章节顺序：站点把「最新一话」钉在目录首位，源必须按编号重排
///      （否则阅读器「下一章」会跳过那一话）；
///   3. 图片地址统一升级到 https（iOS 的 ATS 不允许明文 http）。
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
    '色友漫画：分类列表 / 详情 / 章节顺序 / 正文图片（快照）',
    () async {
      final source = await _boot(
        _script('seyoumanhua_comic.js'),
        section: Section.comic,
        http: _SnapshotHttp(get: <String, String>{
          'https://seyoumanhua.com/index.php/category/list/5': _read('seyoumanhua_list.html'),
          'https://seyoumanhua.com/index.php/comic/dongdongzahuodian': _read('seyoumanhua_comic.html'),
          'https://seyoumanhua.com/index.php/chapter/29373': _read('seyoumanhua_chapter.html'),
        }),
      );
      addTearDown(source.dispose);

      // 分类：站点自己的 25 个 + 「全部」。
      final categories = await source.data.categories();
      expect(categories.length, 26);
      expect(categories.first.id, 'all');
      expect(categories[1].title, '都市');

      // 列表：20 条，封面走 https，标题非空。
      final list = await source.data.list(categoryId: '5');
      expect(list.items.length, 20);
      expect(list.items.first.id, isNotEmpty);
      expect(list.items.first.title, isNotEmpty);
      expect(
        (list.items.first.cover ?? '').startsWith('https://'),
        isTrue,
        reason: 'iOS 禁明文 http，封面必须是 https',
      );

      // 详情：标题取自 og:title（去掉站点后缀），封面 https。
      const slug = 'dongdongzahuodian';
      final detail = await source.data.detail(slug);
      expect(detail, isNotNull);
      expect(detail!.title, '洞洞雜貨店');
      expect((detail.cover ?? '').startsWith('https://'), isTrue);

      // 章节：152 条，且**按编号重排**——站点把第22話钉在目录首位，
      // 排序后第 1 话必须在最前、第 22 话回到它自己的位置。
      final chapters = await source.data.chapters(slug);
      expect(chapters.length, 152);
      expect(chapters.first.title, startsWith('第1話'));
      expect(
        chapters[21].title,
        startsWith('第22話'),
        reason: '被站点钉在首位的「第22話」必须回到第 22 位（否则下一章会跳过它）',
      );
      expect(
        chapters.last.title,
        contains('休刊公告'),
        reason: '解析不出编号的条目保留在末尾，而不是被丢掉',
      );
      expect(chapters.map((c) => c.id).toSet().length, 152, reason: '章节 id 不应重复');

      // 正文：75 张图，全部 https。
      final content = await source.data.content(
        itemId: slug,
        chapterId: '29373',
      );
      expect(content, isA<ImageContent>());
      final images = (content! as ImageContent).images;
      expect(images.length, 75);
      expect(
        images.every((url) => url.startsWith('https://')),
        isTrue,
        reason: '正文图片也必须升级到 https',
      );
    },
    skip: skipUnless(<String>['seyoumanhua_comic.js', 'seyoumanhua_list.html', 'seyoumanhua_comic.html', 'seyoumanhua_chapter.html']),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    '99xs 小说：分类从站点导航读（繁体 slug）+ 搜索带 cookie（真机修复的回归）',
    () async {
      // 站点分类 slug 是**繁体**（亂倫小說），界面名是简体（乱伦小说），
      // 写死简体拼地址会 404（实测：繁体 200 / 简体 404；而百分号转义的大小写
      // 无所谓，两种都 200）。因此源改为**从 /enter 的导航里读分类**，
      // id 用站点自己的 slug——这份快照守的就是这条。
      //
      // 搜索还会撞站点的「点击继续访问」拦截页：必须带 cookie
      // `x-index-auth=authed`（不带时返回的是 2.4KB 拦截页，一条都解析不出来）。
      final http = _SnapshotHttp(get: <String, String>{
        'https://99xs.sbs/enter': _read('99xs_enter.html'),
        'https://99xs.sbs/article/category/%E4%BA%82%E5%80%AB%E5%B0%8F%E8%AA%AA': _read('99xs_category.html'),
        'https://99xs.sbs/?s=%E7%BE%8E%E5%A5%B3&paged=1': _read('99xs_search.html'),
      });
      final source = await _boot(
        _script('99xs_novel.js'),
        section: Section.novel,
        http: http,
      );
      addTearDown(source.dispose);

      // 分类来自导航：第一项是「全部」，其余是站点自己的 slug（解码后为繁体）。
      final categories = await source.data.categories();
      expect(categories.length, greaterThan(5));
      expect(categories.first.id, 'all');
      expect(
        categories.map((category) => category.id),
        contains('亂倫小說'),
        reason: 'id 应当是站点 slug 解码后的繁体名，而不是界面的简体名',
      );
      expect(
        categories.firstWhere((category) => category.id == '亂倫小說').title,
        '乱伦小说',
        reason: '展示名仍用站点界面的简体',
      );

      // 用站点给的 id 取列表：命中快照即证明地址拼对了。
      final byCategory = await source.data.list(categoryId: '亂倫小說');
      expect(
        byCategory.items.length,
        20,
        reason: '分类页要能解析出 20 条（地址拼错的话这里会是 404）',
      );

      // 搜索：结果条数 + 请求确实带了那枚 cookie。
      final byKeyword = await source.data.list(keyword: '美女');
      expect(byKeyword.items.length, 20);
      expect(
        http.seenHeaders['https://99xs.sbs/?s=%E7%BE%8E%E5%A5%B3&paged=1']?['Cookie'],
        contains('x-index-auth=authed'),
        reason: '搜索走根路径会撞拦截页，必须带上这枚 cookie',
      );
      expect(
        http.seenHeaders['https://99xs.sbs/article/category/%E4%BA%82%E5%80%AB%E5%B0%8F%E8%AA%AA']?['Cookie'],
        contains('x-index-auth=authed'),
        reason: '其余请求也统一带头（站点自己就是让用户写这枚 cookie 的）',
      );
    },
    skip: skipUnless(<String>['99xs_novel.js', '99xs_enter.html', '99xs_category.html', '99xs_search.html']),
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
      const <String>{'categories', 'list', 'detail', 'chapters', 'content'};
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
