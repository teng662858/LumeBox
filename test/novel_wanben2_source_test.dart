import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 完本神站（wanben2，主站 301 到 xwbsz.com）：真脚本 + 真沙箱 + 快照。
///
/// 守的是四件**不看真页面就发现不了**的事：
///   1. 分类列表页给两套标记：`#hotcontent .item`（**只有本页前 6 条**，带封面）
///      与 `#newscontent` 的 `<li>` 行（本页全部 35 条，只有文字）。脚本以 li 行
///      为条目、把 .item 的封面按书号并进去 —— 只用 .item 每页只剩 6 条，
///      只用 li 行则一条封面都没有（两种退化都会在这里被数量/封面断言抓住）；
///   2. 封面写死在 **明文 http://www.xwbsz.com/images/…**，iOS 禁明文，脚本要
///      把它升到 https；`static/heibing/nocover.jpg` 是站点占位图，必须当没有封面；
///   3. 目录**在详情页 `#list` 里**、完整、旧→新；站点数据里相邻章节会复用同一个
///      章节地址（1054 条只有 844 个唯一地址），脚本按站点原样给全、不按地址去重；
///   4. 正文在 `div#content` 的 `<p>` 里。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '完本神站：分类 / 列表（li 行 + 卡片封面）/ 分页 / 排行（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.xwbsz.com/fenlei/1/1/': 'novel_wanben2_list.html',
          'https://www.xwbsz.com/fenlei/1/2/': 'novel_wanben2_list_p2.html',
          'https://www.xwbsz.com/rank/': 'novel_wanben2_rank.html',
        }),
      );
      final source = await bootNovelSource('wanben2_novel.js', http: http);
      addTearDown(source.dispose);

      // 分类是站点导航那 26 个入口（24 个栏目 + 全部小说 + 排行榜单）。
      final categories = await source.data.categories();
      expect(categories.length, 26);
      expect(categories.first.id, '1');
      expect(categories.first.title, '玄幻');
      expect(categories.map((c) => c.id), contains('all'));
      expect(categories.map((c) => c.id), contains('rank'));

      // 列表第 1 页：35 条（li 行），封面从同页的 .item 并进来。
      final page1 = await source.data.list(categoryId: '1', page: 1);
      expect(page1.items.length, 35, reason: '只用 .item 会只剩 6 条');
      expect(page1.items.first.title, '帝龙情薄+番外');
      expect(page1.items.last.title, '我的怪物小情人');
      for (final item in page1.items) {
        expect(item.id, matches(RegExp(r'^\d+$')));
        expect(item.title, isNotEmpty);
      }
      final withCover = page1.items.where((item) => (item.cover ?? '').isNotEmpty);
      expect(withCover.length, 1, reason: '本页 6 张里只有「永恒武神」不是占位图');
      for (final item in page1.items) {
        expect(item.cover ?? '', isNot(contains('nocover')),
            reason: '占位图不能当封面');
        if ((item.cover ?? '').isNotEmpty) {
          expect(item.cover!.startsWith('https://www.xwbsz.com/'), isTrue,
              reason: '站点封面是明文 http，必须升到 https');
        }
      }
      final eternal = page1.items.firstWhere((item) => item.id == '94389370');
      expect(eternal.cover, 'https://www.xwbsz.com/images/94389/94389370/94389370s.jpg');
      expect(page1.hasMore, isTrue, reason: '分页器里有「下一页」');

      // 第 2 页：地址 /fenlei/1/2/，内容换了一批。
      // 注意：站点这一页的「最近更新列表」与第 1 页会**重复少量条目**（刚更新过的
      // 书会被重新列出来，实测 35 条里重 3 条），所以断言是「大部分是新书」。
      final page2 = await source.data.list(categoryId: '1', page: 2);
      expect(page2.items.length, 35);
      expect(page2.items.first.title, '恐怖复苏，我加点练剑，剑开天门');
      final firstIds = page1.items.map((item) => item.id).toSet();
      final fresh = page2.items.where((item) => !firstIds.contains(item.id)).length;
      expect(fresh, greaterThanOrEqualTo(30), reason: '第 2 页必须是另一批书（允许少量重复）');
      expect(http.seen.contains('https://www.xwbsz.com/fenlei/1/2/'), isTrue,
          reason: '分页地址是 /fenlei/<栏目>/<页>/');

      // 排行榜单：整页 50 张卡片，**没有 li 行**，此时退回只用卡片。
      final rank = await source.data.list(categoryId: 'rank', page: 1);
      expect(rank.items.length, 50);
      expect(rank.hasMore, isFalse, reason: '/rank/ 没有分页');
      expect(rank.items.first.title, '虚有其表');
      // 50 张里 49 张是真图、1 张是站点自己的 nocover 占位（当没有封面）。
      final rankCovers = rank.items.where((item) => item.cover != null).toList();
      expect(rankCovers.length, 49);
      for (final item in rankCovers) {
        expect(item.cover!.startsWith('https://www.xwbsz.com/images/'), isTrue);
      }
      expect(
        rank.items.any((item) => (item.cover ?? '').contains('nocover')),
        isFalse,
        reason: '占位图不能当封面',
      );
    },
    skip: skipUnless(<String>[
      'wanben2_novel.js',
      'novel_wanben2_list.html',
      'novel_wanben2_list_p2.html',
      'novel_wanben2_rank.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '完本神站：详情 / 目录 1054 章 / 正文（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.xwbsz.com/92962467/': 'novel_wanben2_detail.html',
          'https://www.xwbsz.com/92962467/16383271.html': 'novel_wanben2_chapter.html',
        }),
      );
      final source = await bootNovelSource('wanben2_novel.js', http: http);
      addTearDown(source.dispose);

      final detail = await source.data.detail('92962467');
      expect(detail, isNotNull);
      expect(detail!.title, '不灭神王');
      expect(detail.cover, 'https://www.xwbsz.com/images/92962/92962467/92962467s.jpg');
      expect(detail.subtitle, contains('观棋'));
      expect(detail.subtitle, contains('玄幻'));
      expect(detail.subtitle, contains('全本'));
      // 这一本的 `#intro` 是空的，脚本退回站点的 meta description。
      expect(detail.description, isNotNull);
      expect(detail.description, contains('不灭神王'));

      // 目录在详情页里、完整（1054 条，旧→新）。
      final chapters = await source.data.chapters('92962467');
      expect(chapters.length, 1054);
      expect(chapters.first.title, '第一章 王可');
      expect(chapters.last.title, '第一千零五十四章 （大结局）');
      final ids = chapters.map((c) => int.parse(c.id)).toList();
      expect(ids, orderedEquals(<int>[...ids]..sort()),
          reason: '目录必须按章节号升序（站点相邻章节复用同一地址，仍是单调不减）');
      expect(chapters.every((c) => c.title.isNotEmpty), isTrue);

      final content = await source.data.content(
        itemId: '92962467',
        chapterId: chapters.first.id,
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(800));
      expect(text, contains('朱仙镇'));
      expect(text, contains('\n'), reason: '段落之间要保留换行');
    },
    skip: skipUnless(<String>[
      'wanben2_novel.js',
      'novel_wanben2_detail.html',
      'novel_wanben2_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
