import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 101小说（www.101minc.com，杰奇定制皮）：真脚本 + 快照。
///
/// 快照取自 2026-10-16 的真实响应（snapshots/novel_101minc_*.html）。这里守的是：
///   1. 列表封面是 **lazysizes**：`img[src=/images/nopic.jpg][srcset=1px 占位 gif]
///      [data-imgurl=真图]`——按 src 取等于没封面（「很多源没封面」的典型原因）；
///      这条用例直接盯住首条封面等于 data-imgurl 的那个地址；
///   2. 条目容器是 `ul#article_list_content`（同页侧栏「小说推荐」是另一套 div.imgbox 形状），
///      整页扫会多出 12 条；
///   3. 站点**没有 SSR 全量目录**：详情页只给最新 15 章（span 里还带更新时间），
///      全量目录在 `/<作品路径>index.html`；两条路都要能走，且退回时要说清只取到多少章；
///   4. 章节文件号 ≠ 章节号（第1245章 = 2419.html），只能从详情页「开始阅读」的
///      文件号起步顺 +1 走，不能从 1 开始数。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  // 快照里的作品地址（站点自己的百分号编码，脚本原样用它拼地址）。
  const book = '/%E8%87%B3%E5%B0%8A%E7%A5%9E%E9%AD%94-4759341530790/';
  const bookUrl = 'https://www.101minc.com$book';

  test(
    '101小说：分类 / 列表（data-imgurl 封面）/ 详情 / 目录（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.101minc.com/novelsort_1_1.html': 'novel_101minc_list.html',
          bookUrl: 'novel_101minc_detail.html',
        }),
      );
      final source = await bootNovelSource('101小说.js', http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 14);
      expect(categories.first.id, 'novelsort/1');
      expect(categories.first.title, '玄幻');
      expect(
        categories.map((category) => category.id),
        containsAll(<String>['noveltop/allvisit', 'noveltop/lastupdate', 'novelfull', 'gengxin']),
      );

      // 列表第 1 页：60 条；id 是 /<书名>-<数字id>/ 的站内路径。
      final page1 = await source.data.list(categoryId: 'novelsort/1', page: 1);
      expect(page1.items.length, 60);
      expect(page1.hasMore, isTrue, reason: '<link rel="next"> 指向 _1_2');
      expect(page1.items.first.title, '加点修仙，我强但我很稳健');
      expect(page1.items.first.subtitle, contains('牛肉包没有牛'));
      expect(
        page1.items.first.cover,
        'https://www.101minc.com/files/article/image/5553714337/5553714337287/5553714337287s.jpg',
        reason: '封面必须取自 data-imgurl，而不是 src 里的 nopic.jpg 占位图',
      );
      for (final item in page1.items) {
        expect(RegExp(r'-[0-9]+/$').hasMatch(item.id), isTrue, reason: 'id=${item.id}');
        expect(item.id, startsWith('/%'), reason: '站点按百分号编码匹配，不能解码后再拼');
        expect(item.title, isNotEmpty);
        if ((item.cover ?? '').isNotEmpty) {
          expect(item.cover!.startsWith('https://'), isTrue);
          expect(item.cover, contains('/files/article/image/'));
          expect(item.cover, isNot(contains('nopic')));
        }
      }
      final covered = page1.items.where((item) => (item.cover ?? '').isNotEmpty).toList();
      expect(covered.length, 53, reason: '快照这一页 60 条里有 7 条站点自己就没有封面');

      // 详情：简介在 #tab_info 的 navtxt 里（站点后面还跟着推荐语，只取第一个 p）。
      final detail = await source.data.detail(book);
      expect(detail, isNotNull);
      expect(detail!.title, '至尊神魔');
      expect(detail.cover, 'https://www.101minc.com/files/article/image/4759341530/4759341530790/4759341530790s.jpg');
      expect(detail.subtitle, contains('洛城东'));
      expect(detail.subtitle, contains('玄幻小说'));
      expect(detail.subtitle, contains('1082.0万字'));
      expect(detail.description, contains('龙脉大陆'));

      // 目录：index.html 在快照环境里 404 ⇒ 退回「顺抓 + 详情页最新 15 章」；
      // 顺抓从「开始阅读」的 75.html 起步（站点文件号不是章节号），快照里 75.html 也 404。
      final chapters = await source.data.chapters(book);
      expect(
        http.seen.contains('${bookUrl}index.html'),
        isTrue,
        reason: '章节页导航里有目录入口 /<作品路径>index.html，应当先试它',
      );
      expect(http.seen.contains('${bookUrl}75.html'), isTrue, reason: '顺抓要从「开始阅读」的文件号起步');
      expect(chapters.length, 15);
      expect(chapters.first.title, '第5749章 没有生路！');
      expect(chapters.last.title, '第5763章 就凭你，也配跟我动手？');
      expect(chapters.first.id, '6910');
      expect(chapters.last.id, '6934');
      final numbers = chapters.map((chapter) => int.parse(chapter.id)).toList();
      for (var i = 1; i < numbers.length; i++) {
        expect(numbers[i], greaterThan(numbers[i - 1]), reason: '目录必须升序');
      }
      expect(
        chapters.any((chapter) => RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(chapter.title)),
        isFalse,
        reason: '详情页那个 span 里带更新时间，要剥掉',
      );
    },
    skip: skipUnless(<String>[
      '101小说.js',
      'novel_101minc_list.html',
      'novel_101minc_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '101小说：正文 / 首页榜单（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.101minc.com/': 'novel_101minc_home.html',
          'https://www.101minc.com/novelsort_1_1.html': 'novel_101minc_list.html',
          '${bookUrl}2419.html': 'novel_101minc_chapter.html',
        }),
      );
      final source = await bootNovelSource('101小说.js', http: http);
      addTearDown(source.dispose);

      final content = await source.data.content(itemId: book, chapterId: '2419');
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(500));
      expect(text, contains('陈枫'));
      expect(text, contains('炼药师'));
      expect(text, isNot(contains('<p')), reason: '正文里不该残留标记');

      // 首页：热门榜单（7 条，带真封面）+ 玄幻列表首屏。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 2);
      expect(home.boards.first.title, '热门榜单');
      expect(home.boards.first.items.length, 7);
      expect(home.boards.first.items.first.title, '带着农场混异界');
      expect(home.boards.first.items.first.cover, contains('/files/article/image/'));
      expect(home.boards.first.moreUrl, 'noveltop/allvisit');
      expect(home.boards.last.title, '玄幻');
      expect(home.boards.last.items.length, 12);

      for (final url in http.seen) {
        expect(url.startsWith('https://'), isTrue, reason: '脚本请求了非 https 地址：$url');
      }
    },
    skip: skipUnless(<String>[
      '101小说.js',
      'novel_101minc_home.html',
      'novel_101minc_list.html',
      'novel_101minc_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
