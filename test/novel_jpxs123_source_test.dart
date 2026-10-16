import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// 精品小说网（jpxs123）：**gb2312 站点**，真脚本 + 真沙箱 + 快照**字节**。
///
/// 这个用例的要点是编码，别的地方都是顺带的：
///   1. 快照文件是 gb2312 原始字节。宿主网络层对 `LumeSource.http.get().body`
///      是按 **utf-8 宽松解码**（非法字节 → U+FFFD）的 —— 也就是说普通 GET 拿到
///      的字符串里，中文**已经不可恢复**。脚本必须走宿主的二进制响应
///      （`http.fetch` + `binary:true` → `bodyBase64`）拿真实字节，再用自带的
///      GBK 表解码。本用例按原始字节喂快照，走的正是这条路（真机同一条）；
///      把解码换回 utf-8 或换掉表，标题断言立刻变成乱码/替换符。
///   2. 解出来必须是**干净中文**：断言标题逐字相等、且没有任何 U+FFFD。
///   3. 列表/详情/章节的地址都要带栏目段（`/tongren/11981.html`），
///      id 直接就是站点路径 —— 断言 id 形状就是在断言 URL 拼对了。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }
  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    '精品小说网：gb2312 解码 / 分类 / 列表 / 详情（快照字节）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://jpxs123.top/tongren/': 'novel_jpxs123_list.html',
          'https://jpxs123.top/book/': 'novel_jpxs123_book.html',
          'https://jpxs123.top/tongren/11981.html': 'novel_jpxs123_detail.html',
        }),
      );
      final source = await bootNovelSource('jpxs123_novel.js', http: http);
      addTearDown(source.dispose);

      // 分类＝站点导航那 8 个入口（「精品小说」＝全部）。
      final categories = await source.data.categories();
      expect(categories.length, 8);
      expect(categories.first.id, 'book');
      expect(categories.first.title, '精品小说');
      expect(categories.map((c) => c.id), contains('tongren'));

      // 列表第 1 页：20 条，标题是**解码后的中文**（gb2312 没解对就全是替换符）。
      final page1 = await source.data.list(categoryId: 'tongren', page: 1);
      expect(page1.items.length, 20);
      expect(page1.items.first.title, '漫威：刚成祖国人，神盾局找上门',
          reason: 'gb2312 必须按字节解出干净中文；带后缀的 (1-235) 已由脚本剔掉');
      expect(page1.items.first.id, '/tongren/12649.html',
          reason: 'id 是站点路径（详情地址必须带栏目段）');
      for (final item in page1.items) {
        expect(item.title, isNotEmpty);
        expect(item.title, isNot(contains('\uFFFD')),
            reason: '标题里不许出现替换符（说明字节解错了）');
        expect(item.title, isNot(matches(RegExp(r'[（(]\d+-\d+[)）]$'))),
            reason: '站点加在标题尾部的 (1-235) 统计尾巴要剔掉');
        expect(item.id, startsWith('/tongren/'));
        expect(item.cover, isNotNull);
        expect(item.cover!.startsWith('https://jpxs123.top/d/file/p/'), isTrue,
            reason: '封面是站内相对地址，按站点地址补全');
      }
      expect(page1.items[1].title, '地错，开局流星一条！');
      expect(page1.hasMore, isTrue, reason: '分页器里有 index_2…index_10');

      // 「精品小说」（/book/）走的是同一套标记。
      final all = await source.data.list(categoryId: 'book', page: 1);
      expect(all.items.length, 20);
      expect(all.items.first.title, isNot(contains('\uFFFD')));

      // 详情：书名（尾部的 (1-183) 剔掉）、封面、简介。
      final detail = await source.data.detail('/tongren/11981.html');
      expect(detail, isNotNull);
      expect(detail!.title, '综漫：从日常开始种神树！');
      expect(detail.cover, isNotNull);
      expect(detail.cover!.startsWith('https://jpxs123.top/d/file/p/'), isTrue);
      expect(detail.subtitle, contains('渣茶'));
      expect(detail.description, contains('夏川'));
      expect(detail.description, isNot(contains('\uFFFD')));
    },
    skip: skipUnless(<String>[
      'jpxs123_novel.js',
      'novel_jpxs123_list.html',
      'novel_jpxs123_book.html',
      'novel_jpxs123_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '精品小说网：目录 298 节升序 / 正文（快照字节）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://jpxs123.top/tongren/11981.html': 'novel_jpxs123_detail.html',
          'https://jpxs123.top/tongren/11981/2.html': 'novel_jpxs123_chapter.html',
        }),
      );
      final source = await bootNovelSource('jpxs123_novel.js', http: http);
      addTearDown(source.dispose);

      // 目录就在详情页里：`div.book_list ul li a`，完整、旧→新。
      final chapters = await source.data.chapters('/tongren/11981.html');
      expect(chapters.length, 298);
      expect(chapters.first.title, '第1节');
      expect(chapters.last.title, '第298节');
      expect(chapters.first.id, '/tongren/11981/1.html');
      expect(chapters.map((c) => c.id).toSet().length, 298);
      expect(chapters.every((c) => !c.title.contains('\uFFFD')), isTrue);

      // 正文：`div.read_chapterDetail` 的 `<p>`（快照是第 2 节）。
      final content = await source.data.content(
        itemId: '/tongren/11981.html',
        chapterId: '/tongren/11981/2.html',
      );
      expect(content, isA<TextContent>());
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(500));
      expect(text, contains('宫水神社'));
      expect(text, isNot(contains('\uFFFD')), reason: '正文也不许有替换符');
      expect(text, contains('\n'));
    },
    skip: skipUnless(<String>[
      'jpxs123_novel.js',
      'novel_jpxs123_detail.html',
      'novel_jpxs123_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
