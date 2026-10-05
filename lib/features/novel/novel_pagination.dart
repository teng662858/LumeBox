import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'novel_typesetting.dart';

/// 规范化后的章节文本。
///
/// 排版前先归一：统一换行符、去掉空白行（空行由段间距表达，不占页面）。
/// 归一后的文本是**字符偏移的唯一坐标系**——阅读进度、页码、书签位置都以它为准，
/// 与图源给的原始字符串无关（原始串的换行风格各不相同）。
class NovelChapterText {
  const NovelChapterText._(this.paragraphs, this.offsets, this.length);

  /// 段落列表（已去掉空白段）。
  final List<String> paragraphs;

  /// `offsets[i]` = 第 i 段在全文中的起始字符下标。
  final List<int> offsets;

  /// 全文长度（含段间换行符）。
  final int length;

  bool get isEmpty => paragraphs.isEmpty;

  /// 全文（段间以 `\n` 连接）。仅用于落缓存或调试，渲染按段落切片。
  String get text => paragraphs.join('\n');

  /// 由原始章节文本构造。空文本得到空结果。
  static NovelChapterText parse(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final paragraphs = <String>[];
    final offsets = <int>[];
    var cursor = 0;
    for (final line in normalized.split('\n')) {
      final paragraph = line.trim();
      if (paragraph.isEmpty) continue;
      offsets.add(cursor);
      paragraphs.add(paragraph);
      cursor += paragraph.length + 1; // 段间换行符占一个字符
    }
    return NovelChapterText._(
      List<String>.unmodifiable(paragraphs),
      List<int>.unmodifiable(offsets),
      // 末尾的段间换行符不属于任何段落，长度按实际文本算。
      paragraphs.isEmpty ? 0 : cursor - 1,
    );
  }

  static final NovelChapterText empty =
      NovelChapterText._(const <String>[], const <int>[], 0);
}

/// 一页中的一段切片：指向原段落的字符区间与页内纵向位置。
///
/// 渲染时按 [start]..[end] 裁出该段的这一部分单独排版——裁剪点落在原排版的
/// 行首，因此重新排版后的断行与整段排版完全一致，省下「整章重新排版」的开销。
class NovelTextSegment {
  const NovelTextSegment({
    required this.paragraphIndex,
    required this.start,
    required this.end,
    required this.dy,
  });

  /// 段落下标（指向 [NovelChapterText.paragraphs]）。
  final int paragraphIndex;

  /// 段落内字符起点（含）。
  final int start;

  /// 段落内字符终点（不含）。
  final int end;

  /// 该段在正文内容区内的纵向偏移。
  final double dy;

  @override
  String toString() =>
      'Segment(p$paragraphIndex, $start..$end @${dy.toStringAsFixed(1)})';
}

/// 一页。
class NovelPage {
  const NovelPage({
    required this.index,
    required this.segments,
    required this.charStart,
    required this.charEnd,
  });

  final int index;

  /// 本页按纵向顺序排列的段落切片。
  final List<NovelTextSegment> segments;

  /// 本页起点在全文中的字符下标（进度就记它）。
  final int charStart;

  /// 本页终点在全文中的字符下标（不含）。
  final int charEnd;

  bool get isEmpty => segments.isEmpty;

  @override
  String toString() =>
      'NovelPage($index, chars $charStart..$charEnd, ${segments.length} 段)';
}

/// 一次分页的完整结果。
///
/// 字符区间约定：页区间只覆盖**真正被渲染的字符**。段间的换行符不参与渲染
/// （换行由段间距表达），因此它不属于任何页——页与页之间最多隔一个换行符，
/// 除此之外不重不漏。
class ChapterPagination {
  const ChapterPagination({
    required this.key,
    required this.text,
    required this.pages,
  });

  /// 缓存键：章节 + 视口 + 排版参数。参数一变即视为另一次分页。
  final String key;

  final NovelChapterText text;

  final List<NovelPage> pages;

  int get pageCount => pages.length;

  /// 取第 [index] 页；空分页（空章）时返回一个空页而不是抛错。
  ///
  /// 空章是正常输入（图源返回空白章节），阅读器仍会走「保存进度」等路径——
  /// 那些路径不该因为「没有页」而崩。
  NovelPage pageAt(int index) {
    if (pages.isEmpty) {
      return const NovelPage(
        index: 0,
        segments: <NovelTextSegment>[],
        charStart: 0,
        charEnd: 0,
      );
    }
    return pages[index.clamp(0, pages.length - 1)];
  }

  /// 字符偏移 → 页序号。二分查找：取最后一个 `charStart <= offset` 的页。
  int pageIndexForChar(int charOffset) {
    if (pages.isEmpty) return 0;
    var low = 0;
    var high = pages.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (pages[mid].charStart <= charOffset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// 第 index 页读完后在整章里的进度 0..1（按字符算，比按页数准）。
  double charRatio(int index) {
    if (pages.isEmpty || text.length <= 0) return 0;
    return (pages[index.clamp(0, pages.length - 1)].charEnd / text.length)
        .clamp(0.0, 1.0);
  }

  /// 缓存键：章节 id + 视口尺寸 + 排版签名 + 版面开关。
  ///
  /// 版面开关（是否预留页眉页脚、页首是否补段间距）算进键里，是因为它们会
  /// 改变分页结果——连续滚动与分页翻页因此各有一份缓存，互不污染。
  static String cacheKey({
    required String chapterId,
    required Size viewport,
    required NovelTypesetting typesetting,
    bool reserveChrome = true,
    bool leadingParagraphSpacing = false,
  }) =>
      '$chapterId@${viewport.width.round()}x${viewport.height.round()}'
      '#${typesetting.signature}'
      '${reserveChrome ? '' : '#nochrome'}'
      '${leadingParagraphSpacing ? '#lead' : ''}';
}

/// 分页引擎：把章节文本按视口与排版参数切成页。
///
/// 做法是「以 TextPainter 为断行原语，自己做版面」：
/// 1. 逐段用 [TextPainter] 排一次，拿到行度量（[LineMetrics]）；
/// 2. 逐行累加高度，超出内容区高度即换页；行是分页的最小单位，
///    段落可以在页中断开；
/// 3. 行首字符通过 `getPositionForOffset` 反查（取行中点求位置，避免落在
///    行边界上产生歧义），于是每页、每段切片都能精确对应到字符区间。
///
/// 这样渲染一页只需要排「这一页可见的几段」，不必重排整章；进度也能精确到
/// 字符偏移（宪法要求的小说进度口径）。
class NovelPaginator {
  const NovelPaginator();

  /// 浮点误差容忍：行高累加与内容区高度比较时留半像素。
  static const double _epsilon = 0.5;

  /// [reserveChrome]：是否预留页眉页脚（连续滚动模式不预留）。
  /// [leadingParagraphSpacing]：页首是否也补段间距（连续滚动模式需要，
  /// 否则跨页的段落在视觉上会挤在一起）。
  ChapterPagination paginate({
    required String chapterId,
    required NovelChapterText text,
    required Size viewport,
    required NovelTypesetting typesetting,
    bool reserveChrome = true,
    bool leadingParagraphSpacing = false,
  }) {
    final content = typesetting.contentSize(viewport, reserveChrome: reserveChrome);
    final builder = _PageBuilder(
      text: text,
      contentHeight: content.height,
      paragraphSpacing: typesetting.paragraphSpacing,
      leadingParagraphSpacing: leadingParagraphSpacing,
    );
    final style = typesetting.baseStyle;
    for (var index = 0; index < text.paragraphs.length; index++) {
      final paragraph = text.paragraphs[index];
      final painter = TextPainter(
        text: TextSpan(text: paragraph, style: style),
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: content.width);
      final metrics = painter.computeLineMetrics();
      final lineStarts = <int>[];
      final lineHeights = <double>[];
      var top = 0.0;
      for (final metric in metrics) {
        final middle = top + metric.height / 2;
        lineStarts.add(painter.getPositionForOffset(Offset(0, middle)).offset);
        lineHeights.add(metric.height);
        top += metric.height;
      }
      painter.dispose();
      if (lineHeights.isEmpty) continue;
      builder.appendParagraph(
        paragraphIndex: index,
        lineStarts: lineStarts,
        lineHeights: lineHeights,
        paragraphLength: paragraph.length,
      );
    }
    builder.flush();
    return ChapterPagination(
      key: ChapterPagination.cacheKey(
        chapterId: chapterId,
        viewport: viewport,
        typesetting: typesetting,
        reserveChrome: reserveChrome,
        leadingParagraphSpacing: leadingParagraphSpacing,
      ),
      text: text,
      pages: List<NovelPage>.unmodifiable(builder.pages),
    );
  }
}

/// 分页过程中的页装配器：维护「当前页已用高度」与「本页切片」。
class _PageBuilder {
  _PageBuilder({
    required this.text,
    required this.contentHeight,
    required this.paragraphSpacing,
    this.leadingParagraphSpacing = false,
  });

  final NovelChapterText text;
  final double contentHeight;
  final double paragraphSpacing;

  /// 页首也补段间距（连续滚动模式）。
  final bool leadingParagraphSpacing;

  final List<NovelPage> pages = <NovelPage>[];
  final List<NovelTextSegment> _segments = <NovelTextSegment>[];
  double _y = 0;

  bool get _hasContent => _segments.isNotEmpty;

  /// 追加一段：按行切分到当前页，放不下就换页续排。
  void appendParagraph({
    required int paragraphIndex,
    required List<int> lineStarts,
    required List<double> lineHeights,
    required int paragraphLength,
  }) {
    int? openStart;
    var openTop = 0.0;
    for (var line = 0; line < lineHeights.length; line++) {
      final height = lineHeights[line];
      if (openStart == null) {
        // 段落起始：段间距只在页中生效，页首不加（连续滚动模式例外）；
        // 若「段间距 + 首行」都放不下，先换页再判断。
        var spacing =
            (leadingParagraphSpacing || _hasContent) ? paragraphSpacing : 0.0;
        if (_hasContent &&
            _y + spacing + height > contentHeight + NovelPaginator._epsilon) {
          _flush();
          spacing = leadingParagraphSpacing ? paragraphSpacing : 0.0;
        }
        _y += spacing;
        openStart = lineStarts[line];
        openTop = _y;
      } else if (_y + height > contentHeight + NovelPaginator._epsilon) {
        // 本页放不下这一行：收束当前切片，换页继续。
        _segments.add(
          NovelTextSegment(
            paragraphIndex: paragraphIndex,
            start: openStart,
            end: lineStarts[line],
            dy: openTop,
          ),
        );
        _flush();
        openStart = lineStarts[line];
        openTop = _y;
      }
      _y += height;
    }
    if (openStart != null) {
      _segments.add(
        NovelTextSegment(
          paragraphIndex: paragraphIndex,
          start: openStart,
          end: paragraphLength,
          dy: openTop,
        ),
      );
    }
  }

  /// 结束当前页（内容为空时不产生空页）。
  void flush() => _flush();

  void _flush() {
    if (_segments.isEmpty) return;
    final first = _segments.first;
    final last = _segments.last;
    pages.add(
      NovelPage(
        index: pages.length,
        segments: List<NovelTextSegment>.unmodifiable(_segments),
        charStart: text.offsets[first.paragraphIndex] + first.start,
        charEnd: text.offsets[last.paragraphIndex] + last.end,
      ),
    );
    _segments.clear();
    _y = 0;
  }
}

/// 章节文本与分页结果的缓存：小说「大章节」的两个热点都在这里。
///
/// - 文本缓存：避免反复切章时重新规范化字符串；
/// - 分页缓存：排版是本章最贵的一步（逐段 TextPainter），
///   以「章节 + 视口 + 排版参数」为键记住结果，翻页、切主题、旋转都不重排。
///
/// 两者都按条目数 + 字符预算做 LRU：大章节不会把内存顶穿。
class NovelLayoutCache {
  NovelLayoutCache({
    // 6 = 当前章 + 前后各 2 章预取 + 1 章余量：预取深度是 2（见阅读器的
    // `_prefetchDepth`），缓存条目数必须容得下它，否则预取刚放进来的章
    // 会被下一次预取挤掉，等于白拉。
    this.maxTextEntries = 6,
    this.maxTextChars = 600 * 1024,
    this.maxPaginationEntries = 3,
  });

  final int maxTextEntries;
  final int maxTextChars;
  final int maxPaginationEntries;

  final Map<String, NovelChapterText> _texts = <String, NovelChapterText>{};
  final Map<String, ChapterPagination> _paginations =
      <String, ChapterPagination>{};

  int _textChars = 0;

  /// 已缓存的章节文本数（测试与日志用）。
  int get textCount => _texts.length;

  /// 已缓存的分页结果数。
  int get paginationCount => _paginations.length;

  /// 缓存中的字符总数。
  int get textChars => _textChars;

  NovelChapterText? text(String chapterId) {
    final cached = _texts.remove(chapterId);
    if (cached == null) return null;
    _texts[chapterId] = cached; // 命中即置为最近使用
    return cached;
  }

  void putText(String chapterId, NovelChapterText text) {
    final previous = _texts.remove(chapterId);
    if (previous != null) _textChars -= previous.length;
    _texts[chapterId] = text;
    _textChars += text.length;
    while (_texts.length > maxTextEntries ||
        (_textChars > maxTextChars && _texts.length > 1)) {
      final oldest = _texts.keys.first;
      final removed = _texts.remove(oldest);
      if (removed != null) _textChars -= removed.length;
    }
  }

  ChapterPagination? pagination(String key) {
    final cached = _paginations.remove(key);
    if (cached == null) return null;
    _paginations[key] = cached;
    return cached;
  }

  void putPagination(ChapterPagination pagination) {
    _paginations.remove(pagination.key);
    _paginations[pagination.key] = pagination;
    while (_paginations.length > maxPaginationEntries) {
      _paginations.remove(_paginations.keys.first);
    }
  }

  /// 清空全部缓存（退出阅读器时调用，把大章节占用的内存还回去）。
  void clear() {
    _texts.clear();
    _paginations.clear();
    _textChars = 0;
  }

  int get byteEstimate => math.max(_textChars, 1) * 2;
}
