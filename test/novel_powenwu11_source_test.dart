import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/novel_snapshot_harness.dart';

/// PO文屋（www.powenwu11.com，**GBK 编码**）：真脚本 + 真快照字节。
///
/// 快照是 2026-10-16 的原样响应（snapshots/novel_powenwu11_*.html，GBK），
/// 用例把**原始字节**喂给 HTTP 替身——这正是脚本必须自己解 GBK 的原因：
/// 宿主的 `response.body` 是 `utf8.decode(bytes, allowMalformed: true)`，
/// GBK 字节过一遍就不可逆了（非法字节变 U+FFFD），沙箱里也没有 TextDecoder。
/// 脚本唯一的路是宿主桥 `LumeBridge.invoke('http.fetch', {binary:true})` 拿 `bodyBase64`，
/// 再用内置码表解码——这条链子断了就只能报错，不能拿乱码当书名。
///
/// 这里守的是：
///   1. GBK 解码真的解出中文（书名/作者/正文/章节名），且没有替换字符混进来；
///   2. 列表页条目没有封面（封面只在详情页）；详情页封面在 `div.bookcover`（带 hidden-xs 类）；
///   3. 详情页 dl 里「最新章节」是最新在前，`div#list-chapterAll` 才是全量升序目录；
///   4. 正文页 `<title>` 自带页码「(1/2)」，第 2 页是 `89_2.html`：要顺页拼接。
void main() {
  final bridge = resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    Qjs.reclaimRuntime = false;
  }

  setUp(() => LumeJsEngine.debugSupportedOverride = true);
  tearDown(() => LumeJsEngine.debugSupportedOverride = null);

  test(
    'PO文屋：GBK 解码下的分类 / 列表 / 详情 / 全量目录（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.powenwu11.com/all.html': 'novel_powenwu11_list.html',
          'https://www.powenwu11.com/book/1/': 'novel_powenwu11_detail.html',
        }),
      );
      final source = await bootNovelSource('PO文屋.js', http: http);
      addTearDown(source.dispose);

      final categories = await source.data.categories();
      expect(categories.length, 12);
      expect(categories.first.id, 'danmei');
      expect(categories.first.title, '耽美');
      expect(
        categories.map((category) => category.id),
        containsAll(<String>['all', 'top', 'wanben']),
      );

      // 列表第 1 页：30 条，标题/作者是 GBK 解出来的中文。
      final page1 = await source.data.list(categoryId: 'all', page: 1);
      expect(page1.items.length, 30);
      expect(page1.hasMore, isTrue, reason: '分页器里写着 1/8112');
      expect(page1.items.first.id, '243134');
      expect(page1.items.first.title, '一朝云梦赴仙途 (NPH)');
      expect(page1.items.first.subtitle, contains('爱吃的阿斯卡里'));
      expect(page1.items.first.subtitle, contains('最新：'));
      for (final item in page1.items) {
        expect(RegExp(r'^\d+$').hasMatch(item.id), isTrue, reason: 'id=${item.id}');
        expect(item.title.contains('\uFFFD'), isFalse, reason: 'GBK 解码残留了替换字符：${item.title}');
        expect(item.title, isNotEmpty);
        // 列表条目不输出封面（封面只在详情页）。
        expect(item.cover ?? '', isEmpty);
      }

      // 详情：封面在带 hidden-xs 的 div.bookcover 里（og:image 是它的明文 http 版）。
      final detail = await source.data.detail('1');
      expect(detail, isNotNull);
      expect(detail!.title, '[HP同人]HP重生之记忆抹杀');
      expect(detail.description, contains('詹姆斯波特'), reason: '简介要解出 GBK 中文');
      expect(detail.subtitle, contains('醉桃歌'));
      expect(detail.subtitle, contains('49万字'));
      expect(detail.subtitle, contains('连载中'));
      expect(detail.cover, 'https://img.powenwu11.com/image/0/1/1s.jpg');
      expect(
        http.seen.contains('https://www.powenwu11.com/book/1/'),
        isTrue,
        reason: '详情页从 /book/<id>/ 取',
      );

      // 目录：`div#list-chapterAll` 的全量目录（升序 1..89）；
      // 详情页上面那 10 条「最新章节」是最新在前，不能当目录用。
      final chapters = await source.data.chapters('1');
      expect(chapters.length, 89);
      expect(chapters.first.id, '1');
      expect(chapters.first.title, '分卷阅读1');
      expect(chapters.last.id, '89');
      expect(chapters.last.title, '分卷阅读89');
      final numbers = chapters.map((chapter) => int.parse(chapter.id)).toList();
      expect(numbers, List<int>.generate(89, (index) => index + 1),
          reason: '全量目录必须严格升序 1..89');
    },
    skip: skipUnless(<String>[
      'PO文屋.js',
      'novel_powenwu11_list.html',
      'novel_powenwu11_detail.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'PO文屋：正文（多页 + 剔广告）/ 首页两截（快照）',
    () async {
      final http = SnapshotHttp(
        responses: snapshotMap(<String, String>{
          'https://www.powenwu11.com/': 'novel_powenwu11_home.html',
          'https://www.powenwu11.com/book/1/89.html': 'novel_powenwu11_chapter.html',
        }),
      );
      final source = await bootNovelSource('PO文屋.js', http: http);
      addTearDown(source.dispose);

      // 正文：第 89 章的 <title> 是「…分卷阅读89(1/2)_PO文屋」⇒ 要拼第 2 页
      // （快照只有第 1 页 ⇒ 404 停住，已抓到的正文照样可读，并把失败写进正文）。
      final content = await source.data.content(itemId: '1', chapterId: '89');
      final text = (content! as TextContent).text;
      expect(text.length, greaterThan(800));
      expect(text, contains('魔法阵'), reason: 'GBK 正文要解出中文');
      expect(text.contains('\uFFFD'), isFalse, reason: '正文里不该有替换字符');
      expect(text, contains('分卷阅读89'));
      expect(text.contains('肉肉屋'), isFalse, reason: '行尾的站点推广不是正文');
      expect(
        http.seen.contains('https://www.powenwu11.com/book/1/89_2.html'),
        isTrue,
        reason: 'title 里的 (1/2) 说明还有第 2 页，必须去拼',
      );
      expect(text, contains('第 2 页抓取失败'));

      // 首页：站点自己的「最新小说」与「最近更新」两截（都是 ul>li，没有封面）。
      final home = await source.data.home();
      expect(home.isBoards, isTrue);
      expect(home.boards.length, 2);
      expect(home.boards.first.title, '最新小说');
      expect(home.boards.first.items.first.title, '孤屿之舟（还想不告而别？再跑一个试试！1v1）');
      expect(home.boards.first.items.first.subtitle, contains('章晚昀的无毛猫'));
      expect(home.boards.last.title, '最近更新');
      expect(home.boards.last.items.first.id, '243134');
      expect(home.boards.last.items.first.subtitle, contains('爱吃的阿斯卡里'));
      for (final board in home.boards) {
        expect(board.items.length, greaterThan(10));
        for (final item in board.items) {
          expect(item.title.contains('\uFFFD'), isFalse);
        }
      }
    },
    skip: skipUnless(<String>[
      'PO文屋.js',
      'novel_powenwu11_home.html',
      'novel_powenwu11_chapter.html',
    ]),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
