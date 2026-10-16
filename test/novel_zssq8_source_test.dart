import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 追书神器吧（zssq8）：真脚本 + 真 QuickJS 沙箱 + 快照应答。
///
/// 守的是四件**不看真页面就发现不了**的事：
///   1. 三套分页形状各不相同：书库 `/listN/`、排行 `/top/`+`/top/all_0_<N>.html`、
///      完本 `/full/`+`/full/0_<N>.html`（写成 `/full/<N>.html` 就是 404）；
///   2. 列表条目是 `dl > dt > a > img` + `dd > h3 > a`，封面是站内相对地址；
///   3. 目录**详情页与 `/book/<id>/index_1.html` 是同一份页面**（实测字节相同），
///      第 1 页给 100 章、分页 1/9；翻页失败只当空页，不能把整本目录废掉；
///   4. 正文在 `<article class="font_max">` 里、用 `<br><br>` 分段。
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
    '追书神器吧：分类 / 列表 / 三套分页 / 详情（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.zssq8.cc/list1/': 'novel_zssq8_list.html',
          'https://www.zssq8.cc/list1/2.html': 'novel_zssq8_list_p2.html',
          'https://www.zssq8.cc/full/': 'novel_zssq8_full.html',
          // 完本第 2 页的真实地址（快照只有第 1 页，用同一份内容证明**地址形状**）。
          'https://www.zssq8.cc/full/0_2.html': 'novel_zssq8_full.html',
          'https://www.zssq8.cc/top/': 'novel_zssq8_top.html',
          'https://www.zssq8.cc/top/all_0_2.html': 'novel_zssq8_top.html',
          'https://www.zssq8.cc/book/130137/': 'novel_zssq8_detail.html',
          // 目录第 1 页（与详情页同一份页面）。
          'https://www.zssq8.cc/book/130137/index_1.html': 'novel_zssq8_detail.html',
        }),
      );
      final source = await bootNovelSource('zssq8_novel.js', http: http);
      addTearDown(source.dispose);

      // 分类＝8 个书库 + 排行 + 完本。
      final categories = await source.data.categories();
      expect(categories.length, 10);
      expect(categories.first.id, 'list1');
      expect(categories.first.title, '玄幻');
      expect(categories.map((c) => c.id), contains('top'));
      expect(categories.map((c) => c.id), contains('full'));

      // 书库第 1 页：20 条、封面都是站内相对地址补全后的 https。
      final page1 = await source.data.list(categoryId: 'list1', page: 1);
      expect(page1.items.length, 20);
      for (final item in page1.items) {
        expect(item.id, matches(RegExp(r'^\d+$')), reason: 'id 是书号');
        expect(item.id, isNotEmpty);
        expect(item.title, isNotEmpty);
        expect(item.cover, isNotNull);
        expect(item.cover!.startsWith('https://www.zssq8.cc/'), isTrue,
            reason: '封面是相对地址 /images/…，必须按站点地址补全且升到 https');
      }
      expect(page1.items.first.title, '八零易孕懒娇娘，绝嗣大佬追着要');
      expect(page1.hasMore, isTrue, reason: '分页器写着 1/855');

      // 第 2 页：地址形状 /list1/2.html，内容必须换了一批。
      final page2 = await source.data.list(categoryId: 'list1', page: 2);
      expect(page2.items.length, 20);
      final firstIds = page1.items.map((item) => item.id).toSet();
      expect(page2.items.any((item) => firstIds.contains(item.id)), isFalse,
          reason: '第 2 页必须是另一批书');

      // 排行 / 完本：条目同为 dl 标记，但**分页地址形状不同**。
      final full = await source.data.list(categoryId: 'full', page: 1);
      expect(full.items.length, 30);
      expect(full.items.first.cover, isNotNull);
      expect(full.hasMore, isTrue);
      await source.data.list(categoryId: 'full', page: 2);
      expect(
        http.seen.contains('https://www.zssq8.cc/full/0_2.html'),
        isTrue,
        reason: '完本第 2 页是 /full/0_2.html（/full/2.html 会 404）',
      );

      final top = await source.data.list(categoryId: 'top', page: 1);
      expect(top.items.length, 30);
      // 排行/完本的标题带站点自己的 [分类] 前缀（与书库页不同），如实保留。
      expect(top.items.first.title, '[历史]迷魂阵');
      await source.data.list(categoryId: 'top', page: 2);
      expect(
        http.seen.contains('https://www.zssq8.cc/top/all_0_2.html'),
        isTrue,
        reason: '排行第 2 页是 /top/all_0_2.html',
      );

      // 详情：书名 / 封面 / 简介。
      final detail = await source.data.detail('130137');
      expect(detail, isNotNull);
      expect(detail!.title, '华娱：满级导演但歌手出道');
      expect(detail.cover, isNotNull);
      expect(detail.cover!.startsWith('https://www.zssq8.cc/images/'), isTrue);
      expect(detail.subtitle, contains('青光辉'));
      expect(detail.subtitle, contains('连载'));
      expect(detail.description, contains('重生在98年代'));
    },
    skip: skipUnless(<String>[
      'zssq8_novel.js',
      'novel_zssq8_list.html',
      'novel_zssq8_list_p2.html',
      'novel_zssq8_full.html',
      'novel_zssq8_top.html',
      'novel_zssq8_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '追书神器吧：目录 100 章升序 / 正文（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.zssq8.cc/book/130137/index_1.html': 'novel_zssq8_detail.html',
          'https://www.zssq8.cc/book/130137/537787.html': 'novel_zssq8_chapter.html',
        }),
      );
      final source = await bootNovelSource('zssq8_novel.js', http: http);
      addTearDown(source.dispose);

      // 目录：第 1 页 100 章（旧→新）。页内写着 1/9，于是脚本还会去抓 index_2…9
      // ——快照里没有这些页，替身回 404；脚本必须**当作空页跳过**而不是抛错。
      final chapters = await source.data.chapters('130137');
      expect(chapters.length, 100);
      expect(chapters.first.title, startsWith('第1章'));
      expect(chapters.last.title, '第99章 什么才是自由？');
      expect(chapters.map((c) => c.id).toSet().length, 100, reason: '章节 id 不能重号');
      expect(
        http.seen.contains('https://www.zssq8.cc/book/130137/index_2.html'),
        isTrue,
        reason: '分页 1/9 说明还有第 2 页，脚本要去抓（失败了才降级）',
      );
      final numbers = chapters
          .map((c) => int.tryParse(c.id) ?? 0)
          .toList();
      expect(numbers, orderedEquals(<int>[...numbers]..sort()),
          reason: '目录必须按章节号升序（阅读器的下一章按这个顺序走）');

      // 正文：`<article class="font_max">`，段落之间是 <br><br>。
      // 快照抓的是第 838 章（章节号 537787）；目录第 1 页只到第 100 章，
      // 所以这里直接用快照自己那一章，验的是正文解析而不是章节对应。
      final content = await source.data.content(
        itemId: '130137',
        chapterId: '537787',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(400));
      expect(text, contains('郑弦'), reason: '正文首段是「郑弦眨巴着大眼睛」');
      expect(text, contains('\n'), reason: '段落之间要保留换行');
    },
    skip: skipUnless(<String>[
      'zssq8_novel.js',
      'novel_zssq8_detail.html',
      'novel_zssq8_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
