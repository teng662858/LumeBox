import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 采墨阁（www.caimoge8.net，**明文 http 站**）：真脚本 + 快照。
///
/// 站点的 443 端口证书对不上域名、且无论直连还是走代理都回 403（实测：直连 https
/// 403、直连 http 200），所以源脚本按 http 拼地址、不做 http→https 升级；用例里的
/// 地址表与断言也一律是 http。
///
/// 快照取自 2026-10-16 的真实响应（snapshots/novel_caimoge8_*.html）。这里守的是：
///   1. 分类页的**分页列表**（`div.l > ul > li`，每页 24 条）与同页的「热门推荐」
///      （`div.item`，有封面、不分页）是两套标记——把 div.item 算进列表会多出 6 条
///      且前 6 条有封面、其余没有（真机上表现为封面一闪一闪）；
///   2. 列表本身没有封面（**封面只在 div.item 里**，且是 `img.lazy[data-original]`，
///      src 是 nocover 占位图）——按 src 取会拿到灰底占位图；
///   3. 详情页的 dl 只是「最新章节」那 108 条（末尾有「点击查看全部章节目录」入口），
///      默认最新在前 → 必须按章节 id 升序重排，否则阅读器从大结局开始读；
///   4. 章节页 h1 自带页码「（1/2）」，第 2 页是 `_2.html`：不拼接就少一半正文。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '采墨阁：分类 / 列表 / 详情 / 目录升序（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'http://www.caimoge8.net/shuku/chuanyue/1.html': 'novel_caimoge8_list.html',
          'http://www.caimoge8.net/txt/53704.html': 'novel_caimoge8_detail.html',
        }),
      );
      final source = await bootNovelSource('采墨阁.js', http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 10);
      expect(categories.first.id, 'shuku/chuanyue');
      expect(categories.first.title, '穿越');
      expect(
        categories.map((category) => category.id),
        containsAll(<String>['shuku/wangyou', 'sort', 'rank/allvisit', 'quanben/sort']),
      );

      // 列表第 1 页：24 条，id 是 /txt/<数字>.html 里的数字。
      final page1 = await source.data.list(categoryId: 'shuku/chuanyue', page: 1);
      expect(page1.items.length, 24);
      expect(page1.hasMore, isTrue, reason: '分页器里有 /shuku/chuanyue/2.html');
      expect(page1.items.first.id, '261753');
      expect(page1.items.first.title, '废墟之上：我们升级安全屋');
      expect(page1.items.first.subtitle, contains('某某城的千一'));
      expect(page1.items.first.subtitle, contains('3分钟前'));
      for (final item in page1.items) {
        expect(RegExp(r'^\d+$').hasMatch(item.id), isTrue, reason: 'id=${item.id}');
        expect(item.title, isNotEmpty);
        // 分类列表在站点上就是没有封面（封面只在「热门推荐」块里）；
        // 脚本要返回空串而不是 nocover.jpg 这类占位图，否则 App 显示灰底假封面。
        expect(item.cover ?? '', isEmpty, reason: '分页列表没有封面字段');
      }

      // 详情：书名 / 作者 / 元信息；这本的封面在站点上就是占位图 ⇒ 空封面。
      final detail = await source.data.detail('53704');
      expect(detail, isNotNull);
      expect(detail!.title, '万族之劫');
      expect(detail.subtitle, contains('老鹰吃小鸡'));
      expect(detail.subtitle, contains('989章节'));
      expect(detail.description, isNotNull);
      expect(detail.description!.length, greaterThan(40));
      expect(detail.cover ?? '', isEmpty, reason: 'nocover.jpg 是占位图，要返回空串而不是坏地址');

      // 目录：/indexlist/ 在快照环境里 404 ⇒ 退回详情页那 108 条，且必须升序。
      // 站点在详情页里只列了「开篇几十章 + 最新十几章」两截，所以中间有断档
      // （真机上全量目录由 /indexlist/ 给出）。
      final chapters = await source.data.chapters('53704');
      expect(chapters.length, 108);
      expect(
        http.seen.contains('http://www.caimoge8.net/indexlist/53704/'),
        isTrue,
        reason: '详情页自己给了「全部章节目录」入口，应当先试它',
      );
      expect(chapters.first.title, '第1章 父子', reason: '详情页默认最新在前，要重排成升序');
      expect(chapters.last.title, '老鹰吃小鸡 完结专访');
      final ids = chapters.map((chapter) => int.parse(chapter.id)).toList();
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i], greaterThan(ids[i - 1]), reason: '目录必须严格升序');
      }
      expect(
        chapters.any((chapter) => chapter.title.contains('点击查看全部章节')),
        isFalse,
        reason: '「点击查看全部章节目录」是入口（dt），不是章节',
      );
    },
    skip: skipUnless(<String>[
      '采墨阁.js',
      'novel_caimoge8_list.html',
      'novel_caimoge8_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '采墨阁：首页封面（data-original）/ 正文多页拼接（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'http://www.caimoge8.net/': 'novel_caimoge8_home.html',
          'http://www.caimoge8.net/shuku/chuanyue/1.html': 'novel_caimoge8_list.html',
          'http://www.caimoge8.net/read/110411/84252828.html':
              'novel_caimoge8_chapter.html',
        }),
      );
      final source = await bootNovelSource('采墨阁.js', http: http);
      addTearDown(source.dispose);

      // 首页：热门推荐（div.item，真封面在 data-original）+ 人气小说榜 + 一个分类列表。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 3);
      expect(home.boards.first.title, '热门推荐');
      expect(home.boards.first.items.length, 6);
      final covered = home.boards.first.items
          .where((item) => (item.cover ?? '').isNotEmpty)
          .toList();
      expect(covered.length, greaterThanOrEqualTo(4), reason: 'data-original 才是真封面');
      for (final item in covered) {
        expect(item.cover!.startsWith('http://'), isTrue,
            reason: '站点只有明文 http（https 证书对不上域名且回 403），封面也得是 http');
        expect(item.cover, contains('img.caimoge8.net'));
        expect(item.cover, isNot(contains('nocover')));
      }
      expect(home.boards[1].title, '人气小说榜');
      expect(home.boards[1].items.length, greaterThan(5));
      expect(home.boards.last.title, '穿越');

      // 正文：第 1974 章是 1/2 页 ⇒ 必须顺 `_2.html` 拼接（快照只有第 1 页 ⇒ 404 停住，
      // 已抓到的正文照样可读，并把失败写进正文）。
      final content = await source.data.content(itemId: '110411', chapterId: '84252828');
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(500));
      expect(text, contains('钟馗'));
      expect(
        http.seen.contains('http://www.caimoge8.net/read/110411/84252828_2.html'),
        isTrue,
        reason: 'h1 的「（1/2）」说明还有第 2 页，必须去拼',
      );
      expect(text, contains('第 2 页抓取失败'));

      for (final url in http.seen) {
        expect(url.startsWith('http://www.caimoge8'),
            isTrue, reason: '脚本请求了非本站地址：$url');
      }
    },
    skip: skipUnless(<String>[
      '采墨阁.js',
      'novel_caimoge8_home.html',
      'novel_caimoge8_list.html',
      'novel_caimoge8_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
