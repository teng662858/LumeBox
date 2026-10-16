import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 随看书（suixkan，m.suixkan.com）：真脚本 + 真沙箱 + 快照。
///
/// 守的是四件**不看真页面就发现不了**的事：
///   1. **列表优先走 JSON 接口** `/api/book/classify?classify_id=&page=`（站点自己的
///      列表页就是用它翻页的：`{code:0,data:{count,list:[…]}}`，每页 5 条、
///      `count` 是分类总数）；接口失败才回退 HTML。两个路径都要能用；
///   2. HTML 列表的导航**全是 JS**（`onclick="gotoPage('/b/<书号>.html')"`），
///      几乎没有 `<a href>` —— 书号只能从 onclick 里取；
///   3. 目录 `/c/<书号>.html` **整本在一个 HTML 里**（3182 章 ≈ 500KB，页内用
///      `<div id="N">` 做锚点跳转，不是分页）；
///   4. 正文 `/r/<书号>/<章节号>.html` 也是**整章在一个 HTML 里**，由多个
///      `div.section`（第一节没有 `none`，其余是 `section none`）组成；每节末尾
///      都插一句「（本章未完，请翻页）」（不是正文），且**节与节之间是一句话被
///      切开**，所以跨节要直接续写、不能插换行。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '随看书：分类 / 列表（JSON 优先 + HTML 回退）/ 详情（快照）',
    () async {
      final jsonHttp = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.suixkan.com/api/book/classify?classify_id=1100&page=1':
              'novel_suixkan_api_p1.json',
          'https://m.suixkan.com/l/f/1100/1.html': 'novel_suixkan_list.html',
          'https://m.suixkan.com/b/31146.html': 'novel_suixkan_detail.html',
        }),
      );
      final source = await bootNovelSource('suixkan_novel.js', http: jsonHttp);
      addTearDown(source.dispose);

      // 分类＝三个频道下的 24 个分类号。
      final categories = await source.data.categories();
      expect(categories.length, 24);
      expect(categories.first.id, '1100');
      expect(categories.first.title, '都市人生');
      expect(categories.map((c) => c.id), containsAll(<String>['1100', '2100', '4107']));

      // **JSON 路径**：5 条/页，封面是 CDN 的 https 地址。
      final page1 = await source.data.list(categoryId: '1100', page: 1);
      expect(page1.items.length, 5);
      expect(page1.items.first.id, '/b/18615.html');
      expect(page1.items.first.title, '逍遥小医仙');
      expect(page1.items.first.cover,
          'https://cdn.p.yueyouxs.com/wap/18615/69d1e3a65455cf2c7456f2c0c43fb71d.jpg');
      expect(page1.items.first.coverHeaders['Referer'], contains('suixkan.com'),
          reason: '封面在独立 CDN 上，要带 Referer');
      expect(page1.items.first.subtitle, contains('客家少爷'));
      expect(page1.items.first.subtitle, contains('41.73 万字'));
      for (final item in page1.items) {
        expect(item.id, matches(RegExp(r'^/b/\d+\.html$')));
        expect(item.title, isNotEmpty);
        expect(item.cover, isNotNull);
        expect(item.cover!.startsWith('https://cdn.p.yueyouxs.com/'), isTrue);
      }
      expect(page1.hasMore, isTrue, reason: 'count 7072，第 1 页 5 条当然还有');

      // 详情：书名 / 封面 / 作者+分类+字数（`.v-words` 行）/ 共 N 章 / 简介。
      final detail = await source.data.detail('31146');
      expect(detail, isNotNull);
      expect(detail!.title, '校花的修仙强者');
      expect(detail.cover,
          'https://cdn.p.yueyouxs.com/wap/31146/9fefc9de5118cf151fe36ed2cbdf48a5.jpg');
      expect(detail.subtitle, contains('落叶浮尘'));
      expect(detail.subtitle, contains('武侠仙侠'));
      expect(detail.subtitle, contains('共 3182 章'));
      expect(detail.description, contains('修仙'));

      // **HTML 回退路径**：接口不在（404）时改用 /l/f/<分类号>/<页>.html，
      // 书号从 onclick 的 gotoPage 里取。
      final htmlHttp = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.suixkan.com/l/f/1100/1.html': 'novel_suixkan_list.html',
        }),
      );
      final fallback = await bootNovelSource('suixkan_novel.js', http: htmlHttp);
      addTearDown(fallback.dispose);
      final htmlItems = await fallback.data.list(categoryId: '1100', page: 1);
      expect(htmlItems.items.length, 5,
          reason: 'HTML 列表这一页服务端渲染了 5 条（导航是 JS，只能从 onclick 取）');
      expect(htmlItems.items.first.id, '/b/18615.html');
      expect(htmlItems.items.first.title, '逍遥小医仙');
      expect(htmlItems.items.first.cover,
          startsWith('https://cdn.p.yueyouxs.com/'));
      expect(
        htmlHttp.seen.contains('https://m.suixkan.com/api/book/classify'
            '?classify_id=1100&page=1'),
        isTrue,
        reason: '接口是首选：先试接口，失败了才回退',
      );
      expect(htmlHttp.seen.contains('https://m.suixkan.com/l/f/1100/1.html'), isTrue);
    },
    skip: skipUnless(<String>[
      'suixkan_novel.js',
      'novel_suixkan_api_p1.json',
      'novel_suixkan_list.html',
      'novel_suixkan_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '随看书：目录 3182 章（单页）/ 正文多节拼接（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.suixkan.com/c/31146.html': 'novel_suixkan_index.html',
          'https://m.suixkan.com/r/31146/31147.html': 'novel_suixkan_chapter.html',
        }),
      );
      final source = await bootNovelSource('suixkan_novel.js', http: http);
      addTearDown(source.dispose);

      // 目录：整本在一个 HTML 里（3182 章）。
      final chapters = await source.data.chapters('31146');
      expect(chapters.length, 3182);
      expect(chapters.first.id, '/r/31146/31147.html');
      expect(chapters.first.title, '第1章 重生归来');
      expect(chapters.last.id, '/r/31146/34328.html');
      expect(chapters.map((c) => c.id).toSet().length, 3182);
      expect(
        http.seen.contains('https://m.suixkan.com/c/31146.html'),
        isTrue,
        reason: '目录是一整页，不该出现 /c/31146_2.html 这种请求',
      );

      // 正文：5 个 section 拼成一章。
      final content = await source.data.content(
        itemId: '31146',
        chapterId: '/r/31146/31147.html',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(1500), reason: '5 节加起来远不止一节');
      expect(text, startsWith('雨夜，电闪雷鸣！'));
      expect(text, contains('杨天'), reason: '第 5 节的内容也要在（证明是拼接）');
      expect(text, isNot(contains('（本章未完，请翻页）')),
          reason: '站点插的翻页提示不是正文，必须剔掉');
      expect(text, contains('他不是破天仙帝，而是一个普通人。'),
          reason: '节与节之间是一句话被切开，跨节必须直接续写（不能插换行）');
    },
    skip: skipUnless(<String>[
      'suixkan_novel.js',
      'novel_suixkan_index.html',
      'novel_suixkan_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
