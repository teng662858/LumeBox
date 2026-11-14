import 'dart:convert';
import 'dart:io';

import '../net/lume_http.dart';

class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);
  final Duration start, end;
  final String text;
}

/// Bounded text loader for local and remote SRT / WebVTT. ASS stays in libass.
class TextSubtitles {
  TextSubtitles(this.cues) {
    var latest = Duration.zero;
    for (final cue in cues) {
      if (cue.end > latest) latest = cue.end;
      _latestEnd.add(latest);
    }
  }
  final List<Duration> _latestEnd = [];
  final List<SubtitleCue> cues;
  static const maxBytes = 8 * 1024 * 1024;
  static Future<TextSubtitles?> load(String path) async {
    final uri = Uri.tryParse(path);
    late List<int> bytes;
    if (uri != null && ['http', 'https'].contains(uri.scheme)) {
      final http = LumeHttp();
      try {
        final response = await http.send(url: path, maxBytes: maxBytes);
        if (response.statusCode != 200) return null;
        bytes = response.body;
      } finally {
        http.dispose();
      }
    } else {
      final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(path);
      if (await file.length() > maxBytes) return null;
      bytes = await file.readAsBytes();
    }
    final result = parse(decode(bytes));
    return result.cues.isEmpty ? null : result;
  }

  static String decode(List<int> bytes) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      final little = bytes[0] == 255;
      return String.fromCharCodes([
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    return utf8.decode(bytes);
  }

  static TextSubtitles parse(String text) {
    final lines = const LineSplitter().convert(text.startsWith('\ufeff') ? text.substring(1) : text);
    final cues = <SubtitleCue>[];
    final timing = RegExp(
      r'^\s*((?:\d+:)?\d{2}:\d{2}[,.]\d{3})\s*-->\s*((?:\d+:)?\d{2}:\d{2}[,.]\d{3})(?:[ \t]+.*)?$',
    );
    Duration? timestamp(String value) {
      final parts = value.split(RegExp(r'[:,.]'));
      final hours = parts.length == 4 ? int.tryParse(parts.removeAt(0)) : 0;
      // Duration stores signed 64-bit microseconds on native platforms.
      const maxMilliseconds = 0x7fffffffffffffff ~/ 1000;
      if (hours == null || hours > maxMilliseconds ~/ 3600000) return null;
      final minutes = int.parse(parts[0]), seconds = int.parse(parts[1]);
      if (minutes > 59 || seconds > 59) return null;
      final milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1000 + int.parse(parts[2]);
      return milliseconds > maxMilliseconds ? null : Duration(milliseconds: milliseconds);
    }

    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final block = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        block.add(lines[i++]);
      }
      final first = block.first.trim();
      if (first == 'NOTE' || first.startsWith('NOTE ') || first.startsWith('NOTE\t') ||
          first == 'STYLE' || first == 'REGION') {
        continue;
      }
      // A cue may have one identifier line before its timing line.
      final index = block.take(2).toList().indexWhere((line) => timing.hasMatch(line));
      if (index < 0) continue;
      final match = timing.firstMatch(block[index])!;
      final start = timestamp(match[1]!), end = timestamp(match[2]!);
      if (start == null || end == null || end <= start) continue;
      final value = block.skip(index + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&');
      if (value.trim().isNotEmpty) {
        cues.add(SubtitleCue(start, end, value));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return TextSubtitles(cues);
  }

  String at(Duration position) {
    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (cues[mid].start <= position) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final visible = <String>[];
    for (var i = lo - 1; i >= 0 && _latestEnd[i] > position; i--) {
      if (position < cues[i].end) visible.add(cues[i].text);
    }
    return visible.reversed.join('\n');
  }
}
