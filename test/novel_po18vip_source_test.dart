import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// PO18（wap.po18vip.com，成人站）：真脚本 + 真沙箱 + 快照。
///
/// 守的是四件**不看真页面就发现不了**的事：
///   1. 列表是书库筛选矩阵 `/shuku/<a>/<类型>/<b>/<字数>/<时间>/<e>/<排序>/<页>.html`
///      ——**类型在第 2 段**（`/shuku/0/1/…` 才是玄幻奇幻），其余段固定 0；
///   2. 封面是懒加载的 `img.lazyload[_src]`（`src` 同值但关了 JS 才填），
///      图床是独立域名且写成明文 http，必须升到 https；
///   3. 目录在 `/index/<书号>/asc/<页>.html`（20 章/页，页内 select 给总页数）；
///   4. 正文在 `div#YiJianZhan`（`<br/>` 分行）。**VIP / 需登录的章节抓不到正文时
///      必须点名**，不能把「请登录」的提示页当正文返回（这里另有用例守住）。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    'PO18：分类 / 列表 / 排行 / 详情（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://wap.po18vip.com/shuku/0/0/0/0/0/0/lastupdate/1.html':
              'novel_po18vip_list.html',
          // 「玄幻奇幻」列表：验的是类型落在第 2 段（用 seen 断言地址形状）。
          'https://wap.po18vip.com/shuku/0/1/0/0/0/0/lastupdate/1.html':
              'novel_po18vip_list.html',
          'https://wap.po18vip.com/top/rank.html': 'novel_po18vip_rank.html',
          'https://wap.po18vip.com/book/294.html': 'novel_po18vip_detail.html',
        }),
      );
      final source = await bootNovelSource('po18vip_novel.js', http: http);
      addTearDown(source.dispose);

      // 分类＝书库的 9 个类型 + 排行榜单。
      final categories = await source.data.categories();
      expect(categories.length, 10);
      expect(categories.first.id, '0');
      expect(categories.first.title, '全部');
      expect(categories.map((c) => c.id), contains('rank'));

      // 列表第 1 页：20 条，封面按 `_src` 取并升到 https。
      final page1 = await source.data.list(categoryId: '0', page: 1);
      expect(page1.items.length, 20);
      expect(page1.items.first.id, '110969');
      expect(page1.items.first.title, '孤屿之舟（还想不告而别？再跑一个试试！1v1）');
      expect(page1.items.first.cover,
          'https://img.po18vip.com/image/110/110969/110969s.jpg');
      expect(page1.items.first.coverHeaders['Referer'], contains('po18vip.com'),
          reason: '图床是独立域名，封面要带 Referer');
      for (final item in page1.items) {
        expect(item.id, matches(RegExp(r'^\d+$')));
        expect(item.title, isNotEmpty);
        expect(item.title, isNot(startsWith('【')),
            reason: '书名前面的 span.uptime 是热度值，不能混进标题');
        expect(item.cover, isNotNull);
        expect(item.cover!.startsWith('https://img.po18vip.com/'), isTrue,
            reason: '明文 http 的图床地址必须升到 https');
      }
      expect(page1.items.first.subtitle, contains('章晚昀的无毛猫'));
      expect(page1.hasMore, isTrue, reason: '分页器里有 a.pg-next');

      // 类型筛选：id 落在 URL 第 2 段。
      await source.data.list(categoryId: '1', page: 1);
      expect(
        http.seen.contains(
            'https://wap.po18vip.com/shuku/0/1/0/0/0/0/lastupdate/1.html'),
        isTrue,
        reason: '类型是 /shuku/ 的第 2 段（/shuku/0/1/0/0/0/0/lastupdate/1.html）',
      );

      // 排行榜单：单页 30 条、没有分页。
      final rank = await source.data.list(categoryId: 'rank', page: 1);
      expect(rank.items.length, 30);
      expect(rank.hasMore, isFalse);
      expect(rank.items.first.id, '13175');
      expect(rank.items.first.cover, startsWith('https://img.po18vip.com/'));

      // 详情：书名 / 封面 / 作者 / 类别 / 状态 / 简介。
      final detail = await source.data.detail('294');
      expect(detail, isNotNull);
      expect(detail!.title, '欲灵天下');
      expect(detail.cover, 'https://img.po18vip.com/image/0/294/294s.jpg');
      expect(detail.subtitle, contains('相思夜'));
      expect(detail.subtitle, contains('武侠仙侠'));
      expect(detail.subtitle, contains('全本'));
      expect(detail.description, contains('修真门派'));
      expect(detail.description, isNot(contains('www.po1')),
          reason: '简介里的站内截断尾巴要剔掉');
    },
    skip: skipUnless(<String>[
      'po18vip_novel.js',
      'novel_po18vip_list.html',
      'novel_po18vip_rank.html',
      'novel_po18vip_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'PO18：目录 20 章升序 / 正文分行 / VIP 章节要点名（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://wap.po18vip.com/index/294/asc/1.html': 'novel_po18vip_index.html',
          'https://wap.po18vip.com/book/294/23694130.html':
              'novel_po18vip_chapter.html',
          // 一个 HTTP 200 但**没有** `#YiJianZhan` 的页面（拿详情页顶替）：
          // 模拟 VIP / 需登录章节的响应形状。
          'https://wap.po18vip.com/book/294/99999999.html':
              'novel_po18vip_detail.html',
        }),
      );
      final source = await bootNovelSource('po18vip_novel.js', http: http);
      addTearDown(source.dispose);

      // 目录：/index/<书号>/asc/<页>.html，一页 20 章（旧→新）；
      // 页内 select 说还有 9 页，快照里没有 —— 脚本必须把空页当空页。
      final chapters = await source.data.chapters('294');
      expect(chapters.length, 20);
      expect(chapters.first.id, '30149');
      expect(chapters.first.title, '1.缔约灵宠', reason: '「- 10-03」是日期，不是标题的一部分');
      expect(chapters.last.id, '30246');
      expect(chapters.last.title, '20.九重山');
      expect(chapters.map((c) => c.id).toSet().length, 20);
      expect(
        http.seen.contains('https://wap.po18vip.com/index/294/asc/2.html'),
        isTrue,
        reason: 'select 里有第 2 页，脚本要去抓',
      );

      // 正文：`#YiJianZhan`，`<br/>` 分行。
      final content = await source.data.content(
        itemId: '294',
        chapterId: '23694130',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(500));
      expect(text, contains('程如风'));
      expect(text, contains('\n'));

      // VIP / 需登录的章节：页面 200 但没有 `#YiJianZhan` —— 必须**点名**，
      // 不能静默返回空正文（用户会以为章节是空的）。
      await expectLater(
        source.data.content(itemId: '294', chapterId: '99999999'),
        throwsA(predicate((Object error) =>
            error.toString().contains('VIP') &&
            error.toString().contains('需要登录'))),
      );
    },
    skip: skipUnless(<String>[
      'po18vip_novel.js',
      'novel_po18vip_index.html',
      'novel_po18vip_chapter.html',
      'novel_po18vip_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
