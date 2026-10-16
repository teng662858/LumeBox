import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 无忧小说网（51eshu，m.51eshu.com）：真脚本 + 真沙箱 + 快照。
///
/// 守的是四件**不看真页面就发现不了**的事：
///   1. 分类路径里有**脚本 g（U+0261）**：`/QinɡChun/`（青春）、`/NuShenɡ/`（女生）
///      —— 照抄站点导航才对，写成普通 g 会 404。这里断言 id 原样落进请求地址；
///   2. 列表分页是 `/<栏目>/` + `/<栏目>/<N>.html`（第 1 页没有页码段）；
///   3. **一章可能多页**：第 1 页 `<章节号>.html`、第 2 页起 `<章节号>_2.html`…
///      末页的「下一页」指向的是**下一章**，所以只能跟 `_<n>` 形状的链接。
///      这里把 `_2.html` 也指到同一份快照，断言「两页都被抓了并拼起来了」；
///   4. 目录在独立的 `/shu/<书号>/`（50 章/页，页内 select 给总页数），
///      详情页上的 `ul.vlist` 只是「最新 5 + 展开 + 最前 5」的预览，不是目录。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '无忧小说网：分类（脚本 g）/ 列表 / 分页 / 详情（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://m.51eshu.com/LiShi/': 'novel_51eshu_list.html',
          // 第 2 页没有单独快照，指向同一份内容 —— 验的是**地址形状**（用 seen）。
          'https://m.51eshu.com/LiShi/2.html': 'novel_51eshu_list.html',
          'https://m.51eshu.com/QinɡChun/': 'novel_51eshu_list.html',
          // 分类 id 认不出时退回的书库（白名单兜底）。
          'https://m.51eshu.com/XuanHuan/': 'novel_51eshu_list.html',
          'https://m.51eshu.com/xs/29175.html': 'novel_51eshu_detail.html',
        }),
      );
      final source = await bootNovelSource('51eshu_novel.js', http: http);
      addTearDown(source.dispose);

      // 分类＝排序页那 18 个栏目，其中两个目录用的是脚本 g（U+0261）。
      final categories = await source.data.categories();
      expect(categories.length, 18);
      expect(categories.first.id, 'XuanHuan');
      expect(categories.first.title, '玄幻');
      expect(categories.map((c) => c.id), contains('QinɡChun'),
          reason: '站点目录名里的 g 是 U+0261（脚本 g），不是拉丁 g');
      expect('QinɡChun'.runes.contains(0x0261), isTrue);
      expect(categories.map((c) => c.id), contains('NuShenɡ'));
      expect(categories.map((c) => c.title), contains('青春'));

      // 列表第 1 页：20 条，封面是 CDN 原图。
      final page1 = await source.data.list(categoryId: 'LiShi', page: 1);
      expect(page1.items.length, 20);
      expect(page1.items.first.id, '/xs/395021.html',
          reason: 'id 是详情地址（详情 / 目录 / 正文都从它推）');
      expect(page1.items.first.title, '隋末唐初，从小兵到凌烟阁功臣！');
      expect(page1.items.first.cover, 'https://img.51eshu.com/395021/351305.jpg');
      expect(page1.items.first.coverHeaders['Referer'], contains('m.51eshu.com'),
          reason: '图床是独立域名，封面要带 Referer');
      expect(page1.items.first.subtitle, contains('云上子兴'));
      for (final item in page1.items) {
        expect(item.id, matches(RegExp(r'^/xs/\d+\.html$')));
        expect(item.title, isNotEmpty);
        expect(item.cover, isNotNull);
        expect(item.cover!.startsWith('https://img.51eshu.com/'), isTrue);
      }
      expect(page1.hasMore, isTrue, reason: '分页器里有「下一页」');

      // 第 2 页地址形状：/<栏目>/2.html。
      await source.data.list(categoryId: 'LiShi', page: 2);
      expect(http.seen.contains('https://m.51eshu.com/LiShi/2.html'), isTrue);

      // 脚本 g 的分类 id 原样落进路径（拼错就是 404，替身会以拉取失败暴露）。
      final qingchun = await source.data.list(categoryId: 'QinɡChun', page: 1);
      expect(qingchun.items.length, 20);
      expect(http.seen.contains('https://m.51eshu.com/QinɡChun/'), isTrue,
          reason: 'U+0261 必须原样出现在请求地址里');
      // 分类 id 不存在时也不能拿它拼 URL（会 404）：退回默认栏目。
      await source.data.list(categoryId: 'NotACat', page: 1);
      expect(http.seen.contains('https://m.51eshu.com/NotACat/'), isFalse);
      expect(http.seen.contains('https://m.51eshu.com/XuanHuan/'), isTrue,
          reason: '认不出的分类 id 退回第一个书库');

      // 详情：书名 / 封面 / 作者 / 分类 / 状态 / 简介（简介只取 .intro 第一段，
      // 后面两段是站点自动生成的水文）。
      final detail = await source.data.detail('/xs/29175.html');
      expect(detail, isNotNull);
      expect(detail!.title, '天唐锦绣');
      expect(detail.cover, 'https://img.51eshu.com/29175/18719.jpg');
      expect(detail.subtitle, contains('公子许'));
      expect(detail.subtitle, contains('历史'));
      expect(detail.subtitle, contains('连载中'));
      expect(detail.description, contains('穿越'));
      expect(detail.description, isNot(contains('是一名出色的小说作者')));
    },
    skip: skipUnless(<String>[
      '51eshu_novel.js',
      'novel_51eshu_list.html',
      'novel_51eshu_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '无忧小说网：目录 100 章（目录分页）/ 正文拼多页（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          // 目录第 1 页只到第 50 章，第 2 页接第 51–100 章（两条真实快照）。
          'https://m.51eshu.com/shu/29175/': 'novel_51eshu_index.html',
          'https://m.51eshu.com/shu/29175_2/': 'novel_51eshu_index2.html',
          // 正文：只有第 1 页的快照，第 2 页指向同一份 —— 验的是「两页都抓了、
          // 且拼起来了」（`_2.html` 也在 seen 里 + 文本出现两次）。
          'https://m.51eshu.com/shu/29175/154548834.html': 'novel_51eshu_chapter.html',
          'https://m.51eshu.com/shu/29175/154548834_2.html': 'novel_51eshu_chapter.html',
        }),
      );
      final source = await bootNovelSource('51eshu_novel.js', http: http);
      addTearDown(source.dispose);

      final chapters = await source.data.chapters('/xs/29175.html');
      expect(chapters.length, 100, reason: '两页各 50 章（第 1–50 / 第 51–100）');
      expect(chapters.first.title, '第1章 神，请让我再死一次');
      expect(chapters.last.title, '第100章 高尚的情怀');
      expect(chapters.first.id, '/shu/29175/11711427.html');
      expect(chapters.map((c) => c.id).toSet().length, 100);
      expect(http.seen.contains('https://m.51eshu.com/shu/29175_2/'), isTrue,
          reason: '目录第 2 页是 /shu/<书号>_2/（页内 select 给的地址）');

      // 正文：第 1 页 + `_2` 页按顺序拼起来。
      const sentence = '房俊回京之后必有动作';
      final content = await source.data.content(
        itemId: '/xs/29175.html',
        chapterId: '/shu/29175/154548834.html',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(1000));
      expect(
        http.seen.contains('https://m.51eshu.com/shu/29175/154548834_2.html'),
        isTrue,
        reason: '分页器里的「下一页」是 _2.html，必须跟着抓',
      );
      expect(
        sentence.allMatches(text).length,
        2,
        reason: '两页正文都要在结果里（同一份快照被拼了两次）',
      );
    },
    skip: skipUnless(<String>[
      '51eshu_novel.js',
      'novel_51eshu_index.html',
      'novel_51eshu_index2.html',
      'novel_51eshu_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
