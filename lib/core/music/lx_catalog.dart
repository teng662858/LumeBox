import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../net/lume_http.dart';
import '../net/lume_net.dart';
import 'music_models.dart';

/// LX scripts resolve platform IDs; searching is a separate host responsibility.
/// These endpoints only return catalog metadata, never an alternate media URL.
class LxCatalog {
  // ignore: prefer_initializing_formals
  LxCatalog({LumeHttp? http}) : _http = http;
  final LumeHttp? _http;
  static String label(String key) => switch (key) {
    'kw' => '酷我',
    'kg' => '酷狗',
    'wy' => '网易云',
    'tx' => 'QQ 音乐',
    'mg' => '咪咕',
    _ => key,
  };
  Future<Map> _json(
    String url, {
    String method = 'GET',
    Map? body,
    Map<String, String> headers = const {},
  }) async {
    final http = _http ?? LumeHttp(settings: LumeNet.settings);
    try {
      final response = await http.send(
        url: url,
        method: method,
        headers: {
          'Referer': 'https://music.163.com/',
          'Content-Type': 'application/json',
          ...headers,
        },
        body: body == null ? null : jsonEncode(body),
        timeout: const Duration(seconds: 15),
        maxBytes: 2 * 1024 * 1024,
      );
      if (response.statusCode != 200) {
        throw StateError('曲库请求失败（${response.statusCode}）');
      }
      final data = jsonDecode(response.text);
      if (data is! Map) throw const FormatException('曲库返回格式异常');
      return data;
    } finally {
      if (_http == null) http.dispose();
    }
  }

  Future<MusicTrackPage> search(
    String pluginId,
    String platform,
    String keyword,
    int page,
  ) async {
    final q = Uri.encodeQueryComponent(keyword);
    final Map data;
    final List rows;
    switch (platform) {
      case 'kw':
        data = await _json(
          'https://search.kuwo.cn/r.s?client=kt&all=$q&pn=${page - 1}&rn=30&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1',
        );
        if (data['abslist'] is! List) throw StateError('酷我曲库当前不可用');
        rows = data['abslist'] as List;
      case 'kg':
        data = await _json(
          'https://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=$q&hifiquality=0&pagesize=30&PrivilegeFilter=0&page=$page',
        );
        if (data['data'] is! Map || data['data']['lists'] is! List) {
          throw StateError('酷狗曲库当前不可用');
        }
        rows = data['data']['lists'] as List;
      case 'wy':
        data = await _json(
          'https://music.163.com/api/search/get/web?s=$q&type=1&offset=${(page - 1) * 30}&limit=30',
        );
        if (data['code'] != 200 || data['result'] is! Map) {
          throw StateError('网易云曲库当前不可用');
        }
        rows = data['result']['songs'] as List? ?? [];
      case 'tx':
        final searchId = sha1
            .convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}'))
            .toString()
            .substring(0, 32)
            .toUpperCase();
        final payload = {
          'comm': {
            '_channelid': '0',
            '_os_version': '6.2.9200-2',
            'ct': '19',
            'cv': '2151',
            'guid': searchId,
            'patch': '118',
            'psrf_access_token_expiresAt': 0,
            'psrf_qqaccess_token': '',
            'psrf_qqopenid': '',
            'psrf_qqunionid': '',
            'tmeAppID': 'qqmusic',
            'tmeLoginType': 0,
            'uin': '0',
            'wid': '7223299733393904640',
          },
          'req': {
            'module': 'music.search.SearchCgiService',
            'method': 'DoSearchForQQMusicDesktop',
            'param': {
              'grp': 1,
              'num_per_page': 30,
              'page_num': page,
              'query': keyword,
              'search_type': 0,
              'remoteplace': 'txt.newclient.top',
              'searchid': '${searchId}00000',
            },
          },
        };
        data = await _json(
          'https://u.y.qq.com/cgi-bin/musics.fcg?sign=${qqSignature(jsonEncode(payload))}',
          method: 'POST',
          body: payload,
          headers: {
            'User-Agent': 'QQMusic 14090508(android 12)',
            'Referer': 'https://y.qq.com/',
          },
        );
        if (data['code'] != 0 ||
            data['req'] is! Map ||
            data['req']['code'] != 0 ||
            data['req']['data']?['body']?['song']?['list'] is! List) {
          throw StateError('QQ 曲库请求被拒绝，请稍后重试或使用 MusicFree 搜索');
        }
        rows = data['req']['data']['body']['song']['list'] as List;
      case 'mg':
        final time = '${DateTime.now().millisecondsSinceEpoch}';
        const device = '963B7AA0D21511ED807EE5846EC87D20';
        final sign = md5
            .convert(
              utf8.encode(
                '${keyword}6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50$device$time',
              ),
            )
            .toString();
        data = await _json(
          'https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=${Uri.encodeQueryComponent(jsonEncode({'song': 1, 'album': 0, 'singer': 0, 'tagSong': 1, 'mvSong': 0, 'bestShow': 1, 'songlist': 0, 'lyricSong': 0}))}&pageSize=30&text=$q&pageNo=$page&sort=0&sid=USS',
          headers: {
            'uiVersion': 'A_music_3.6.1',
            'deviceId': device,
            'timestamp': time,
            'sign': sign,
            'channel': '0146921',
          },
        );
        if (data['code'] != '000000' || data['songResultData'] is! Map) {
          throw StateError('咪咕曲库当前不可用');
        }
        rows = [
          for (final group
              in data['songResultData']['resultList'] as List? ?? [])
            if (group is List) ...group else if (group is Map) group,
        ];
      default:
        throw UnsupportedError('此 LX 平台不提供在线曲库');
    }
    return MusicTrackPage([
      for (final row in rows)
        if (row is Map) normalize(pluginId, platform, row),
    ], hasMore: rows.length >= 30);
  }

  static MusicTrack normalize(String pluginId, String platform, Map row) {
    String names(Object? values) => values is List
        ? values.map((v) => v is Map ? v['name'] ?? '' : v).join(' / ')
        : '${values ?? ''}';
    Map<String, dynamic> raw;
    switch (platform) {
      case 'kw':
        raw = {
          'songmid': '${row['MUSICRID']}'.replaceFirst('MUSIC_', ''),
          'name': row['SONGNAME'] ?? row['NAME'],
          'singer': row['ARTIST'],
          'albumName': row['ALBUM'],
          'albumId': row['ALBUMID'],
          'duration': num.tryParse('${row['DURATION']}'),
        };
      case 'kg':
        final types = <String, Map<String, dynamic>>{};
        for (final tuple in [
          ('128k', 'File'),
          ('320k', 'HQFile'),
          ('flac', 'SQFile'),
          ('flac24bit', 'ResFile'),
        ]) {
          final hash = row['${tuple.$2}Hash'];
          if (hash is String && hash.isNotEmpty) {
            types[tuple.$1] = {'hash': hash, 'size': row['${tuple.$2}Size']};
          }
        }
        raw = {
          'songmid': row['Audioid'] ?? row['FileHash'],
          'hash': row['FileHash'],
          'albumAudioId': row['MixSongID'],
          'name': row['OriSongName'] ?? row['SongName'],
          'singer': names(row['Singers'] ?? row['SingerName']),
          'albumId': row['AlbumID'],
          'albumName': row['AlbumName'],
          'duration': row['Duration'],
          '_types': types,
        };
      case 'wy':
        final album = row['album'] as Map? ?? {};
        raw = {
          'songmid': row['id'],
          'name': row['name'],
          'singer': names(row['artists']),
          'albumName': album['name'],
          'albumId': album['id'],
          'img': album['picUrl'],
          'duration': row['duration'] is num
              ? (row['duration'] as num) / 1000
              : null,
        };
      case 'tx':
        raw = {
          'songmid': row['mid'],
          'strMediaMid': row['file']?['media_mid'],
          'songId': row['id'],
          'name': row['name'],
          'singer': names(row['singer']),
          'albumName': row['album']?['name'],
          'albumId': row['album']?['mid'],
          'duration': row['interval'],
        };
      case 'mg':
        raw = {
          'songmid': row['songId'],
          'copyrightId': row['copyrightId'],
          'name': row['name'],
          'singer': names(row['singerList']),
          'albumName': row['album'],
          'albumId': row['albumId'],
          'img': row['img3'] ?? row['img2'] ?? row['img1'],
          'duration': row['duration'],
          'lrcUrl': row['lrcUrl'],
        };
      default:
        throw UnsupportedError(platform);
    }
    raw['source'] = platform;
    raw['typeUrl'] = <String, dynamic>{};
    raw['types'] = [
      for (final type in (raw['_types'] as Map? ?? const {'128k': {}}).keys)
        {'type': type},
    ];
    raw['_types'] ??= <String, dynamic>{};
    final seconds = (raw['duration'] as num?)?.toInt() ?? 0;
    raw['_interval'] = seconds;
    raw['interval'] =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return MusicTrack.parse(pluginId, raw, platform: platform);
  }

  Future<MusicLyrics> lyrics(MusicTrack track) async {
    if (track.platform != 'wy') return const MusicLyrics();
    final result = await _json(
      'https://music.163.com/api/song/lyric?id=${Uri.encodeQueryComponent(track.id)}&lv=-1&tv=-1',
    );
    return MusicLyrics(
      original: '${result['lrc']?['lyric'] ?? ''}',
      translation: '${result['tlyric']?['lyric'] ?? ''}',
    );
  }

  /// QQ catalog request signature, over the exact UTF-8 JSON sent in the body.
  static String qqSignature(String json) {
    final digest = sha1.convert(utf8.encode(json));
    final hex = digest.toString();
    String pick(List<int> positions) =>
        positions.where((i) => i < hex.length).map((i) => hex[i]).join();
    const mask = [
      89,
      39,
      179,
      150,
      218,
      82,
      58,
      252,
      177,
      52,
      186,
      123,
      120,
      64,
      242,
      133,
      143,
      161,
      121,
      179,
    ];
    final mixed = base64Encode([
      for (var i = 0; i < 20; i++) digest.bytes[i] ^ mask[i],
    ]).replaceAll(RegExp(r'[/+=]'), '');
    return 'zzc${pick([23, 14, 6, 36, 16, 40, 7, 19])}$mixed${pick([16, 1, 32, 12, 19, 27, 8, 5])}'
        .toLowerCase();
  }
}
