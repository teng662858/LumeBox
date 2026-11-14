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
    final lines = const LineSplitter().convert(text);
    final cues = <SubtitleCue>[];
    final timing = RegExp(
      r'((?:\d+:)?\d{2}:\d{2}[,.]\d{3})\s*-->\s*((?:\d+:)?\d{2}:\d{2}[,.]\d{3})',
    );
    Duration timestamp(String value) {
      final parts = value.replaceAll(',', '.').split(':');
      var seconds = 0.0;
      for (final p in parts) {
        seconds = seconds * 60 + double.parse(p);
      }
      return Duration(milliseconds: (seconds * 1000).round());
    }

    for (var i = 0; i < lines.length; i++) {
      final match = timing.firstMatch(lines[i]);
      if (match == null) continue;
      final start = timestamp(match[1]!), end = timestamp(match[2]!);
      final body = <String>[];
      while (++i < lines.length && lines[i].trim().isNotEmpty) {
        body.add(lines[i]);
      }
      final value = body
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&');
      if (end > start && value.trim().isNotEmpty) {
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
