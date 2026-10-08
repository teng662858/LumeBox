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

/// 真实 QuickJS + LumeSourceBridge 下的四个站点源联调。
///
/// HTTP 使用固定快照替身，测试的是生产调用链本身：脚本载入 → 宿主 HTTP
/// 桥接 → `JsDataSource` 参数分发 → 统一内容模型。这样不会因为目标站点临时
/// 不可达而使契约回归测试不稳定。
void main() {
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言。
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎 · 四个扩展源', () {
    test('99xs 小说：列表 / 详情 / 分页正文', () async {
      final source = await _boot(
        _script('99xs_novel.js'),
        section: Section.novel,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://99xs.sbs/enter': _read('99xs.html'),
            'https://99xs.sbs/article/529': _read('99xs_detail.html'),
            'https://99xs.sbs/article/529/2': _read('99xs_detail.html'),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(page: 1);
      expect(list.items, isNotEmpty);
      expect(list.items.first.id, '529');

      final detail = await source.data.detail('529');
      expect(detail?.title, '处女表妹被表哥诱奸');

      final chapters = await source.data.chapters('529');
      expect(chapters.length, 2);
      expect(chapters.last.id, '529/2');

      final content = await source.data.content(
        itemId: '529',
        chapterId: chapters.last.id,
      );
      expect(content, isA<TextContent>());
      expect((content! as TextContent).text, isNotEmpty);
    }, skip: _skipUnless(<String>['99xs_novel.js', '99xs.html', '99xs_detail.html']));

    test('daniao5 漫画：列表 / 详情 / 章节 / 图片', () async {
      final source = await _boot(
        _script('daniao5_comic.js'),
        section: Section.comic,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://daniao5.com/new-manga': _read('daniao5.html'),
            'https://daniao5.com/manga-detail/54000': _read(
              'daniao5_detail.html',
            ),
            'https://daniao5.com/manga-read/54000/fMkYyVpTyuMZJGDREyrw': _read(
              'daniao5_read.html',
            ),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(page: 1);
      expect(list.items.length, greaterThanOrEqualTo(10));
      expect(list.items.first.id, isNotEmpty);

      final detail = await source.data.detail('54000');
      expect(detail?.title, '[3D]妈妈成了家裏保姆儿媳妇');

      final chapters = await source.data.chapters('54000');
      expect(chapters.length, greaterThan(50));
      expect(chapters.first.id, contains('/manga-read/54000/'));

      final content = await source.data.content(
        itemId: '54000',
        chapterId: chapters.first.id,
      );
      expect(content, isA<ImageContent>());
      expect((content! as ImageContent).images.length, greaterThan(50));
    }, skip: _skipUnless(<String>['daniao5_comic.js', 'daniao5.html']));

    // 2026-10-08：接口换成了**实测到的全量那条**。
    //
    // 上一版脚本走 `/Index/latestVideo`（首页那几块，每类固定几条）——真机表现就是
    // 「只能显示几个视频」。新版走 SPA 自己的 `/Search/GetConditionList`：
    // 真浏览器 + curl 双向实测（电影 42960 条、国产剧 23222 条、全站 147232 条，
    // page/pageSize 翻页有效，按 **tid** 过滤）。下面的快照按真实返回形状录制。
    test('gztv5 视频：分类树 / 全量列表 + 翻页 / 详情 / 选集 / 播放', () async {
      final http = _SnapshotHttp(
          post: <String, String>{
            'https://haiwaiapi.1fc8ab0.com/Pc/Index/indexPid':
                '{"data":[{"id":1,"pid":1,"t_id":0,"name":"热门","type":"recommend"},'
                '{"id":3,"pid":3,"t_id":1,"name":"电影","type":"video"},'
                '{"id":4,"pid":4,"t_id":2,"name":"国产剧","type":"video"},'
                '{"id":10,"pid":10,"t_id":0,"name":"游戏","type":"game"}],"code":200}',
            'https://haiwaiapi.1fc8ab0.com/Pc/Search/GetConditionList':
                '{"data":{"total":23222,"list":[{"vod_id":"154204",'
                '"vod_name":"狂王第二季",'
                '"vod_pic":"https://img.example/cdn-cgi/image/height=260/upload/cover.webp",'
                '"vod_area":"内地","vod_year":"2026","vod_scroe":"7.4",'
                '"vod_continu":"12","d_total":"24","t_id":2}]},"code":200}',
            'https://haiwaiapi.1fc8ab0.com/Pc/Resource/GetVodInfo':
                '{"data":{"vodInfo":{"vod_id":"154204","vod_name":"狂王第二季",'
                '"pic":"https://img.example/pic.jpg","vod_continu":"12",'
                '"vod_total":"24","vod_scroe":"7.4","videoTag":["国产剧","热血"],'
                '"vod_year":"2026","vod_area":"内地","vod_actor":"甲,乙",'
                '"vod_director":"丙","vod_use_content":"简介正文"},'
                '"recommendVod":[]},"code":200}',
            'https://haiwaiapi.1fc8ab0.com/Pc/Resource/GetOnePlayList':
                '{"data":{"total_vod_vurl":"2","urls":['
                '{"name":"01","vurl_id":4726345,'
                '"url":"https://cdn.example/1/index.m3u8"},'
                '{"name":"02","vurl_id":4821170,'
                '"url":"https://cdn.example/2/index.m3u8"}]},"code":200}',
          },
      );
      final source = await _boot(
        _script('gztv5_video.js'),
        section: Section.video,
        http: http,
      );
      addTearDown(source.dispose);

      // 分类树：只留能出片的 video / recommend（游戏那类被过滤掉），
      // id 用 **t_id**（列表接口按 tid 过滤，传 pid 会被服务端忽略）。
      final categories = await source.data.categories();
      expect(categories.map((c) => c.title), containsAll(<String>['全部', '热门', '电影', '国产剧']));
      expect(categories.any((c) => c.title == '游戏'), isFalse);
      expect(categories.last.title, '国产剧');
      expect(categories.last.id, '2', reason: 'id 必须是 t_id');

      // 全量列表：条目字段与「更新至 N 集」的进度文案。
      final list = await source.data.list(categoryId: '2', page: 1);
      expect(list.items.single.id, '154204');
      expect(list.items.single.subtitle, contains('更新至 12 集'));
      expect(list.hasMore, isTrue, reason: 'total 23222 > 30，必须能翻页');
      // 封面：接口给的是 Cloudflare 变换地址，脚本要退回原图（真机反馈首页没封面）。
      expect(
        list.items.single.cover,
        'https://img.example/upload/cover.webp',
        reason: '变换段（/cdn-cgi/image/<变换>/）要被去掉，直接用原图地址',
      );

      final detail = await source.data.detail('154204');
      expect(detail?.title, '狂王第二季');
      expect(detail?.cover, 'https://img.example/pic.jpg');
      expect(detail?.subtitle, contains('更新至 12 集'));
      expect(detail?.description, '简介正文');

      final chapters = await source.data.chapters('154204');
      expect(chapters.length, 2);
      // 线路只取一次：chapters 与 content 共用（真机反馈「打开播放器后加载慢」，
      // 不记忆就是两次往返）。
      expect(
        http.calls.where((c) => c.$2.contains('GetOnePlayList')).length,
        1,
        reason: 'chapters + content 只该打一次 GetOnePlayList（少一次往返，起播更快）',
      );
      expect(chapters.first.id, '0', reason: '章节 id 用线路下标');
      expect(chapters.first.title, '01');

      final content = await source.data.content(
        itemId: '154204',
        chapterId: '1',
      );
      expect(content, isA<VideoContent>());
      expect(
        (content! as VideoContent).url.toString(),
        'https://cdn.example/2/index.m3u8',
      );
    }, skip: _skipUnless(<String>['gztv5_video.js']));

    test('dage 视频：加密信封能解开（/core.json 菜单）+ 无快照时明确失败', () async {
      // 这个站每个 JSON 都被包成 {"status":1,"data":"<混淆串>"}，data 要按
      // `/`→0、`@`→/、`.`→+、反转、base64 的顺序还原。下面的快照就是按同一套
      // 规则**反推**出来的（生成脚本自校验过还原结果等于原文），
      // 因此这条用例真正测的是「解包链路能跑通」，而不只是「有没有抛错」。
      const coreEnvelope =
          '{"status":1,"data":"==Qfd1XXbpjIuVmckxWaoNmIsIyYpBnI6ISZwlHdiwiIHm45.uZ5iojIl1WYuJCLiIjI6ICZpJyes0XX9JibvNnauAjMvEzLzR2LzR3cpx2LiojIsJXdiwiInmY5GeK61S55iojIl1WYuJCLiMHZiojIklmI7xSfi42bzpmLwIzLx8Sek9yc0NXas9iI6ICbyVnIsISs9WetUeuI6ISZtFmbiwiI5RmI6ICZpJyebpjIuVmckxWaoNmIsICZvZnI6ISZwlHdiwiIGeK6x2b5iojIl1WYuJCLiEjI6ICZpJyebpjI15WZtJye"}';
      final http = _SnapshotHttp(
        get: <String, String>{'https://dage.one/api/core.json': coreEnvelope},
      );
      final source = await _boot(
        _script('dage_video.js'),
        section: Section.video,
        http: http,
      );
      addTearDown(source.dispose);

      // 分类来自 menu 里 type == 'vod' 的分组（图片分组被跳过）。
      final categories = await source.data.categories();
      expect(
        categories.map((category) => category.title),
        <String>['电影', '电视剧'],
        reason: '解密后的菜单要能读出两个 vod 分类',
      );

      // 边界：列表没有登记快照 → 拉取失败必须**显式报错**，不能静默返回空列表
      // （用户会以为「这个源没内容」，实际是站点/网络的问题）。
      await expectLater(
        source.data.list(categoryId: 'dy'),
        throwsA(isA<SourceException>()),
      );
    }, skip: _skipUnless(<String>['dage_video.js']));

    test('luttt 视频：列表 / 详情 / 选集 / 播放 m3u8', () async {
      final source = await _boot(
        _script('luttt_video.js'),
        section: Section.video,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://v.luttt.com/vodshow/2--------1---.html': _read(
              'luttt_list.html',
            ),
            'https://v.luttt.com/vodshow/2--------2---.html': _read(
              'luttt_list_p2.html',
            ),
            'https://v.luttt.com/voddetail/1137.html': _read('luttt_detail.html'),
            'https://v.luttt.com/vodplay/1137-1-1.html': _read('luttt_play.html'),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(categoryId: '2', page: 1);
      expect(list.items, isNotEmpty);
      expect(list.items.any((item) => item.id == '1137'), isTrue);

      final detail = await source.data.detail('1137');
      expect(detail?.title, '寄生之心');
      expect(detail?.cover, startsWith('http'));

      final chapters = await source.data.chapters('1137');
      expect(chapters.length, greaterThan(1));
      expect(chapters.first.id, contains('/vodplay/1137-'));

      final content = await source.data.content(
        itemId: '1137',
        chapterId: chapters.first.id,
      );
      expect(content, isA<VideoContent>());
      expect((content! as VideoContent).url.toString(), contains('.m3u8'));
    }, skip: _skipUnless(<String>['luttt_video.js', 'luttt_detail.html', 'luttt_play.html']));

    test('p5mh 漫画：列表 / 详情 / 章节 / 多页图片拼接', () async {
      final source = await _boot(
        _script('p5mh_comic.js'),
        section: Section.comic,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://www3.6p5mh3.click/booklist?page=1': _read('p5mh_list.html'),
            'https://www3.6p5mh3.click/book/10612': _read('p5mh_detail.html'),
            'https://www3.6p5mh3.click/chapter/100471684': _read(
              'p5mh_chapter.html',
            ),
            'https://www3.6p5mh3.click/chapter/100471684?page=2': _read(
              'p5mh_chapter_p2.html',
            ),
            'https://www3.6p5mh3.click/chapter/100471684?page=3': _read(
              'p5mh_chapter_p3.html',
            ),
            'https://www3.6p5mh3.click/chapter/100471684?page=4': _read(
              'p5mh_chapter_p4.html',
            ),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(page: 1);
      expect(list.items, isNotEmpty);
      expect(list.items.first.id, '10612');

      final detail = await source.data.detail('10612');
      expect(detail?.title, '朋友妈妈我天菜');

      final chapters = await source.data.chapters('10612');
      expect(chapters, isNotEmpty);
      expect(chapters.first.id, contains('/chapter/'));

      // 这一话在快照里跨了 4 页，content 应该把四页图片拼起来。
      final content = await source.data.content(
        itemId: '10612',
        chapterId: chapters.first.id,
      );
      expect(content, isA<ImageContent>());
      expect((content! as ImageContent).images.length, greaterThanOrEqualTo(55));
    }, skip: _skipUnless(<String>['p5mh_comic.js', 'p5mh_list.html', 'p5mh_detail.html']));

    test('xxs 小说：列表 / 详情 / 章节 / 正文', () async {
      final source = await _boot(
        _script('xxiaoshuo_novel.js'),
        section: Section.novel,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://book.xn--x-ny6am91b6ug0se.com/books': _read('xxs_list.html'),
            'https://book.xn--x-ny6am91b6ug0se.com/book/ffbc92cddbf85a848309e580dd593265':
                _read('xxs_book.html'),
            'https://book.xn--x-ny6am91b6ug0se.com/read/ffbc92cddbf85a848309e580dd593265/32567':
                _read('xxs_read.html'),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(page: 1);
      expect(list.items, isNotEmpty);

      final detail = await source.data.detail('book:ffbc92cddbf85a848309e580dd593265');
      expect(detail?.title, isNotEmpty);

      final chapters = await source.data.chapters(
        'book:ffbc92cddbf85a848309e580dd593265',
      );
      expect(chapters.length, greaterThan(1));

      final content = await source.data.content(
        itemId: 'book:ffbc92cddbf85a848309e580dd593265',
        chapterId: chapters.first.id,
      );
      expect(content, isA<TextContent>());
      expect((content! as TextContent).text, isNotEmpty);
    }, skip: _skipUnless(<String>['xxiaoshuo_novel.js', 'xxs_list.html', 'xxs_book.html', 'xxs_read.html']));

    test('xchina 小说：列表 / 详情 / 章节 / 正文', () async {
      final source = await _boot(
        _script('xchina_novel.js'),
        section: Section.novel,
        http: _SnapshotHttp(
          get: <String, String>{
            'https://xchina.co/fictions/1.html': _read('xchina_list.html'),
            'https://xchina.co/fiction/id-6ac68dd9db5c9.html': _read(
              'xchina_series.html',
            ),
            'https://xchina.co/fiction/id-dGhpc19pc19hX2ZpeGVkMHJhTmJoelVjMjJWNm1iZG5WTXF1L2c9PQ==.html':
                _read('xchina_chapter.html'),
          },
        ),
      );
      addTearDown(source.dispose);

      final list = await source.data.list(page: 1);
      expect(list.items, isNotEmpty);
      expect(list.items.first.id, 'series:6ac68dd9db5c9');

      final detail = await source.data.detail('series:6ac68dd9db5c9');
      expect(detail?.title, '豪乳老师刘艳——第七部06');
      expect(detail?.cover, startsWith('http'));

      final chapters = await source.data.chapters('series:6ac68dd9db5c9');
      expect(chapters.length, 25);

      final content = await source.data.content(
        itemId: 'series:6ac68dd9db5c9',
        chapterId: chapters.first.id,
      );
      expect(content, isA<TextContent>());
      expect((content! as TextContent).text, isNotEmpty);
    }, skip: _skipUnless(<String>['xchina_novel.js', 'xchina_list.html', 'xchina_chapter.html']));
  }, skip: skipReason);
}

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
  required _SnapshotHttp http,
}) async {
  final sourceId = scriptPath.split('/').last.replaceAll('.js', '');
  final host = LumeSourceHost(
    http,
    timeout: const Duration(seconds: 3),
    section: section,
    sourceId: sourceId,
  );
  final sandbox = LumeSandbox.create(
    id: host.expectedSandboxId,
    policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
    host: host,
    polyfills: LumeSourcePolyfills.forSection(section),
  );
  final loaded = await sandbox.load(File(scriptPath).readAsStringSync());
  expect(loaded.isOk, isTrue, reason: '脚本必须能载入: $scriptPath: ${loaded.error}');
  return _BootedSource(
    data: JsDataSource(
      id: sourceId,
      name: sourceId,
      section: section,
      runtime: _SandboxRuntime(sandbox),
    ),
    dispose: () {
      sandbox.dispose();
      host.dispose();
    },
  );
}

/// 读一份缓存里的资产（脚本或站点快照）。用例的 skip 条件保证它存在。
String _read(String file) => File(sourceAssetPath(file)!).readAsStringSync();

class _BootedSource {
  _BootedSource({required this.data, required this.dispose});

  final JsDataSource data;
  final void Function() dispose;
}

class _SnapshotHttp extends LumeHttp {
  _SnapshotHttp({
    this.get = const <String, String>{},
    this.post = const <String, String>{},
  }) : super();

  final Map<String, String> get;
  final Map<String, String> post;

  /// 实际发出的请求（method, url）：用来断言「同一条接口只打了一次」这类
  /// 请求次数口径（真机反馈「打开播放器加载慢」，重复往返就是其中一类原因）。
  final List<(String, String)> calls = <(String, String)>[];

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    final table = method.toUpperCase() == 'POST' ? post : get;
    calls.add((method.toUpperCase(), url));
    final response = table[url];
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

/// 脚本路径（本机没拉缓存时用例会被 skip，不会走到这里）。
String _script(String name) => sourceScriptPath(name)!;
