import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/novel/novel_pagination.dart';
import 'package:lume_box/features/novel/novel_typesetting.dart';

/// 小说分页引擎的验证：规范化、分页覆盖面、字符偏移映射、缓存与排版参数联动。
///
/// 这些断言对着真实 TextPainter 的断行结果，因此是「排版是否正确」而不是
/// 「代码是否跑通」：任何让页面接不上、字符丢失的改动都会在这里失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewport = Size(360, 640);
  const typesetting = NovelTypesetting();

  String buildChapter(int paragraphs) => List<String>.generate(
        paragraphs,
        (index) =>
            '第${index + 1}段：' '这一段的用途是验证分页引擎，因此需要足够长的中文文本，'
            '让每一段都能折成多行，并且能在页与页之间断开。',
      ).join('\n');

  group('章节文本规范化', () {
    test('段落、偏移与长度按归一后的文本给出', () {
      final text = NovelChapterText.parse('甲\n\n乙\n   \n丙\n');

      expect(text.paragraphs, <String>['甲', '乙', '丙']);
      // 段间各占一个换行符，因此第二段起点是 2，第三段起点是 4。
      expect(text.offsets, <int>[0, 2, 4]);
      // 归一后的文本就是「甲\n乙\n丙」，长度 5。
      expect(text.length, 5);
      expect(text.text, '甲\n乙\n丙');
    });

    test('空文本与空白文本得到空结果', () {
      expect(NovelChapterText.parse('').isEmpty, isTrue);
      expect(NovelChapterText.parse('\n\n  \n').isEmpty, isTrue);
    });
  });

  group('分页', () {
    final paginator = const NovelPaginator();

    test('页与页首尾相接，且完整覆盖整章', () {
      final text = NovelChapterText.parse(buildChapter(12));
      final pagination = paginator.paginate(
        chapterId: 'c1',
        text: text,
        viewport: viewport,
        typesetting: typesetting,
      );

      expect(pagination.pageCount, greaterThan(1));
      expect(pagination.pages.first.charStart, 0);
      expect(pagination.pages.last.charEnd, text.length);
      for (var index = 0; index < pagination.pageCount - 1; index++) {
        final gap = pagination.pages[index + 1].charStart -
            pagination.pages[index].charEnd;
        // 段中断页时两页严丝合缝（gap = 0）；段末断页时只隔一个段间换行符
        // （该换行符不参与渲染，不属于任何页，因此 gap = 1）。
        expect(gap, anyOf(0, 1), reason: '第 $index 页与下一页之间不重不漏');
      }
      // 每页都必须有内容，不能出现空页。
      for (final page in pagination.pages) {
        expect(page.isEmpty, isFalse, reason: '第 ${page.index} 页不应为空页');
      }
    });

    test('切片按纵向顺序排列，且不越出段落边界', () {
      final text = NovelChapterText.parse(buildChapter(6));
      final pagination = paginator.paginate(
        chapterId: 'c2',
        text: text,
        viewport: viewport,
        typesetting: typesetting,
      );

      for (final page in pagination.pages) {
        var lastDy = -1.0;
        for (final segment in page.segments) {
          expect(segment.dy, greaterThanOrEqualTo(lastDy));
          lastDy = segment.dy;
          expect(segment.start, greaterThanOrEqualTo(0));
          expect(
            segment.end,
            lessThanOrEqualTo(text.paragraphs[segment.paragraphIndex].length),
          );
          expect(segment.end, greaterThan(segment.start));
        }
      }
    });

    test('字号变大页数变多，视口变高页数变少', () {
      final text = NovelChapterText.parse(buildChapter(10));

      int pagesFor({required Size size, required NovelTypesetting ts}) =>
          paginator
              .paginate(
                chapterId: 'c3',
                text: text,
                viewport: size,
                typesetting: ts,
              )
              .pageCount;

      final base = pagesFor(size: viewport, ts: typesetting);
      final bigger = pagesFor(
        size: viewport,
        ts: typesetting.copyWith(fontSize: 26),
      );
      final wider = pagesFor(
        size: const Size(360, 1200),
        ts: typesetting,
      );

      expect(bigger, greaterThan(base));
      expect(wider, lessThan(base));
    });

    test('字符偏移映射：首字符在第一页，末字符在最后一页', () {
      final text = NovelChapterText.parse(buildChapter(10));
      final pagination = paginator.paginate(
        chapterId: 'c4',
        text: text,
        viewport: viewport,
        typesetting: typesetting,
      );

      expect(pagination.pageIndexForChar(0), 0);
      expect(
        pagination.pageIndexForChar(text.length - 1),
        pagination.pageCount - 1,
      );
      // 单调不减：偏移越大，页序号不会回退。
      var previous = 0;
      for (var offset = 0; offset < text.length; offset += 7) {
        final page = pagination.pageIndexForChar(offset);
        expect(page, greaterThanOrEqualTo(previous));
        expect(page, lessThan(pagination.pageCount));
        previous = page;
      }
    });

    test('每页起始字符都能反查回同一页（进度可精确还原）', () {
      final text = NovelChapterText.parse(buildChapter(8));
      final pagination = paginator.paginate(
        chapterId: 'c5',
        text: text,
        viewport: viewport,
        typesetting: typesetting,
      );

      for (final page in pagination.pages) {
        expect(pagination.pageIndexForChar(page.charStart), page.index);
      }
    });

    test('换排版参数或视口会得到新的分页键', () {
      const defaultKey = 'chapter@360x640';
      final keyA = ChapterPagination.cacheKey(
        chapterId: 'c',
        viewport: viewport,
        typesetting: typesetting,
      );
      final keyB = ChapterPagination.cacheKey(
        chapterId: 'c',
        viewport: viewport,
        typesetting: typesetting.copyWith(fontSize: 20),
      );
      final keyC = ChapterPagination.cacheKey(
        chapterId: 'c',
        viewport: const Size(400, 640),
        typesetting: typesetting,
      );

      expect(keyA, isNot(keyB));
      expect(keyA, isNot(keyC));
      expect(keyA, isNot(defaultKey));
      expect(keyA, contains('c@360x640'));
    });
  });

  group('排版缓存', () {
    test('文本缓存按条目上限淘汰，字符计数同步', () {
      final cache = NovelLayoutCache(
        maxTextEntries: 2,
        maxTextChars: 1024 * 1024,
        maxPaginationEntries: 1,
      );
      final a = NovelChapterText.parse('甲' * 50);
      final b = NovelChapterText.parse('乙' * 50);
      final c = NovelChapterText.parse('丙' * 50);

      cache.putText('a', a);
      cache.putText('b', b);
      expect(cache.text('a'), isNotNull); // 命中 a，使其成为最近使用
      cache.putText('c', c);

      expect(cache.text('a'), isNotNull);
      expect(cache.text('b'), isNull, reason: '最久未使用的 b 应被淘汰');
      expect(cache.textCount, 2);
      expect(cache.textChars, a.length + c.length);

      cache.clear();
      expect(cache.textCount, 0);
      expect(cache.textChars, 0);
    });

    test('分页缓存按章节 + 几何参数分别命中', () {
      final cache = NovelLayoutCache(maxPaginationEntries: 1);
      final text = NovelChapterText.parse('正文' * 200);
      final pagination = const NovelPaginator().paginate(
        chapterId: 'c',
        text: text,
        viewport: viewport,
        typesetting: typesetting,
      );

      cache.putPagination(pagination);
      expect(cache.pagination(pagination.key), isNotNull);
      expect(
        cache.pagination(
          ChapterPagination.cacheKey(
            chapterId: 'c',
            viewport: viewport,
            typesetting: typesetting.copyWith(margin: 30),
          ),
        ),
        isNull,
      );
    });
  });
}
