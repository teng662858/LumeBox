import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 顶点小说（m.dingdian666.com，杰奇 WAP）：用真机抓下来的页面快照跑生产调用链。
///
/// 快照取自 2026-10-16 的真实响应（snapshots/novel_dingdian666_*.html）。这里守的是
/// **不看真页面就发现不了**的几条：
///   1. 列表一页 50 条里只有前 3 条（li.sort_one）带封面，其余（li.sort_two）
///      本来就没有封面——按「窗口取第一张图」写会把这 3 张封面串给别的条目；
///   2. 详情页的目录**分页**（每页 15 章），且页面上另有一块「最新三章」用的是
///      同一套 `ul.sort > li.sort_two > a.zhangjie` 标记：不做区块定位会把最新 3 章
///      当成第 1–3 章塞进目录开头；
///   3. 正文页的 `#neirong` 里混着站点自己的阅读器部件（字号按钮 / 章名 / 报错链接 /
///      上下页条）——不剔就会连同「夜间模式：关 护眼：关 …」一起读成正文。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言。
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '顶点小说：分类 / 列表 / 详情 / 目录（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.dingdian666.com/sort/1_1/': 'novel_dingdian666_list.html',
          'https://m.dingdian666.com/ebooks/7325/': 'novel_dingdian666_detail.html',
        }),
      );
      final source = await bootNovelSource('顶点小说.js', http: http);
      addTearDown(source.dispose);

      // 分类：站点导航就 4 个入口（首页 / 分类 / 排行 / 全本），分类下 8 个题材。
      final categories = await source.data.categories();
      expect(categories.length, 10);
      expect(categories.first.id, 'sort/1');
      expect(categories.first.title, '玄幻魔法');
      expect(categories.map((category) => category.id), containsAll(<String>['top', 'full']));

      // 列表第 1 页：50 条（3 条带封面 + 47 条纯文字），id 是纯数字书号。
      final page1 = await source.data.list(categoryId: 'sort/1', page: 1);
      expect(page1.items.length, 50);
      expect(page1.hasMore, isTrue, reason: '整页满 50 条 ⇒ 还有下一页（列表页自己没有分页器）');
      expect(page1.items.first.id, '5485');
      expect(page1.items.first.title, '超维术士');
      expect(page1.items.first.subtitle, contains('牧狐'));
      expect(page1.items.first.cover, contains('/files/article/image/3/3697/3697s.jpg'));
      expect(page1.items.first.cover!.startsWith('https://'), isTrue);
      for (final item in page1.items) {
        expect(RegExp(r'^\d+$').hasMatch(item.id), isTrue, reason: 'id 是 /ebooks/<数字id>/，id=${item.id}');
        expect(item.title, isNotEmpty);
        if ((item.cover ?? '').isNotEmpty) {
          expect(item.cover!.startsWith('https://'), isTrue);
          expect(item.cover, isNot(contains('/000.jpg')), reason: '000.jpg 是站点 onerror 的 1x1 兜底图');
        }
      }
      // 只有 li.sort_one 那 3 条有封面（其余 li.sort_two 本来就没图）。
      final covered = page1.items.where((item) => (item.cover ?? '').isNotEmpty).toList();
      expect(covered.length, 3, reason: '一页只有前 3 条带封面：按窗口取图会把封面串条');
      expect(page1.items[3].cover ?? '', isEmpty);

      // 详情：封面来自 a.p1 的 img（og:image 同址），书名在 h1，简介在 p.jianjie。
      final detail = await source.data.detail('7325');
      expect(detail, isNotNull);
      expect(detail!.title, '万古神帝');
      expect(detail.cover, contains('/files/article/image/2/2639/2639s.jpg'));
      expect(detail.cover!.startsWith('https://'), isTrue);
      expect(detail.subtitle, contains('飞天鱼'));
      expect(detail.subtitle, contains('其他类型'));
      expect(detail.description, isNotNull);
      expect(detail.description!.length, greaterThan(60));

      // 目录：详情页只有第 1 页的 15 章（站点共 282 页，后续页快照没有 ⇒ 404 停住）。
      final chapters = await source.data.chapters('7325');
      expect(chapters.length, 15);
      expect(chapters.first.title, '第1章 八百年后', reason: '目录里的 `1.` 前缀是序号，要剥掉');
      expect(chapters.last.title, '第15章 四牛之力');
      expect(chapters.first.id, '27337205');
      // 「最新三章」版块用的是同一套标记，但**不在**文章目录区里，绝不能混进来。
      expect(
        chapters.any((chapter) => chapter.title.contains('元始法则')),
        isFalse,
        reason: '「最新三章」块与目录同标记，按区块定位才不会串',
      );
      expect(
        chapters.map((chapter) => chapter.id).toSet().length,
        chapters.length,
        reason: '章节号要去重',
      );
    },
    skip: skipUnless(<String>[
      '顶点小说.js',
      'novel_dingdian666_list.html',
      'novel_dingdian666_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '顶点小说：正文（多页拼接 + 剔除阅读器部件）/ 首页（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.dingdian666.com/': 'novel_dingdian666_home.html',
          'https://m.dingdian666.com/sort/1_1/': 'novel_dingdian666_list.html',
          'https://m.dingdian666.com/zhangjie/7325/27337205.html':
              'novel_dingdian666_chapter.html',
        }),
      );
      final source = await bootNovelSource('顶点小说.js', http: http);
      addTearDown(source.dispose);

      // 正文：第 1 章在第 1 页（站点上是 1/2 页，第 2 页快照没有 ⇒ 404 停住，
      // 已抓到的第 1 页照样要能读，并把失败如实写进正文）。
      final content = await source.data.content(itemId: '7325', chapterId: '27337205');
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(800), reason: '第 1 页正文本身就有几千字');
      expect(text, contains('张若尘'));
      expect(text, contains('池瑶'));
      expect(
        text.contains('夜间模式'),
        isFalse,
        reason: '#neirong 里的字号按钮属于阅读器部件，不能混进正文',
      );
      expect(
        text.contains('无弹窗'),
        isFalse,
        reason: '#neirong 顶部那条站点推广行不是正文（它的域名只应出现在失败提示里）',
      );
      expect(text.contains('上一章'), isFalse, reason: '上下页条属于阅读器部件');
      expect(
        text.contains('第 2 页抓取失败'),
        isTrue,
        reason: '多页章节的后续页拉不到时要显式写在正文里，不能静默截断',
      );
      expect(
        http.seen.contains('https://m.dingdian666.com/zhangjie/7325/27337205/2.html'),
        isTrue,
        reason: '多页章节要顺 #fanye1 的「下一页」继续抓',
      );

      // 首页：本站强推（6 条，封面是真的）+ 首页上第一个分类版块（玄幻小说）。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 2);
      expect(home.boards.first.title, '本站强推');
      expect(home.boards.first.items.length, 6);
      expect(home.boards.first.items.first.title, '万古神帝');
      expect(home.boards.first.items.first.cover, contains('/files/article/image/2/2639/2639s.jpg'));
      expect(home.boards.last.title, '玄幻小说');
      expect(home.boards.last.moreUrl, 'sort/1');
      expect(home.boards.last.items.length, greaterThan(10));

      // 宿主只把字符串原样交给网络层：脚本必须发绝对地址。
      for (final url in http.seen) {
        expect(url.startsWith('https://'), isTrue, reason: '脚本请求了非绝对地址：$url');
      }
    },
    skip: skipUnless(<String>[
      '顶点小说.js',
      'novel_dingdian666_home.html',
      'novel_dingdian666_list.html',
      'novel_dingdian666_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
