import '../../core/player/abstract_player.dart';
import '../../core/player/player_capabilities.dart';
import '../../core/player/player_experience.dart';

/// Wires the saved playback preferences (UA / subtitle language) into the real
/// playback path. Kept pure so the matching rules are unit-testable without a
/// player instance.
class PlaybackPreferenceWiring {
  const PlaybackPreferenceWiring._();

  /// Returns [headers] with the configured browser UA added when:
  /// - the preference is non-empty, and
  /// - the media does not already carry its own `User-Agent`
  ///   (source/session UA keeps priority, as the settings row promises).
  static Map<String, String> withUserAgent(
    Map<String, String>? headers,
    PlayerExperience preferences,
  ) {
    final configured = preferences.browserUA;
    final current = headers ?? const <String, String>{};
    if (configured.isEmpty) return headers ?? const <String, String>{};
    if (current.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      return current;
    }
    return <String, String>{...current, 'User-Agent': configured};
  }

  static PlayerMedia applyUserAgent(
    PlayerMedia media,
    PlayerExperience preferences,
  ) {
    if (media.headers == null && preferences.browserUA.isEmpty) return media;
    final headers = withUserAgent(media.headers, preferences);
    if (identical(headers, media.headers)) return media;
    return PlayerMedia(
      uri: media.uri,
      headers: headers,
      title: media.title,
      previews: media.previews,
    );
  }

  /// Picks the first subtitle track matching [preference]. `source` keeps the
  /// source/kernel default; `off` is handled by the caller (select null).
  static String? chooseSubtitleTrack(
    List<PlayerTrack> tracks,
    String preference,
  ) {
    if (tracks.isEmpty) return null;
    final keys = _subtitleKeys[preference];
    if (keys == null) return null;
    // Prefer the structured language field (e.g. "zh-Hans") before the title.
    for (final track in tracks) {
      final language = (track.language ?? '').toLowerCase().trim();
      if (language.isEmpty) continue;
      for (final key in keys) {
        if (language == key ||
            language.startsWith('$key-') ||
            language.startsWith('${key}_')) {
          return track.id;
        }
      }
    }
    for (final track in tracks) {
      final haystack = '${track.language ?? ''} ${track.label}'.toLowerCase();
      for (final key in keys) {
        if (_containsTerm(haystack, key)) return track.id;
      }
    }
    return null;
  }

  /// Human labels used by the settings page and by docs/tests.
  static const subtitleLanguageLabels = <String, String>{
    'source': '跟随片源',
    'zh-Hans': '简体中文',
    'zh-Hant': '繁体中文',
    'yue': '粤语',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'off': '关闭字幕',
  };

  static const _subtitleKeys = <String, List<String>>{
    'zh-Hans': ['zh-hans', 'zh-cn', 'zh_cn', 'chs', 'chi', '简体', '简中', '中文'],
    'zh-Hant': ['zh-hant', 'zh-tw', 'zh_tw', 'cht', '繁体', '繁體', '繁中'],
    'yue': ['yue', '粤语', '粵語', '粤', '粵'],
    'en': ['en', 'eng', 'english', '英语', '英文'],
    'ja': ['ja', 'jpn', 'japanese', '日语', '日文', '日本語'],
    'ko': ['ko', 'kor', 'korean', '韩语', '韓語', '韩文', '한국'],
  };

  /// Short ISO codes need a token match so e.g. "french" does not match "en".
  static bool _containsTerm(String haystack, String term) {
    if (term.length > 3) return haystack.contains(term);
    return RegExp('(^|[^a-z])${RegExp.escape(term)}([^a-z]|\$)')
        .hasMatch(haystack);
  }
}
