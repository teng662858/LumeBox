import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/speech/speech.dart';

/// 朗读切分的验证：片段覆盖完整、起点可换算、断点自然、长度受控。
///
/// 这套逻辑是「跟读翻页」的地基：引擎回报的位置是相对片段的，只有起点记对了，
/// 才能换算回整章偏移。因此这里断言的重点是**覆盖性与换算一致性**，
/// 而不是某个具体的切分点。
void main() {
  /// 断言片段在原文里首尾相接、不重不漏（空白除外）。
  void expectCovers(String text, List<SpeechSegment> segments) {
    if (segments.isEmpty) {
      expect(text.trim(), isEmpty, reason: '无片段只允许出现在纯空白文本上');
      return;
    }
    for (final segment in segments) {
      expect(
        text.substring(segment.start, segment.end),
        segment.text,
        reason: '片段内容必须与 [start, end) 的切片一致（换算靠它）',
      );
    }
    for (var i = 1; i < segments.length; i++) {
      expect(
        segments[i].start,
        greaterThanOrEqualTo(segments[i - 1].end),
        reason: '片段按顺序且不重叠（硬断时首尾相接，允许相等）',
      );
    }
    // 首个片段之前、末个片段之后的原文只允许是空白。
    expect(text.substring(0, segments.first.start).trim(), isEmpty);
    expect(text.substring(segments.last.end).trim(), isEmpty);
  }

  group('基本切分', () {
    test('空文本与纯空白不产出片段', () {
      expect(SpeechSegments.split(''), isEmpty);
      expect(SpeechSegments.split('   \n\t  '), isEmpty);
    });

    test('短文本整段一片', () {
      const text = '第一段。\n第二段。';
      final segments = SpeechSegments.split(text);
      expect(segments, hasLength(1));
      expect(segments.single.start, 0);
      expect(segments.single.text, text);
      expectCovers(text, segments);
    });

    test('段落边界优先于长度：整章切成多片且每片起点准确', () {
      // 每段 30 字，共 20 段（600 字）；上限 200 字 → 约 3~4 片。
      final paragraphs = <String>[
        for (var i = 1; i <= 20; i++) '第 $i 段：${'内容' * 13}。',
      ];
      final text = paragraphs.join('\n');
      final segments = SpeechSegments.split(text, maxChars: 200);

      expect(segments.length, greaterThan(1), reason: '超过上限必须切开');
      expectCovers(text, segments);
      for (final segment in segments) {
        expect(
          segment.text.length,
          lessThanOrEqualTo(200),
          reason: '单片不得超过上限',
        );
      }
    });

    test('切片点落在段落末尾，不把段落从中间劈开', () {
      final text = <String>[
        '第一段内容' * 10,
        '第二段内容' * 10,
        '第三段内容' * 10,
      ].join('\n');
      final segments = SpeechSegments.split(text, maxChars: 60);

      expect(segments.length, greaterThan(1));
      for (final segment in segments.take(segments.length - 1)) {
        expect(
          segment.text.endsWith('容') || segment.text.endsWith('。'),
          isTrue,
          reason: '非末片应断在段末或句末，实际结尾：${segment.text.substring(segment.text.length - 4)}',
        );
      }
      expectCovers(text, segments);
    });
  });

  group('句末断点', () {
    test('长段内优先在句号后断开', () {
      // 一段无换行的长文本：只有句号可断。
      final text = '${'甲' * 30}。${'乙' * 30}。${'丙' * 30}。${'丁' * 30}。';
      final segments = SpeechSegments.split(text, maxChars: 70);

      expect(segments.length, greaterThan(1));
      for (final segment in segments.take(segments.length - 1)) {
        expect(segment.text.endsWith('。'), isTrue, reason: '应断在句号后');
      }
      expectCovers(text, segments);
    });

    test('句末的收尾引号跟着上一句一起断', () {
      final text = '${'甲' * 40}。“${'乙' * 40}。”${'丙' * 40}。';
      final segments = SpeechSegments.split(text, maxChars: 60);

      // 要求：收尾引号不能被单独甩到下一片的开头（那会让下一片以标点起头），
      // 而应当跟着它闭合的那句话留在上一片末尾。
      for (final segment in segments) {
        expect(
          segment.text.startsWith('”') || segment.text.startsWith('』'),
          isFalse,
          reason: '片段不该以收尾引号开头，实际：${segment.text.substring(0, 2)}',
        );
      }
      final withQuote = segments.where((s) => s.text.endsWith('”'));
      expect(withQuote, isNotEmpty, reason: '引号应留在它闭合的那句末尾');
      expectCovers(text, segments);
    });

    test('没有任何标点时按长度硬断，不超上限', () {
      final text = '甲' * 500;
      final segments = SpeechSegments.split(text, maxChars: 120);

      expect(segments.length, greaterThan(1));
      for (final segment in segments) {
        expect(segment.text.length, lessThanOrEqualTo(120));
        expect(segment.text, isNotEmpty);
      }
      expectCovers(text, segments);
    });

    test('单片上限非法时收敛到 1（不会死循环）', () {
      final segments = SpeechSegments.split('甲乙丙丁', maxChars: 0);
      expect(segments, isNotEmpty);
      expectCovers('甲乙丙丁', segments);
    });
  });

  group('断点续听（fromOffset）', () {
    test('跳过起点之前的内容，且首片起点不小于起点', () {
      final text = <String>[
        for (var i = 1; i <= 10; i++) '第 $i 段：${'内容' * 8}。',
      ].join('\n');
      final all = SpeechSegments.split(text, maxChars: 100);
      final from = all[2].start;
      final resumed = SpeechSegments.split(text, fromOffset: from, maxChars: 100);

      expect(resumed.first.start, greaterThanOrEqualTo(from));
      expect(resumed.length, lessThan(all.length));
      expect(
        text.substring(resumed.first.start, resumed.first.end),
        resumed.first.text,
        reason: '续听片段的换算同样成立',
      );
      expect(text.substring(resumed.last.end).trim(), isEmpty);
    });

    test('起点越界时返回空（不会抛错）', () {
      expect(SpeechSegments.split('甲乙丙', fromOffset: 99), isEmpty);
      expect(SpeechSegments.split('甲乙丙', fromOffset: -5), isNotEmpty);
    });

    test('起点落在空白处时前移到第一个非空白字符', () {
      const text = '第一段。\n\n\n第二段。';
      // 下标：0..3 是「第一段。」，4/5/6 是三个换行，7 起是「第二段。」
      final segments = SpeechSegments.split(text, fromOffset: 4, maxChars: 500);
      expect(segments.single.start, 7, reason: '跳过换行，从「第」开始');
      expect(segments.single.text, '第二段。');
    });
  });

  group('片段不变量', () {
    test('片段的 start + text.length == end（位置换算恒等式）', () {
      final text = <String>[
        for (var i = 1; i <= 12; i++) '段落 $i：${'字' * 25}。',
      ].join('\n\n');
      for (final segment in SpeechSegments.split(text, maxChars: 150)) {
        expect(segment.start + segment.text.length, segment.end);
        expect(segment.isSpeakable, isTrue);
      }
    });

    test('首尾空白不会混进片段（否则位置会偏）', () {
      const text = '   前面有空格的内容。\n\n   后面也有。   ';
      for (final segment in SpeechSegments.split(text, maxChars: 10)) {
        expect(segment.text, segment.text.trim());
      }
    });

    test('全角空格也视为空白', () {
      const text = '第一段。\u3000\u3000第二段。';
      final segments = SpeechSegments.split(text, maxChars: 500);
      expect(segments.single.text, contains('第二段'));
      expect(segments.single.text.startsWith('\u3000'), isFalse);
    });

    test('大章节（5000 字）切分后覆盖完整', () {
      final text = <String>[
        for (var i = 1; i <= 100; i++) '第 $i 段：${'内容内容' * 6}。',
      ].join('\n');
      final segments = SpeechSegments.split(text);
      expect(segments.length, greaterThan(1));
      expectCovers(text, segments);
      for (final segment in segments) {
        expect(segment.text.length, lessThanOrEqualTo(SpeechSegments.defaultMaxChars));
      }
    });
  });
}
