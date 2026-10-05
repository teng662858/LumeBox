import 'dart:math' as math;

/// 一个朗读片段：交给语音引擎的一段文本 + 它在整章中的字符起点。
class SpeechSegment {
  const SpeechSegment({required this.text, required this.start});

  /// 待朗读文本（首尾空白已去掉，可直接交给引擎）。
  final String text;

  /// 本片段首字符在整章原文中的下标。
  ///
  /// 引擎回报的朗读位置是**相对片段**的，加上这个起点才能换算回整章的字符
  /// 偏移——跟读翻页、进度保存、断点续听都依赖这个换算。
  final int start;

  /// 片段终点（不含）。
  int get end => start + text.length;

  /// 片段是否在整章中可定位（空片段没有意义，一律不产出）。
  bool get isSpeakable => text.isNotEmpty;

  @override
  String toString() => 'SpeechSegment($start..$end, ${text.length} 字)';
}

/// 朗读文本切分：把一章切成若干「听感完整」的片段。
///
/// 为什么要在 Dart 侧切，而不是把整章丢给引擎：
/// - **断点续听**：从当前页开始听，必须能指定起点；引擎接口只接受「一段文本」，
///   不接受「从第 N 个字开始」，所以起点只能由切分表达；
/// - **跟读翻页**：引擎回报的位置是相对片段的，只有切分时记下每片的字符起点，
///   才能换算成整章偏移、进而定位到页；
/// - **进度粒度**：一整章作为一段时，进度回调的粒度取决于引擎对超长文本的处理；
///   切成千字左右一片，位置回报稳定且可控。
///
/// 切分规则（按优先级）：
/// 1. 段落边界（换行）优先——换段处断开最自然，也不会有半句话被连读；
/// 2. 句末标点（。！？；…）次之，并连带其后的收尾引号 / 括号；
/// 3. 都没有（长句、无标点文本）时按长度硬断，保证单片不超上限。
class SpeechSegments {
  const SpeechSegments._();

  /// 单片长度上限（字符）。
  ///
  /// 1000 字约合 2~4 分钟语音：既让进度回报足够细，又不会因为片段太碎而
  /// 让「一句话被切两半」的听感问题频繁出现。
  static const int defaultMaxChars = 1000;

  /// 句末标点：在这些字符之后断开最自然。
  static const String _enders = '。！？；!?;…';

  /// 收尾符号：跟在句末标点后的引号 / 括号属于上一句，一起断进去。
  static const String _closers = '”』」’"\'）)】]》';

  /// 切分整章文本。[fromOffset] 之前的文本会被跳过（断点续听）。
  ///
  /// 返回的片段覆盖 `[fromOffset, text.length)` 内的全部非空白内容，
  /// 且按顺序排列——引擎顺序朗读即可，不需要额外的顺序表。
  static List<SpeechSegment> split(
    String text, {
    int fromOffset = 0,
    int maxChars = defaultMaxChars,
  }) {
    if (text.isEmpty) return const <SpeechSegment>[];
    final limit = maxChars < 1 ? 1 : maxChars;
    final segments = <SpeechSegment>[];
    var cursor = fromOffset.clamp(0, text.length);
    while (cursor < text.length) {
      // 片段不从空白开始：起点前的空白对朗读没有意义，留着只会让
      // 「片段起点 == 朗读位置」的换算多一层偏移。
      while (cursor < text.length && _isSpace(text.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor >= text.length) break;
      final start = cursor;
      final hardEnd = math.min(text.length, start + limit);
      var end = hardEnd;
      if (hardEnd < text.length) {
        final boundary = _lastBoundary(text, start, hardEnd);
        if (boundary > start) end = boundary;
      }
      // 片段末尾的空白不属于朗读内容：收掉它，并让 end 落在最后一个
      // 非空白字符之后——这样 `start + text.length == end` 恒成立。
      var sliceEnd = end;
      while (sliceEnd > start && _isSpace(text.codeUnitAt(sliceEnd - 1))) {
        sliceEnd--;
      }
      if (sliceEnd > start) {
        segments.add(
          SpeechSegment(text: text.substring(start, sliceEnd), start: start),
        );
      }
      cursor = end;
    }
    return List<SpeechSegment>.unmodifiable(segments);
  }

  /// 在 `[start, limit)` 内找最后一个可断点，返回断点之后的下标（不含）。
  ///
  /// 找不到可断点时返回 `start`（调用方据此走硬断）。
  static int _lastBoundary(String text, int start, int limit) {
    for (var index = limit - 1; index > start; index--) {
      final unit = text.codeUnitAt(index);
      if (unit == 0x0A) return index + 1; // 换行：最强断点
      if (_enders.contains(String.fromCharCode(unit))) {
        // 句末标点后的收尾符号（引号 / 括号）一起断进来。
        var end = index + 1;
        while (end < limit &&
            _closers.contains(String.fromCharCode(text.codeUnitAt(end)))) {
          end++;
        }
        return end;
      }
    }
    return start;
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || // 空格
      unit == 0x09 || // 制表符
      unit == 0x0A || // 换行
      unit == 0x0D || // 回车
      unit == 0x3000; // 全角空格
}
