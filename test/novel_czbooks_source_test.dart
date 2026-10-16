import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 小說狂人（czbooks.net，繁體站）：真脚本 + 快照。
///
/// 快照取自 2026-10-16 的真实响应（snapshots/novel_czbooks_*.html）。这里守的是：
///   1. 条目链接是**协议相对地址** `//czbooks.net/n/<key>`，书名在 `div.novel-item-title`，
///      而封面有大半条目本来就是 `default_no_thumbnail.jpg` 占位图（快照里 42 条只有 11 条
///      有真图）——把占位图当封面，App 会显示一张灰底假封面；
///   2. 站点每页都内联 `/cdn-cgi/`（rocket-loader / 邮箱混淆），那是 CF 的前端注入、
///      不是人机校验：拿它当判据会把每一页都误判成「被 Cloudflare 拦」；
///   3. 详情页书名带《》，要剥掉；目录在 `ul#chapter-list` 里、卷名是 `li.volume`（无锚点），
///      章节 id **必须带 ?chapterNumber=**（阅读顺序就是它，导航链接反而不带）。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '小說狂人：分类 / 列表（占位封面）/ 详情 / 目录升序（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://czbooks.net/c/normal': 'novel_czbooks_list.html',
          'https://czbooks.net/n/skf32953i41': 'novel_czbooks_detail.html',
        }),
      );
      final source = await bootNovelSource('小說狂人.js', http: http);
      addTearDown(source.dispose);

      // 分类：19 个题材 + 5 张榜；站点自己的 slug 拼写错误（fanatsy）也照抄。
      final categories = await source.data.categories();
      expect(categories.length, 24);
      expect(categories.first.id, 'xuanhuan');
      expect(categories.first.title, '玄幻奇幻');
      expect(
        categories.map((category) => category.id),
        containsAll(<String>['fanatsy', 'blerotic', 'normal', 'all', 'favorite', 'finish', 'hot']),
      );

      // 列表第 1 页：42 条；条目 id 是 /n/<bookkey> 站内相对路径。
      final page1 = await source.data.list(categoryId: 'normal', page: 1);
      expect(page1.items.length, 42);
      expect(page1.hasMore, isTrue, reason: '分页器里有第 2 页');
      expect(page1.items.first.id, '/n/skf32953i41');
      expect(page1.items.first.title, '寡婦與糙漢[穿越]_木妖嬈【完結】');
      expect(page1.items.first.subtitle, contains('木妖嬈'));
      expect(page1.items.first.cover ?? '', isEmpty, reason: '这条在站点上就是占位图');
      for (final item in page1.items) {
        expect(item.id, startsWith('/n/'), reason: 'id=${item.id}');
        expect(item.title, isNotEmpty);
        if ((item.cover ?? '').isNotEmpty) {
          expect(item.cover!.startsWith('https://'), isTrue);
          expect(item.cover, isNot(contains('default_no_thumbnail')));
        }
      }
      final covered = page1.items.where((item) => (item.cover ?? '').isNotEmpty).toList();
      expect(covered.length, 11, reason: '快照里一页 42 条只有 11 条有真封面（站点侧缺图）');

      // 详情：书名去掉《》，《》是站点排版用的。
      final detail = await source.data.detail('/n/skf32953i41');
      expect(detail, isNotNull);
      expect(detail!.title, '寡婦與糙漢[穿越]_木妖嬈【完結】');
      expect(detail.subtitle, contains('木妖嬈'));
      expect(detail.subtitle, contains('已完結'));
      expect(detail.subtitle, contains('言情'), reason: '分类在状态表的 a#novel-category 里');
      expect(detail.description, isNotNull);
      expect(detail.description, contains('社畜沈清音'));

      // 目录：111 条，按 chapterNumber 升序；`li.volume`（卷名）不是章节。
      final chapters = await source.data.chapters('/n/skf32953i41');
      expect(chapters.length, 111);
      expect(chapters.first.id, '/n/skf32953i41/sk2e5?chapterNumber=0');
      expect(chapters.first.title, '第1頁');
      expect(chapters.last.id, '/n/skf32953i41/bli2e?chapterNumber=110');
      expect(chapters.last.title, '陸錦佑番外');
      expect(
        chapters.any((chapter) => chapter.title.contains('正文卷')),
        isFalse,
        reason: '卷名是 li.volume，没有锚点，不能当章节',
      );
      final numbers = chapters
          .map((chapter) => int.parse(RegExp(r'chapterNumber=(\d+)').firstMatch(chapter.id)!.group(1)!))
          .toList();
      for (var i = 1; i < numbers.length; i++) {
        expect(numbers[i], greaterThan(numbers[i - 1]), reason: '目录必须按 chapterNumber 升序');
      }
    },
    skip: skipUnless(<String>[
      '小說狂人.js',
      'novel_czbooks_list.html',
      'novel_czbooks_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '小說狂人：正文 / 首页版块（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://czbooks.net/': 'novel_czbooks_home.html',
          'https://czbooks.net/n/skf32953i41/bli2e?chapterNumber=110':
              'novel_czbooks_chapter.html',
        }),
      );
      final source = await bootNovelSource('小說狂人.js', http: http);
      addTearDown(source.dispose);

      // 正文：div.content 的 <br /> 分行文本（单页）。
      final content = await source.data.content(
        itemId: '/n/skf32953i41',
        chapterId: '/n/skf32953i41/bli2e?chapterNumber=110',
      );
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(500));
      expect(text, contains('陸錦佑'));
      expect(text, contains('阿嫂'));
      expect(text, isNot(contains('<br')), reason: '正文里不该残留标记');

      // 首页：首页用 li.novel-list-title 当版块标题（**没有 h2**）。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 3);
      expect(home.boards.first.title, '精選小說 - 熱門排行');
      expect(home.boards.first.moreUrl, 'normal');
      expect(home.boards.first.items.length, greaterThan(10));
      expect(home.boards.last.title, '收藏小說 - 熱門排行');
      for (final board in home.boards) {
        expect(board.items, isNotEmpty);
        expect(board.moreUrl, isNotNull);
        for (final item in board.items) {
          expect(item.id, startsWith('/n/'));
          if ((item.cover ?? '').isNotEmpty) {
            expect(item.cover!.startsWith('https://'), isTrue);
          }
        }
      }

      for (final url in http.seen) {
        expect(url.startsWith('https://'), isTrue, reason: '脚本请求了非 https 地址：$url');
      }
    },
    skip: skipUnless(<String>[
      '小說狂人.js',
      'novel_czbooks_home.html',
      'novel_czbooks_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
