import 'package:xml/xml.dart';

enum SpeechRole { narrator, male, female }

/// Original UTF-16 positions are retained even when the voice changes.
class SpeechTurn {
  const SpeechTurn(this.text, this.start, this.role, {this.pauseMs = 0});
  final String text;
  final int start;
  final SpeechRole role;
  final int pauseMs;
  int get end => start + text.length;
}

class SpeechTurns {
  static List<SpeechTurn> regex(String text, {required bool dialogue}) {
    if (!dialogue) return _chunks(text, 0, SpeechRole.narrator);
    final result = <SpeechTurn>[];
    final speakers = <String, SpeechRole>{};
    final pattern = RegExp(r'[^\n]+\n?|\n');
    final prefix = RegExp(
      r'^[ \t　]*([\u3400-\u9fffA-Za-z0-9·]{1,8})[ \t　]*[：:]',
    );
    final narrativeLabels = RegExp(
      r'^(?:旁白|叙述|作者|注|备注|例如|比如|注意|提示|答案|原因|结果|说明|第.+[章节卷])$|'
      r'(?:是|有|如下|写着|显示|说道|说|问|答|喊|道)$',
    );
    final quotes = RegExp(r'“[^”\n]+”|「[^」\n]+」|『[^』\n]+』|"[^"\n]+"');
    const cue = r'([他她])(?:轻声|低声|大声|笑着)?(?:说道|问道|答道|喊道|说|问|答|喊|道)';
    final beforeQuote = RegExp('$cue[：:]?[ \\t　]*\$');
    final afterQuote = RegExp('^[ \\t　]*[，,]?[ \\t　]*$cue');
    var start = 0;
    var currentRole = SpeechRole.narrator;
    void changeRole(int at, SpeechRole role) {
      if (currentRole == role) return;
      result.addAll(_chunks(text.substring(start, at), start, currentRole));
      start = at;
      currentRole = role;
    }

    for (final line in pattern.allMatches(text)) {
      final content = line.group(0)!;
      if (content.trim().isEmpty) continue;
      final match = prefix.firstMatch(content);
      final name = match?.group(1);
      if (name != null && !narrativeLabels.hasMatch(name)) {
        changeRole(
          line.start,
          speakers.putIfAbsent(name, () {
            if (RegExp(r'她|女|姐|妹|妈|娘|婆|太太|夫人|小姐').hasMatch(name)) {
              return SpeechRole.female;
            }
            if (RegExp(r'他|男|哥|弟|爸|爹|爷|先生|公子').hasMatch(name)) {
              return SpeechRole.male;
            }
            return speakers.length.isEven ? SpeechRole.male : SpeechRole.female;
          }),
        );
        continue;
      }
      changeRole(line.start, SpeechRole.narrator);
      for (final quote in quotes.allMatches(content)) {
        final speaker =
            beforeQuote
                .firstMatch(content.substring(0, quote.start))
                ?.group(1) ??
            afterQuote.firstMatch(content.substring(quote.end))?.group(1);
        if (speaker == null) continue;
        changeRole(
          line.start + quote.start,
          speaker == '她' ? SpeechRole.female : SpeechRole.male,
        );
        changeRole(line.start + quote.end, SpeechRole.narrator);
      }
    }
    result.addAll(_chunks(text.substring(start), start, currentRole));
    return result;
  }

  static List<SpeechTurn> _chunks(
    String text,
    int start,
    SpeechRole role, {
    int pauseMs = 0,
  }) {
    final result = <SpeechTurn>[];
    var offset = 0;
    while (offset < text.length) {
      var end = (offset + 140).clamp(0, text.length);
      if (end < text.length) {
        final part = text.substring(offset, end);
        final breaks = RegExp(r'[。！？!?；;，,\n]').allMatches(part).toList();
        if (breaks.isNotEmpty && breaks.last.end > 40) {
          end = offset + breaks.last.end;
        }
        if (end > offset &&
            text.codeUnitAt(end - 1) >= 0xd800 &&
            text.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
      }
      final part = text.substring(offset, end);
      if (part.trim().isNotEmpty) {
        result.add(
          SpeechTurn(
            part,
            start + offset,
            role,
            pauseMs: end == text.length ? pauseMs : 0,
          ),
        );
      }
      offset = end;
    }
    return result;
  }

  /// Accept markup, never accept rewritten/omitted chapter text. No markup is
  /// sent to the TTS endpoint; providers receive original plain-text slices.
  static List<SpeechTurn> ssml(String markup, String original) {
    if (markup.length > original.length * 12 + 8192 ||
        markup.contains('<!') ||
        markup.contains('<?')) {
      throw const FormatException('不支持的 SSML');
    }
    var source = markup.trim();
    if (source.startsWith('```')) {
      source = source
          .replaceFirst(RegExp(r'^```[^\n]*\n'), '')
          .replaceFirst(RegExp(r'\n?```$'), '');
    }
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local != 'speak') {
      throw const FormatException('缺少 speak 根节点');
    }
    final normalized = <int>[];
    final positions = <int>[];
    bool whitespace(int code) =>
        RegExp(r'\s').hasMatch(String.fromCharCode(code));
    for (var i = 0; i < original.length; i++) {
      if (!whitespace(original.codeUnitAt(i))) {
        normalized.add(original.codeUnitAt(i));
        positions.add(i);
      }
    }
    final result = <SpeechTurn>[];
    var cursor = 0, nodes = 0;
    void visit(XmlNode node, SpeechRole role, int depth) {
      if (++nodes > 20000 || depth > 24) {
        throw const FormatException('SSML 结构过大');
      }
      if (node is XmlText) {
        final units = node.value.codeUnits
            .where((c) => !whitespace(c))
            .toList();
        if (units.isEmpty) return;
        final first = cursor;
        for (final code in units) {
          if (cursor >= normalized.length || normalized[cursor++] != code) {
            throw const FormatException('AI 改写了原文');
          }
        }
        final start = positions[first];
        final end = positions[cursor - 1] + 1;
        result.addAll(_chunks(original.substring(start, end), start, role));
      } else if (node is XmlElement) {
        final tag = node.name.local;
        if (!const {
          'speak',
          'voice',
          'prosody',
          'p',
          's',
          'break',
          'emphasis',
        }.contains(tag)) {
          throw FormatException('不支持 SSML 标签 $tag');
        }
        if (tag == 'voice') {
          final name = node.getAttribute('name');
          role = switch (name) {
            'narrator' => SpeechRole.narrator,
            'male' => SpeechRole.male,
            'female' => SpeechRole.female,
            _ => throw const FormatException('未知角色'),
          };
        }
        if (tag == 'break' && result.isNotEmpty) {
          final raw = node.getAttribute('time') ?? '250ms';
          final number =
              double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 250;
          final ms = (raw.endsWith('ms') ? number : number * 1000)
              .round()
              .clamp(0, 3000);
          final last = result.removeLast();
          result.add(SpeechTurn(last.text, last.start, last.role, pauseMs: ms));
        }
        for (final child in node.children) {
          visit(child, role, depth + 1);
        }
      }
    }

    visit(document.rootElement, SpeechRole.narrator, 0);
    if (cursor != normalized.length || result.isEmpty) {
      throw const FormatException('AI 未返回完整章节');
    }
    return result;
  }

  static List<SpeechTurn> slice(List<SpeechTurn> turns, int start, int end) => [
    for (final turn in turns)
      if (turn.end > start && turn.start < end)
        SpeechTurn(
          turn.text.substring(
            (start - turn.start).clamp(0, turn.text.length),
            (end - turn.start).clamp(0, turn.text.length),
          ),
          turn.start.clamp(start, end) - start,
          turn.role,
          pauseMs: turn.end <= end ? turn.pauseMs : 0,
        ),
  ];
}
