import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 万相书城（www.wxscs.com）：真脚本 + 快照。
///
/// 快照取自 2026-10-16 的真实响应（snapshots/novel_wxscs_*.html）。这里守的是：
///   1. 分类页每页 **10 条**，第 N 页地址是 `/nav/<slug>_p<N>.html`（站点自己的分页
///      锚点写成相对页名 `xuanhuan_p2.html`，照抄相对地址会 404）；
///   2. 作品 id **可能是数字也可能是拼音 slug**（/book/23183/ 与 /book/wanxiangzhiwang/）
///      ——只留数字会把 slug 作品整条丢掉；
///   3. 详情页自带**全量目录**（1837 章），站点给的是倒序（最新在前），必须按章节 id
///      升序重排，否则阅读器从大结局开始读；第一章的锚点被顶部「开始阅读」按钮抢先
///      （同一个 id、**没有 title**），不处理就会显示成「第 7181896 章」；
///   4. 正文块 `div#cont-body` 后面紧跟分页器、底部导航、标签推荐与版权页脚：截断口径
///      取错会把「有能力者请一定订阅正版书籍」当正文尾巴；
///   5. 长章分页（第 2 页相对地址 `7181897_2.html`）必须并起来，否则少一半正文。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '万相书城：分类 / 列表分页 / 详情 / 目录升序（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.wxscs.com/nav/xuanhuan.html': 'novel_wxscs_list.html',
          'https://www.wxscs.com/nav/xuanhuan_p2.html': 'novel_wxscs_list_p2.html',
          'https://www.wxscs.com/book/wanxiangzhiwang/': 'novel_wxscs_detail.html',
        }),
      );
      final source = await bootNovelSource('万相书城.js', http: http);
      addTearDown(source.dispose);

      // 分类＝站点导航那九个，逐个核过。
      final categories = await source.data.categories();
      expect(categories.length, 9);
      expect(categories.first.id, 'xuanhuan');
      expect(categories.first.title, '玄幻·奇幻');
      expect(
        categories.map((category) => category.id),
        containsAll(<String>[
          'xianxia', 'dushi', 'lishi', 'kehuan', 'kongbu', 'chunai', 'yanqing', 'erciyuan',
        ]),
      );

      // 列表第 1 页：10 条，都有封面（封面地址按 base 补全）。
      final page1 = await source.data.list(categoryId: 'xuanhuan', page: 1);
      expect(page1.items.length, 10);
      expect(page1.items.first.id, '23183');
      expect(page1.items.first.title, '我的功法无限提升');
      expect(page1.items.first.cover,
          'https://www.wxscs.com/uploads/cover/pic23183.jpg');
      expect(page1.items.where((item) => (item.cover ?? '').isEmpty), isEmpty,
          reason: '第一页 10 条都带真封面');
      expect(page1.hasMore, isTrue);

      // 第 2 页走 `_p2.html`（不是 `?page=2`），且内容与第 1 页不同。
      final page2 = await source.data.list(categoryId: 'xuanhuan', page: 2);
      expect(
        http.seen.contains('https://www.wxscs.com/nav/xuanhuan_p2.html'),
        isTrue,
        reason: '站点分页是路径式 _p<N>.html，不能写成查询串',
      );
      expect(page2.items.length, 9);
      expect(page2.items.first.id, '22756');
      expect(page2.items.first.id, isNot(page1.items.first.id),
          reason: '第 2 页必须是另一批书，不能回第 1 页');

      // 详情：书名 / 封面 / 作者 / 简介。
      final detail = await source.data.detail('wanxiangzhiwang');
      expect(detail!.title, '万相之王');
      expect(detail.cover,
          'https://www.wxscs.com/uploads/litimg/210410/1-210410135F2B5.jpg');
      expect(detail.subtitle, contains('天蚕土豆'));
      expect(detail.description, contains('万相之王'));

      // 目录：详情页自带全量，倒序 → 升序交付；第一章的标题不能被「开始阅读」按钮带空。
      final chapters = await source.data.chapters('wanxiangzhiwang');
      expect(chapters.length, 1837);
      expect(chapters.first.id, '7181896');
      expect(chapters.first.title, contains('第1章'));
      expect(chapters.last.id, '7183732');
      expect(chapters.last.title, contains('大结局'));
      final ids = chapters.map((chapter) => int.parse(chapter.id)).toList();
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i], greaterThan(ids[i - 1]), reason: '目录必须按章节 id 升序');
      }
    },
    skip: skipUnless(<String>[
      '万相书城.js',
      'novel_wxscs_list.html',
      'novel_wxscs_list_p2.html',
      'novel_wxscs_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '万相书城：无搜索要明确报错 / 正文分页拼接 / 首页三块（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.wxscs.com/': 'novel_wxscs_home.html',
          'https://www.wxscs.com/book/wanxiangzhiwang/7181897.html':
              'novel_wxscs_chapter.html',
          'https://www.wxscs.com/book/wanxiangzhiwang/7181897_2.html':
              'novel_wxscs_chapter2.html',
        }),
      );
      final source = await bootNovelSource('万相书城.js', http: http);
      addTearDown(source.dispose);

      // 站点没有搜索（/search.html 404）：必须**点名**，不能静默返回空列表
      // （空列表会被当成「没搜到」，用户会反复换关键词）。
      await expectLater(
        source.data.list(keyword: '万相'),
        throwsA(predicate((Object error) =>
            error.toString().contains('没有搜索'))),
      );

      // 首页三块：最新入库（无封面行）/ 好书推荐（有封面卡片）/ 书籍列表。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 3);
      expect(home.boards.first.title, '最新入库');
      expect(home.boards.first.items.length, 10);
      expect(home.boards[1].title, '好书推荐');
      expect(home.boards[1].items.where((item) => (item.cover ?? '').isNotEmpty),
          isNotEmpty, reason: '好书推荐块是带封面的卡片');
      expect(home.boards.last.title, '书籍列表');

      // 正文：第 2 章是 1/2 页 ⇒ 必须顺 `_2.html` 拼接，且不能把页脚当正文。
      final content = await source.data.content(
        itemId: 'wanxiangzhiwang',
        chapterId: '7181897',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text, contains('姜青娥'), reason: '第 1 页正文');
      expect(
        http.seen.contains(
            'https://www.wxscs.com/book/wanxiangzhiwang/7181897_2.html'),
        isTrue,
        reason: '分页器里有 _2.html，必须去并',
      );
      expect(text, contains('当然熟悉'), reason: '第 2 页正文也要并进来');
      expect(text, isNot(contains('版权所有')), reason: '页脚版权声明不算正文');
      expect(text, isNot(contains('订阅和购买正版')), reason: '页脚提示不算正文');
    },
    skip: skipUnless(<String>[
      '万相书城.js',
      'novel_wxscs_home.html',
      'novel_wxscs_chapter.html',
      'novel_wxscs_chapter2.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
