import 'dart:convert';

/// Content hints classify sources without loading a site or running its script.
abstract final class SourceMediaHints {
  static bool audioLabel(String value) => RegExp(
    r'有声|有聲|听书|聽書|听小说|聽小說|音频|音頻|广播剧|廣播劇|audiobook|audio[_ -]?book|(?:^|[\s_/-])audio(?:$|[\s_/-])|tingbook',
    caseSensitive: false,
  ).hasMatch(value);

  static String fromScript(String script) {
    final header = RegExp(
      r'^\s*(?://|#)\s*@?LumeSource\s*[:=]\s*(\{[^\n]+\})',
      multiLine: true,
    ).firstMatch(script);
    if (header != null) {
      try {
        final data = jsonDecode(header.group(1)!);
        if (data is Map) {
          final kind =
              '${data['mediaType'] ?? data['contentType'] ?? data['kind'] ?? ''}'
                  .toLowerCase();
          if (['audio', 'audiobook', 'audio-book'].contains(kind)) {
            return 'audio';
          }
          if (kind.isEmpty &&
              data['category'] == 'video' &&
              data['contentTypes'] is List &&
              (data['contentTypes'] as List).contains('video') &&
              (data['contentTypes'] as List).length >= 2) {
            return 'video';
          }
          if (kind.isEmpty && data['category'] == 'audiobook') return 'audio';
          if (['novel', 'text', 'html'].contains(kind) ||
              data['category'] == 'novel') {
            return 'novel';
          }
          if (['photo', 'gallery'].contains(kind) ||
              data['category'] == 'photo' ||
              '${data['id'] ?? ''}'.endsWith('_photo')) {
            return 'photo';
          }
          if (['photo', 'comic'].contains(data['category'])) {
            return '${data['category']}';
          }
          if (kind == 'video') return 'video';
        }
      } catch (_) {
        /* Existing legacy scripts may not have a JSON header. */
      }
    }
    // Legacy pure-audio scripts do not always declare their media type.
    final audio = RegExp(
      r"""['"]?kind['"]?\s*:\s*['"](?:audio|audiobook|audio-book)['"]""",
    );
    final video = RegExp(
      r"""['"]?kind['"]?\s*:\s*['"](?:video|webplayer)['"]""",
    );
    return audio.hasMatch(script) && !video.hasMatch(script) ? 'audio' : '';
  }
}
