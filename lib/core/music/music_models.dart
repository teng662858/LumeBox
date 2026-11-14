import 'dart:convert';

enum MusicProtocol { musicFree, lx }

class MusicPlugin {
  const MusicPlugin({
    required this.id,
    required this.name,
    required this.protocol,
    this.version = '',
    this.origin = '',
    this.enabled = true,
    this.capabilities = const [],
    this.primaryKey = const ['id'],
    this.platforms = const {},
    this.variables = const [],
    this.values = const {},
  });
  final String id, name, version, origin;
  final MusicProtocol protocol;
  final bool enabled;
  final List<String> capabilities, primaryKey;
  final Map<String, List<String>> platforms;
  final List<Map<String, dynamic>> variables;
  final Map<String, String> values;
  String get label => protocol == MusicProtocol.musicFree ? 'MusicFree' : 'LX';
  MusicPlugin copyWith({bool? enabled, Map<String, String>? values}) =>
      MusicPlugin(
        id: id,
        name: name,
        protocol: protocol,
        version: version,
        origin: origin,
        enabled: enabled ?? this.enabled,
        capabilities: capabilities,
        primaryKey: primaryKey,
        platforms: platforms,
        variables: variables,
        values: values ?? this.values,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'version': version,
    'origin': origin,
    'enabled': enabled,
    'capabilities': capabilities,
    'primaryKey': primaryKey,
    'platforms': platforms,
    'variables': variables,
    'values': values,
  };
  factory MusicPlugin.fromJson(Map data) => MusicPlugin(
    id: '${data['id']}',
    name: '${data['name']}',
    protocol: MusicProtocol.values.byName('${data['protocol']}'),
    version: '${data['version'] ?? ''}',
    origin: '${data['origin'] ?? ''}',
    enabled: data['enabled'] != false,
    capabilities: List<String>.from(data['capabilities'] as List? ?? []),
    primaryKey: List<String>.from(data['primaryKey'] as List? ?? ['id']),
    platforms: (data['platforms'] as Map? ?? {}).map(
      (k, v) => MapEntry('$k', List<String>.from(v as List)),
    ),
    variables: [
      for (final v in data['variables'] as List? ?? [])
        if (v is Map) Map<String, dynamic>.from(v),
    ],
    values: (data['values'] as Map? ?? {}).map((k, v) => MapEntry('$k', '$v')),
  );
}

/// Keep platform-specific identifiers intact; LX resolvers need more than a title.
class MusicTrack {
  const MusicTrack({
    required this.pluginId,
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.cover,
    this.platform = '',
    this.duration,
    this.raw = const {},
  });
  final String pluginId, id, title, artist, album, platform;
  final String? cover;
  final Duration? duration;
  final Map<String, dynamic> raw;
  String get key => jsonEncode([pluginId, platform, id]);
  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'platform': platform,
    'durationMs': duration?.inMilliseconds,
    'raw': raw,
  };
  factory MusicTrack.fromJson(Map data) => MusicTrack(
    pluginId: '${data['pluginId']}',
    id: '${data['id']}',
    title: '${data['title']}',
    artist: '${data['artist'] ?? ''}',
    album: '${data['album'] ?? ''}',
    cover: data['cover'] as String?,
    platform: '${data['platform'] ?? ''}',
    duration: data['durationMs'] is num
        ? Duration(milliseconds: (data['durationMs'] as num).toInt())
        : null,
    raw: Map<String, dynamic>.from(data['raw'] as Map? ?? {}),
  );
  static MusicTrack parse(
    String pluginId,
    Map item, {
    String platform = '',
    List<String>? primaryKey,
  }) {
    String text(Object? value) {
      if (value is List) {
        return value
            .map((v) => v is Map ? v['name'] ?? v['title'] ?? '' : v)
            .where((v) => '$v'.isNotEmpty)
            .join(' / ');
      }
      if (value is Map) return '${value['name'] ?? value['title'] ?? ''}';
      return '${value ?? ''}';
    }

    final id =
        primaryKey != null &&
            primaryKey.isNotEmpty &&
            primaryKey.join(',') != 'id'
        ? jsonEncode([for (final key in primaryKey) item[key]])
        : text(item['id'] ?? item['songmid'] ?? item['hash']);
    final title = text(item['title'] ?? item['name'] ?? item['songName']);
    if (id.isEmpty || title.isEmpty) {
      throw const FormatException('音源返回的歌曲缺少标识或标题');
    }
    final seconds = item['duration'];
    return MusicTrack(
      pluginId: pluginId,
      id: id,
      title: title,
      artist: text(item['artist'] ?? item['singer'] ?? item['artists']),
      album: text(item['album'] ?? item['albumName']),
      cover:
          (item['artwork'] ?? item['cover'] ?? item['img'] ?? item['picUrl'])
              as String?,
      platform: platform.isNotEmpty
          ? platform
          : text(item['source'] ?? item['platform']),
      duration: seconds is num && seconds.isFinite
          ? Duration(milliseconds: (seconds * 1000).round())
          : null,
      raw: Map<String, dynamic>.from(item),
    );
  }
}

class MusicTrackPage {
  const MusicTrackPage(this.tracks, {this.hasMore = false});
  final List<MusicTrack> tracks;
  final bool hasMore;
}

class MusicLyrics {
  const MusicLyrics({this.original = '', this.translation = ''});
  final String original, translation;
}

class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
  static List<LyricLine> parse(String lrc) {
    final lines = <LyricLine>[];
    var offset = 0;
    final match = RegExp(
      r'\[offset:([+-]?\d+)\]',
      caseSensitive: false,
    ).firstMatch(lrc);
    if (match != null) offset = int.tryParse(match.group(1)!) ?? 0;
    for (final row in const LineSplitter().convert(lrc)) {
      final times = RegExp(r'\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]')
          .allMatches(row)
          .toList();
      if (times.isEmpty) continue;
      final text = row
          .substring(times.last.end)
          .replaceAll(RegExp(r'<\d+,\d+>'), '')
          .trim();
      for (final t in times) {
        final ms =
            int.parse(t.group(1)!) * 60000 +
            int.parse(t.group(2)!) * 1000 +
            int.parse((t.group(3) ?? '0').padRight(3, '0')) -
            offset;
        lines.add(LyricLine(Duration(milliseconds: ms < 0 ? 0 : ms), text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
