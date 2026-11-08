import 'builtin_danmaku_service.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import '../../../core/util/lume_log.dart';
import 'danmaku_models.dart';
import 'danmaku_credentials.dart';
import 'danmaku_http_client.dart';

export 'danmaku_credentials.dart';

class DandanplayException implements Exception {
  const DandanplayException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DandanplayEpisode {
  const DandanplayEpisode({
    required this.id,
    required this.title,
    required this.episode,
    this.animeId = '',
    this.number,
    this.source = '',
    this.type = '',
    this.year,
  });
  final String id;
  final String title;
  final String episode;
  final String animeId, source, type;
  final int? number, year;
  bool get supplementary => RegExp(
    r'速通|高光|合集|花絮|预告|片花|剪辑|解说|幕后|主题曲|片尾曲|片头曲|trailer|highlights|recap',
    caseSensitive: false,
  ).hasMatch(episode);

  String get workTitle => DandanplayClient.searchTitle(title);
  String get workKey =>
      '${animeId.isEmpty ? workTitle : animeId}|$year|$source';
  String get details => [
    if (year != null) '$year',
    if (type.isNotEmpty) type,
    if (source.isNotEmpty) source,
    if (supplementary) '附加内容／合集，请核对',
  ].join(' · ');
}

/// Official API v2. Source comments and this library are merged by the page.
/// Credentials are stored in iOS Keychain, never embedded in the repository.
class DandanplayClient {
  DandanplayClient({
    required this.credentials,
    http.Client? client,
    Future<Uri> Function()? localService,
  }) : _client = client ?? DanmakuHttpClient(),
       _localService =
           localService ?? BuiltinDanmakuService.instance.ensureStarted;
  final DandanplayCredentials credentials;
  final http.Client _client;
  final Future<Uri> Function() _localService;
  bool _closed = false;
  void close() {
    _closed = true;
    _client.close();
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) =>
      _request(path, query).timeout(const Duration(seconds: 45));

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> query, {
    Map<String, Object?>? body,
  }) async {
    Uri? base;
    if (credentials.builtin) {
      try {
        base = await _localService();
      } on UnsupportedError catch (error) {
        throw DandanplayException(error.message?.toString() ?? '内置服务不可用');
      } catch (error) {
        final detail = '$error'.trim();
        throw DandanplayException(
          detail.isEmpty ? '内置弹幕服务启动失败，请重试或完整关闭 App 后重开' : '内置弹幕服务启动失败：$detail',
        );
      }
      if (_closed) throw const DandanplayException('弹幕请求已取消');
    } else {
      base = Uri.tryParse(credentials.baseUrl.trim());
    }
    if (base == null ||
        !['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const DandanplayException('请填写完整的弹幕服务地址，保留路径前缀');
    }
    if (credentials.official && !credentials.configured) {
      throw const DandanplayException('请先配置弹弹play应用 AppId 和 AppSecret');
    }
    if (base.host == 'api.dandanplay.net' && !credentials.official) {
      throw const DandanplayException('官方服务地址请使用 https://api.dandanplay.net');
    }
    var url = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      queryParameters: query,
    );
    http.Response? response;
    // The official comments endpoint redirects to a CDN. Handle redirects
    // explicitly so signatures never follow the request to another origin.
    for (var redirects = 0; redirects <= 5; redirects++) {
      final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final request = http.Request(body == null ? 'GET' : 'POST', url)
        ..followRedirects = false;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      request.headers.addAll({
        if (credentials.official && DandanplayCredentials.isOfficial(url)) ...{
          'X-AppId': credentials.appId.trim(),
          'X-Timestamp': timestamp,
          'X-Signature': base64Encode(
            sha256
                .convert(
                  utf8.encode(
                    '${credentials.appId.trim()}$timestamp${url.path}${credentials.appSecret.trim()}',
                  ),
                )
                .bytes,
          ),
        },
        'Accept': 'application/json',
        'User-Agent': 'LumeBox/1.0',
      });
      response = await http.Response.fromStream(await _client.send(request));
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
      final location = response.headers['location'];
      final next = location == null ? null : url.resolve(location);
      if (redirects == 5 ||
          next == null ||
          !['http', 'https'].contains(next.scheme) ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty ||
          (url.scheme == 'https' && next.scheme != 'https')) {
        throw const DandanplayException('弹幕服务跳转无效，请检查服务地址');
      }
      if (body != null &&
          (next.origin != url.origin ||
              ![307, 308].contains(response.statusCode))) {
        throw const DandanplayException('弹幕服务不允许转发此操作，请使用最终服务地址');
      }
      url = next;
    }
    response = response!;
    LumeLog.info(
      '[danmaku] ${credentials.builtin
          ? 'builtin'
          : credentials.official
          ? 'official'
          : 'compatible'} ${url.path} -> ${response.statusCode}',
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      final reason = switch (response.headers['x-error-message']) {
        'Invalid Timestamp' => '设备时间不准确，请开启系统自动设置日期与时间',
        'Invalid AppId' => 'AppId 无效或与 AppSecret 不配对，请核对应用凭证',
        'Invalid AppSecret' ||
        'Invalid Signature' => 'AppSecret 无效或签名未通过，请检查密钥是否复制完整及设备时间',
        'Missing Authentication Headers' => '服务未收到应用鉴权信息，请检查服务地址',
        _ =>
          credentials.official
              ? '应用凭证未通过验证，请检查 AppId、AppSecret 和应用状态'
              : '兼容服务拒绝访问，请检查地址中的访问令牌或更换服务',
      };
      throw DandanplayException('$reason（HTTP ${response.statusCode}）');
    }
    if (response.statusCode != 200) {
      // Local adapter and some compatible servers return a JSON error body even
      // with a non-200 status; surface its reason instead of a bare HTTP code.
      String? reason;
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map) reason = '${body['errorMessage'] ?? ''}'.trim();
      } catch (_) {}
      if (reason != null && reason.isNotEmpty) {
        throw DandanplayException('$reason（HTTP ${response.statusCode}）');
      }
      throw DandanplayException('弹幕服务请求失败（HTTP ${response.statusCode}）');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic> || json['success'] == false) {
      final code = json is Map ? int.tryParse('${json['errorCode']}') : null;
      final message = json is Map ? '${json['errorMessage'] ?? ''}'.trim() : '';
      if (message.isNotEmpty) {
        throw DandanplayException(
          code == null ? message : '$message（错误码 $code）',
        );
      }
      throw DandanplayException(
        code == null ? '弹幕服务返回了无效结果' : '弹幕服务请求未成功（错误码 $code）',
      );
    }
    return json;
  }

  /// A successful empty search also proves the API accepted these credentials.
  Future<void> checkConnection() async {
    if (credentials.builtin) {
      final health = await _get('/_health', {});
      if (health['ok'] != true) throw const DandanplayException('内置服务未就绪');
      // Health only proves the local Node adapter is up. Search is what actually
      // contacts the upstream danmu_api platforms, so surface its failure here
      // instead of showing a misleading "连接成功".
      _parseSearch(
        await _get('/api/v2/search/episodes', {
          'anime': '测试',
          'episode': '1',
          'v2': 'true',
        }),
      );
      return;
    }
    _parseSearch(
      await _get('/api/v2/search/episodes', {
        'anime': '测试',
        'episode': '1',
        'v2': 'true',
      }),
    );
  }

  static String describeError(Object error) => switch (error) {
    DandanplayException() => error.message,
    TimeoutException() => '弹幕服务连接超时，请重试或检查网络',
    PlatformException(code: 'network') => '弹幕服务网络请求失败，请检查 VPN 规则或网络连接',
    PlatformException(code: 'api_timeout') => '弹幕服务连接超时，请检查 VPN 规则或网络连接',
    PlatformException(code: 'response_size') => '弹幕响应过大，无法完整读取',
    PlatformException() || MissingPluginException() => '无法读取或保存本机弹幕凭证，请重试',
    FormatException() => '弹幕服务返回格式不正确，请检查服务地址',
    _ => '弹幕服务连接失败，请检查网络或更换服务',
  };

  Future<List<DandanplayEpisode>> search(String title, {int? episode}) async {
    final query = searchTitle(title);
    if (query.isEmpty) {
      throw const DandanplayException('请先填写要匹配的片名');
    }
    final json = await _get('/api/v2/search/episodes', {
      'anime': query,
      'v2': 'true',
      if (episode != null) 'episode': '$episode',
    });
    final direct = _parseSearch(json);
    // Some compatible services apply the episode filter before resolving all
    // platforms. Their unfiltered catalogue can contain more sources for this
    // exact episode. Keep IDs scoped to the selected service.
    if (!credentials.official && episode != null) {
      try {
        final all = _parseSearch(
          await _get('/api/v2/search/episodes', {'anime': query, 'v2': 'true'}),
        );
        final ids = direct.map((e) => e.id).toSet();
        direct.addAll(
          all.where(
            (e) =>
                (e.number ?? parsedEpisodeNumber(e.episode)) == episode &&
                ids.add(e.id),
          ),
        );
      } catch (_) {
        // An optional wider search must not discard successful direct results.
      }
    }
    LumeLog.info(
      '[danmaku] search "$query" ep=${episode ?? '-'} -> ${direct.length}',
    );
    if (!credentials.official ||
        direct.any((e) => normalizedTitle(e.title) == normalizedTitle(title))) {
      return direct;
    }
    // Official /search/episodes primarily searches its native catalogue. TV and
    // movie records may live in TMDB and must be resolved through that API.
    //
    // TMDB enrichment is optional: an account without TMDB permission, a
    // transient network error or a 404 here must NOT discard the direct results
    // that already came back. This is why "official search works for custom
    // services but fails for dandanplay" could happen before.
    final extra = <DandanplayEpisode>[];
    try {
      final tmdb = await _get('/api/v2/search/tmdb', {'keyword': query});
      final candidates = (tmdb['animes'] as List? ?? [])
          .whereType<Map>()
          .where(
            (e) =>
                normalizedTitle('${e['animeTitle'] ?? ''}') ==
                normalizedTitle(title),
          )
          .take(3);
      for (final work in candidates) {
        final id = '${work['bangumiId'] ?? ''}';
        if (!RegExp(r'^tmdb-(?:tv|movie)-[0-9]+$').hasMatch(id)) continue;
        // Resolve the TMDB record back to real comment libraries. A synthetic
        // TMDB bangumi can have an episode ID while containing no comments.
        var mapped = <DandanplayEpisode>[];
        try {
          mapped = _parseSearch(
            await _get('/api/v2/search/episodes', {
              'tmdbId': id.split('-').last,
              'tmdbIdType': id.startsWith('tmdb-movie-') ? '1' : '0',
              if (episode != null) 'episode': '$episode',
              'v2': 'true',
            }),
          );
        } catch (_) {
          // Older compatible implementations may not support TMDB lookup.
        }
        extra.addAll(mapped);
        if (mapped.isNotEmpty) continue;
        final detail = await _get(
          '/api/v2/bangumi/${Uri.encodeComponent(id)}',
          {},
        );
        final bangumi = detail['bangumi'];
        if (bangumi is! Map) continue;
        extra.addAll(
          _parseSearch({
            'animes': [
              {
                ...work,
                ...bangumi,
                'animeTitle': work['animeTitle'],
                'animeId': id,
                'source': 'TMDB',
              },
            ],
          }).where((e) => episode == null || e.number == episode),
        );
      }
    } catch (_) {
      // Keep the native-catalogue results; manual matching can still use them.
    }
    final ids = <String>{};
    // Native catalogue results first: TMDB-derived entries often have a
    // dandanplay episodeId but no comments, so they must not shadow a native
    // result with the same title/episode.
    return [...direct, ...extra].where((e) => ids.add(e.id)).toList();
  }

  static List<DandanplayEpisode> _parseSearch(Map<String, dynamic> json) {
    final animes = json['animes'];
    if (animes is! List) {
      throw const DandanplayException('服务未返回作品列表，请检查弹幕服务地址');
    }
    final result = <DandanplayEpisode>[];
    for (final anime in animes) {
      if (anime is! Map) continue;
      final episodes = anime['episodes'];
      if (episodes is! List) continue;
      final animeTitle = '${anime['animeTitle'] ?? ''}'.trim();
      final source = '${anime['source'] ?? ''}'.trim();
      final inferredSource =
          RegExp(
            r'from\s+([\w-]+)\s*$',
            caseSensitive: false,
          ).firstMatch(animeTitle)?.group(1) ??
          '';
      final year =
          int.tryParse('${anime['startDate'] ?? ''}'.split('-').first) ??
          int.tryParse(
            RegExp(r'[（(\[]((?:19|20)\d{2})[）)\]]')
                    .firstMatch(animeTitle)
                    ?.group(1) ??
                '',
          );
      for (final item in episodes) {
        if (item is! Map) continue;
        final id = '${item['episodeId'] ?? ''}';
        if (id.isEmpty || id == 'null' || animeTitle.isEmpty) continue;
        final episodeTitle = '${item['episodeTitle'] ?? item['title'] ?? ''}';
        result.add(
          DandanplayEpisode(
            id: id,
            title: animeTitle,
            episode: episodeTitle,
            animeId: '${anime['animeId'] ?? anime['bangumiId'] ?? ''}',
            source: source.isEmpty ? inferredSource : source,
            type: '${anime['typeDescription'] ?? anime['type'] ?? ''}',
            year: year,
            number:
                int.tryParse('${item['episodeNumber'] ?? ''}') ??
                parsedEpisodeNumber(episodeTitle),
          ),
        );
      }
    }
    return result;
  }

  /// Compatible LogVar APIs; official service keeps its existing matching path.
  Future<DandanplayEpisode?> match(String fileName) async {
    if (credentials.official) return null;
    final json = await _request(
      '/api/v2/match',
      {},
      body: {'fileName': fileName},
    ).timeout(const Duration(seconds: 45));
    if (json['isMatched'] != true || json['matches'] is! List) return null;
    for (final raw in json['matches'] as List) {
      if (raw is! Map || raw['episodeId'] == null) continue;
      final item = DandanplayEpisode(
        id: '${raw['episodeId']}',
        title: '${raw['animeTitle'] ?? ''}',
        episode: '${raw['episodeTitle'] ?? ''}',
        animeId: '${raw['animeId'] ?? ''}',
      );
      if (!item.supplementary && item.title.isNotEmpty) return item;
    }
    return null;
  }

  Future<Map<String, dynamic>> commentPayload({
    String? id,
    Uri? videoUrl,
    bool segments = true,
  }) {
    if (videoUrl != null &&
        (!['http', 'https'].contains(videoUrl.scheme) ||
            videoUrl.host.isEmpty ||
            videoUrl.userInfo.isNotEmpty)) {
      throw const DandanplayException('请填写有效的平台视频链接');
    }
    return _get(
      id == null
          ? '/api/v2/comment'
          : '/api/v2/comment/${Uri.encodeComponent(id)}',
      {
        'format': 'json',
        'duration': 'true',
        'withRelated': 'true',
        if (!credentials.official && segments) 'segmentflag': 'true',
        if (videoUrl != null) 'url': videoUrl.toString(),
      },
    );
  }

  Future<DanmakuTrack> segment(Map<String, dynamic> descriptor) async =>
      parseComments(
        await _request('/api/v2/segmentcomment', {
          'format': 'json',
        }, body: descriptor).timeout(const Duration(seconds: 45)),
      );

  Future<Map<String, dynamic>> favorites() => _get('/api/v2/favorite/list', {});

  Future<void> updateFavorite(String action, String keyword) async {
    if (!['add', 'refresh', 'remove'].contains(action)) {
      throw ArgumentError.value(action);
    }
    await _request(
      '/api/v2/favorite/$action',
      {},
      body: {'keyword': keyword},
    ).timeout(const Duration(seconds: 45));
  }

  Future<DanmakuTrack> comments(String id) async {
    final json = await _get('/api/v2/comment/${Uri.encodeComponent(id)}', {
      'withRelated': 'true',
      'format': 'json',
      // The local upstream caches comment results. If its first upstream fetch
      // failed and cached an empty list, retrying immediately would keep
      // returning 0. A changing cache key makes "重新加载本集" actually retry.
      if (credentials.builtin) '_': '${DateTime.now().microsecondsSinceEpoch}',
    });
    if (json['comments'] is! List) {
      throw const DandanplayException('服务未返回弹幕列表，请重试或检查弹幕服务地址');
    }
    final track = parseComments(json);
    LumeLog.info('[danmaku] comments $id -> ${track.length}');
    return track;
  }

  static DanmakuTrack parseComments(Map<String, dynamic> json) {
    final result = <DanmakuItem>[];
    for (final raw in (json['comments'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final fields = '${raw['p'] ?? ''}'.split(',');
      final seconds = fields.isEmpty ? null : double.tryParse(fields[0]);
      final text = '${raw['m'] ?? ''}'.trim();
      if (seconds == null ||
          !seconds.isFinite ||
          seconds < 0 ||
          text.isEmpty ||
          fields.length < 3) {
        continue;
      }
      result.add(
        DanmakuItem(
          time: Duration(milliseconds: (seconds * 1000).round()),
          text: text,
          mode: DanmakuMode.fromId(fields[1]),
          color: int.tryParse(fields[2]) ?? 0xFFFFFF,
        ),
      );
    }
    return DanmakuTrack.parse(result);
  }

  static final RegExp _fromSuffix = RegExp(
    r'(?:\s+from\s+|(?<=[）)】\]])\s*from\s*)([^\s]+)$',
    caseSensitive: false,
  );

  static final RegExp _bracketTag = RegExp(r'[【\[（(]([^】\]）)]*)[】\]）)]');

  static final RegExp _yearToken = RegExp(r'^(?:19|20)\d{2}年?$');

  static final RegExp _seasonTag = RegExp(
    r'第\s*(?:\d+|[零〇一二两三四五六七八九十百]+)\s*季|season\s*\d+|\bS\d{1,2}\b',
    caseSensitive: false,
  );

  static final RegExp _episodeCount = RegExp(
    r'^(?:全|共|更新至|已更新|连载至)\s*\d+\s*[集话話期]?$',
    caseSensitive: false,
  );

  static final RegExp _episodeNumberToken = RegExp(
    r'^第?\s*(?:\d+|[零〇一二两三四五六七八九十百]+)\s*[集话話期]$',
  );

  static final RegExp _separator = RegExp(r'[\s·•・|/\\_\-—–.．]+');

  static final RegExp _trailingToken = RegExp(
    r'[\s·•・|/\\_\-—–.．]+([^\s·•・|/\\_\-—–.．]+)\s*$',
  );

  /// 服务端作品名里的常见装饰。只按“整词”匹配，避免误伤
  /// `电影人生` 这种名字里恰好包含类型词的标题。
  static const Set<String> _metadataTokens = <String>{
    // 类型
    '国产剧', '电视剧', '连续剧', '剧集', '动漫', '动画', '番剧', '综艺',
    '纪录片', '电影', '美剧', '日剧', '韩剧', '港剧', '台剧', '短剧',
    '网剧', '微短剧',
    // 语言 / 字幕
    '国语', '粤语', '普通话', '中字', '中文字幕', '双语', '日语', '英语',
    '韩语', '原声', '配音', '国语版', '粤语版', '普通话版', '中字版',
    '双语版', '国语中字', '国粤双语', '中英双字', '中英字幕', '简繁字幕',
    '简中', '繁中',
    // 清晰度 / 压制
    '4k', '2160p', '1080p', '720p', '480p', 'hd', 'bd', 'fhd', 'uhd',
    'hdr', '蓝光', '超清', '高清', '原画', '标清', 'tv', 'tv版',
    'web-dl', 'webrip', 'bluray', 'remux',
    // 平台
    'tencent', 'qq', 'youku', 'iqiyi', 'qiyi', 'mgtv', 'bilibili',
    'sohu', 'migu', 'leshi', 'xigua', 'hongguo', 'bahamut', 'animeko',
    'dandan', 'tmdb', 'imgo', '360', 'vod', 'local', 'custom', 'renren',
    'hanjutv',
    '腾讯视频', '优酷', '爱奇艺', '芒果tv', '哔哩哔哩', 'b站', '咪咕视频',
    '搜狐视频', '乐视视频', '西瓜视频', '人人视频', '韩剧tv',
    // 状态
    '完结', '已完结', '连载', '更新中', '抢先版', '未删减', '未删减版',
  };

  static bool _isMetadataToken(String token) {
    final value = token.trim().toLowerCase();
    if (value.isEmpty) return false;
    // 季数是有意义的信息，不能当装饰词删掉。
    if (_seasonTag.hasMatch(value)) return false;
    return _yearToken.hasMatch(value) ||
        _episodeCount.hasMatch(value) ||
        _episodeNumberToken.hasMatch(value) ||
        _metadataTokens.contains(value);
  }

  static bool _isMetadataBracket(String inner) {
    final value = inner.trim();
    if (value.isEmpty || _seasonTag.hasMatch(value)) return false;
    if (_isMetadataToken(value)) return true;
    final parts = value.split(_separator).where((part) => part.isNotEmpty);
    return parts.isNotEmpty && parts.every(_isMetadataToken);
  }

  /// 自动匹配和手动搜索共用的片名清洗。
  ///
  /// 图源标题常见为 `大刑伺候 2026·国产剧·tencent`、
  /// `[国产剧] 大刑伺候 全40集 1080P` 这类形态。只去掉年份/类型/语言/
  /// 清晰度/平台等装饰，保留季数、`OVA`、`剧场版`、`【我推的孩子】`
  /// 这类可能改变作品身份的信息。
  static String searchTitle(String title) {
    var value = title.trim();
    if (value.isEmpty) return value;

    value = value.replaceFirstMapped(_fromSuffix, (match) {
      final platform = match.group(1) ?? '';
      return _isMetadataToken(platform) ? '' : match.group(0)!;
    }).trim();

    value = value
        .replaceAllMapped(
          _bracketTag,
          (match) =>
              _isMetadataBracket(match.group(1) ?? '') ? '' : match.group(0)!,
        )
        .trim();

    // 年份既可能单独出现，也可能夹在季数/平台之间：
    // `大刑伺候 2026 第二季` 只去掉年份，保留第二季。
    value = value
        .replaceAll(
          RegExp(
            r'[\s·•・|/\\_\-—–.．]+(?:19|20)\d{2}年?(?=[\s·•・|/\\_\-—–.．]|$)',
          ),
          '',
        )
        .trim();
    // 不删开头的年份：`2001 太空漫游` / `2012` 本身就是片名，
    // 只有年份出现在标题之后（或中文标题直接粘连）才当作装饰。
    // 中文标题后直接跟年份、没有分隔符的情况。
    value = value
        .replaceAll(
          RegExp(
            r'(?<=[\u4e00-\u9fff])(?:19|20)\d{2}年?(?=[\s·•・|/\\_\-—–.．]|$)',
          ),
          '',
        )
        .trim();

    // `WEB-DL` / `Blu-Ray` 这类压制标记自带连字符，直接按整段清掉，
    // 避免被后面的逐词逻辑拆成 `WEB` 和 `DL`。
    value = value
        .replaceAll(
          RegExp(
            r'[\s·•・|/\\_\-—–.．]*(?:web[\s-]?dl|webrip|web[\s-]?rip|blu[\s-]?ray|bdrip|brrip|remux|hdtv)(?=[\s·•・|/\\_\-—–.．]|$)',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    // 从末尾逐个剥掉平台/类型/语言/清晰度等整词，
    // 遇到季数（第二季 / S02）就停。
    while (true) {
      final match = _trailingToken.firstMatch(value);
      if (match == null) break;
      final token = match.group(1) ?? '';
      if (!_isMetadataToken(token)) break;
      value = value.substring(0, match.start).trim();
    }

    // `全40集` / `更新至20集` 可能和片名粘在一起。
    value = value
        .replaceFirst(
          RegExp(
            r'[\s·•・|/\\_\-—–.．]*(?:全|共|更新至|已更新|连载至)\s*\d+\s*[集话話期]?$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    value = value.replaceFirst(RegExp(r'[\s·•・|/\\_\-—–.．]+$'), '').trim();
    return value.isEmpty ? title.trim() : value;
  }

  static String normalizedTitle(String title) =>
      searchTitle(title)
          .toLowerCase()
          .replaceAll(RegExp(r'[\s·・:：\-—_，,。.!！?？《》「」【】\[\]（）()]'), '');

  static int episodeNumber(String chapterTitle, {required int chapterIndex}) {
    return parsedEpisodeNumber(chapterTitle) ?? chapterIndex + 1;
  }

  /// Unknown episode titles stay unknown when validating server search results.
  static int? parsedEpisodeNumber(String chapterTitle) {
    final title = chapterTitle.trim();
    final match = RegExp(
      r'第\s*(\d+)\s*[集话話期]|\b(?:S\d+\s*)?E(?:P)?\s*(\d+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    final number = int.tryParse(match?.group(1) ?? match?.group(2) ?? title);
    if (number != null && number > 0) return number;
    if (RegExp(
      r'正片|蓝光|藍光|高清|超清|1080|2160|720|4K|\b(?:HD|BD|FHD|UHD)\b',
      caseSensitive: false,
    ).hasMatch(title)) {
      return 1;
    }
    final suffix = RegExp(r'(?:^|[_\s-])(\d{1,3})(?:\s|$)').firstMatch(title);
    if (suffix != null) return int.tryParse(suffix.group(1)!);
    final chinese = RegExp(r'第\s*([零〇一二两三四五六七八九十百]+)\s*[集话話期]')
        .firstMatch(title)
        ?.group(1);
    if (chinese != null) {
      const digits = {
        '零': 0,
        '〇': 0,
        '一': 1,
        '二': 2,
        '两': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
      };
      var total = 0, digit = 0;
      for (final char in chinese.split('')) {
        if (char == '十' || char == '百') {
          total += (digit == 0 ? 1 : digit) * (char == '十' ? 10 : 100);
          digit = 0;
        } else {
          digit = digits[char]!;
        }
      }
      return total + digit > 0 ? total + digit : null;
    }
    return null;
  }

  static DandanplayEpisode? exactMatch(
    List<DandanplayEpisode> items,
    String title, {
    int? episode,
  }) {
    final exact = items
        .where(
          (item) =>
              !item.supplementary &&
              normalizedTitle(item.title) == normalizedTitle(title) &&
              (episode == null ||
                  (item.number ?? parsedEpisodeNumber(item.episode)) ==
                      episode),
        )
        .toList();
    if (exact.length == 1) return exact.single;
    if (exact.length > 1) {
      // Prefer a native source over a TMDB-only mapping when both match.
      final native = exact
          .where((item) => item.source.toLowerCase() != 'tmdb')
          .toList();
      if (native.length == 1) return native.single;
    }
    return null;
  }

  /// 自动匹配的候选队列：同名、同集、非附加内容；原生来源在前，TMDB 在后。
  ///
  /// [exactMatch] 要求唯一，同名同集有多个来源时会返回 null；自动匹配不应
  /// 因此直接失败，而应按顺序尝试，取第一个有弹幕的条目。
  static List<DandanplayEpisode> candidates(
    Iterable<DandanplayEpisode> items,
    String title, {
    int? episode,
    int limit = 4,
  }) {
    final query = normalizedTitle(title);
    if (query.isEmpty) return const <DandanplayEpisode>[];
    final exact = items
        .where(
          (item) =>
              !item.supplementary &&
              normalizedTitle(item.title) == query &&
              (episode == null ||
                  (item.number ?? parsedEpisodeNumber(item.episode)) ==
                      episode),
        )
        .toList();
    exact.sort((a, b) {
      final aTmdb = a.source.toLowerCase() == 'tmdb' ? 1 : 0;
      final bTmdb = b.source.toLowerCase() == 'tmdb' ? 1 : 0;
      return aTmdb.compareTo(bTmdb);
    });
    final seen = <String>{};
    return exact
        .where((item) => seen.add(item.id))
        .take(limit)
        .toList(growable: false);
  }

  /// 同一作品、同一集、非 TMDB 的候选，用于某个条目返回 0 条时换一个来源。
  ///
  /// 集数未知时返回空表：宁可让用户手动选，也不要把其他集的弹幕加载进来。
  static List<DandanplayEpisode> alternatives(
    Iterable<DandanplayEpisode> items,
    DandanplayEpisode selected, {
    int? episode,
    int limit = 3,
  }) {
    final number =
        episode ?? selected.number ?? parsedEpisodeNumber(selected.episode);
    final title = normalizedTitle(selected.title);
    if (number == null || title.isEmpty) {
      return const <DandanplayEpisode>[];
    }
    return items
        .where(
          (item) =>
              item.id != selected.id &&
              !item.supplementary &&
              item.source.toLowerCase() != 'tmdb' &&
              normalizedTitle(item.title) == title &&
              (item.number ?? parsedEpisodeNumber(item.episode)) == number,
        )
        .take(limit)
        .toList(growable: false);
  }
}
