import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import '../search/search_settings.dart';
import '../net/lume_net.dart';

enum TmdbPosterStyle { fixed, random, carousel }

/// Appearance changes do not invalidate metadata or restart matching.
@immutable
class TmdbDetailAppearance {
  const TmdbDetailAppearance({
    this.backgroundBrightness = 1,
    this.backgroundSaturation = 1,
    this.posterBrightness = 1,
    this.fadeStrength = 1,
    this.logoScale = 1,
  });
  final double backgroundBrightness, backgroundSaturation;
  final double posterBrightness, fadeStrength, logoScale;

  static double bounded(Object? value, double min, double max) =>
      value is num && value.isFinite ? value.toDouble().clamp(min, max) : 1;

  factory TmdbDetailAppearance.fromJson(Map data) => TmdbDetailAppearance(
    backgroundBrightness: bounded(data['backgroundBrightness'], .3, 2.5),
    backgroundSaturation: bounded(data['backgroundSaturation'], 0, 3),
    posterBrightness: bounded(data['posterBrightness'], .2, 1.8),
    fadeStrength: bounded(data['fadeStrength'], 0, 3),
    logoScale: bounded(data['logoScale'], .5, 2.5),
  );
  Map<String, double> toJson() => {
    'backgroundBrightness': backgroundBrightness,
    'backgroundSaturation': backgroundSaturation,
    'posterBrightness': posterBrightness,
    'fadeStrength': fadeStrength,
    'logoScale': logoScale,
  };
  TmdbDetailAppearance withValue(String field, double value) =>
      TmdbDetailAppearance.fromJson({...toJson(), field: value});
}

enum TmdbImageKind {
  backdrop('背景图', ['original', 'w1280', 'w780'], 'w1280'),
  logo('Logo', ['original', 'w500'], 'w500'),
  poster('海报', ['original', 'w780', 'w500', 'w342'], 'w780'),
  profile('演员头像', ['original', 'w632', 'w185'], 'w185'),
  video('视频封面', ['original', 'w500', 'w300'], 'w300');

  const TmdbImageKind(this.label, this.sizes, this.defaultSize);
  final String label;
  final List<String> sizes;
  final String defaultSize;
}

class TmdbSettings extends ChangeNotifier {
  TmdbSettings();
  static final instance = TmdbSettings();
  static const builtInApiKey = String.fromEnvironment(
    'TMDB_API_KEY',
    defaultValue: 'e8cb17a07eb5091739aaceb3ab2e7120',
  );
  bool enabled = true;
  bool detailBackdropEnabled = true;
  final detailAppearance = ValueNotifier(const TmdbDetailAppearance());
  final detailOverrides = ValueNotifier<Map<String, TmdbDetailAppearance>>({});
  TmdbDetailAppearance appearanceFor(String? key) =>
      detailOverrides.value[key] ?? detailAppearance.value;
  void setAppearance(String? key, TmdbDetailAppearance value) {
    if (key == null) {
      detailAppearance.value = value;
    } else {
      detailOverrides.value = {...detailOverrides.value, key: value};
    }
  }

  void clearAppearance(String key) {
    detailOverrides.value = {...detailOverrides.value}..remove(key);
  }

  TmdbPosterStyle posterStyle = TmdbPosterStyle.random;
  String apiKey = '', apiProxy = '', imageProxy = '';
  final Map<TmdbImageKind, String> _imageSizes = {};
  String imageSize(TmdbImageKind kind) => _imageSizes[kind] ?? kind.defaultSize;
  void setImageSize(TmdbImageKind kind, String size) {
    if (!kind.sizes.contains(size)) throw ArgumentError.value(size, 'size');
    _imageSizes[kind] = size;
  }

  int revision = 0;
  File? _file;
  Future<void> _writes = Future.value();
  Future<void> boot() async {
    _imageSizes.clear();
    detailAppearance.value = const TmdbDetailAppearance();
    detailOverrides.value = {};
    try {
      _file = File(
        '${(await getApplicationSupportDirectory()).path}/tmdb_settings.json',
      );
      if (await _file!.exists()) {
        final data =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        for (final kind in TmdbImageKind.values) {
          final value = (data['imageSizes'] as Map?)?[kind.name];
          _imageSizes[kind] = kind.sizes.contains(value)
              ? value as String
              : kind.defaultSize;
        }
        // Older settings saved the old default w500 even without an explicit
        // user choice. Upgrade that legacy default once; retain w342/original.
        if (data['posterQualityVersion'] != 2 &&
            imageSize(TmdbImageKind.poster) == 'w500') {
          _imageSizes[TmdbImageKind.poster] = 'w780';
        }
        enabled = data['enabled'] != false;
        detailBackdropEnabled = data['detailBackdropEnabled'] != false;
        final overrides = data['detailOverrides'];
        if (overrides is Map) {
          detailOverrides.value = {
            for (final e in overrides.entries)
              if (e.key is String && e.value is Map)
                e.key as String: TmdbDetailAppearance.fromJson(e.value as Map),
          };
        }
        if (data['detailAppearance'] is Map) {
          detailAppearance.value = TmdbDetailAppearance.fromJson(
            data['detailAppearance'] as Map,
          );
        }
        apiKey = data['apiKey'] as String? ?? '';
        apiProxy = data['apiProxy'] as String? ?? '';
        imageProxy = data['imageProxy'] as String? ?? '';
        posterStyle =
            TmdbPosterStyle.values
                .where((e) => e.name == data['posterStyle'])
                .firstOrNull ??
            TmdbPosterStyle.random;
      }
    } catch (_) {
      enabled = false;
    }
  }

  Future<void> save({bool appearanceOnly = false}) async {
    if (!appearanceOnly) {
      revision++;
      notifyListeners();
    }
    final snapshot = jsonEncode({
      'enabled': enabled,
      'detailBackdropEnabled': detailBackdropEnabled,
      'detailAppearance': detailAppearance.value.toJson(),
      'detailOverrides': {
        for (final e in detailOverrides.value.entries) e.key: e.value.toJson(),
      },
      'apiKey': apiKey,
      'apiProxy': apiProxy,
      'imageProxy': imageProxy,
      'posterStyle': posterStyle.name,
      'posterQualityVersion': 2,
      'imageSizes': {
        for (final kind in TmdbImageKind.values) kind.name: imageSize(kind),
      },
    });
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final file = _file;
      if (file == null) return;
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    await _writes;
  }

  final Map<String, dynamic> _cache = {};
  Future<void>? _cacheLoad;
  Future<void> _cacheWrites = Future.value();
  String cacheKey(String title, {String? year, String? mediaType}) =>
      jsonEncode([
        'detail-facts-v5',
        apiProxy.trim(),
        imageProxy.trim(),
        TmdbClient.normalized(TmdbClient.cleanTitle(title)),
        year ?? TmdbClient.titleYear(title),
        mediaType,
        for (final kind in TmdbImageKind.values) imageSize(kind),
      ]);
  Future<TmdbMetadata?> cached(String key) async {
    await (_cacheLoad ??= () async {
      try {
        final file = _file;
        if (file != null) {
          final cache = File('${file.parent.path}/tmdb_metadata.json');
          if (await cache.exists()) {
            _cache.addAll(
              jsonDecode(await cache.readAsString()) as Map<String, dynamic>,
            );
          }
        }
      } catch (_) {
        /* Damaged cache must not affect source details. */
      }
    }());
    final value = _cache[key];
    if (value is! Map<String, dynamic>) return null;
    try {
      return TmdbMetadata.fromJson(value);
    } catch (_) {
      _cache.remove(key);
      return null;
    }
  }

  Future<void> cache(
    String key,
    TmdbMetadata? value, {
    bool waitForDisk = true,
  }) async {
    await cached(key);
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache.remove(key);
      _cache[key] = value.toJson();
      while (_cache.length > 200) {
        _cache.remove(_cache.keys.first);
      }
    }
    final snapshot = jsonEncode(_cache);
    _cacheWrites = _cacheWrites
        .catchError((Object _) {})
        .then((_) async {
          final file = _file;
          if (file == null) return;
          final target = File('${file.parent.path}/tmdb_metadata.json');
          final temp = File('${target.path}.tmp');
          await temp.writeAsString(snapshot, flush: true);
          await temp.rename(target.path);
        })
        .catchError((Object _) {
          // Cache persistence must not delay or fail the detail page.
        });
    if (!waitForDisk) return;
    try {
      await _cacheWrites;
    } catch (_) {
      /* Cache writes are best effort. */
    }
  }

  Future<void> flush() async {
    await _writes;
    await _cacheWrites;
  }

  Future<int> clearMetadataCache() async {
    await cached('');
    final count = _cache.length;
    final urls = <String>{};
    for (final raw in _cache.values.whereType<Map>()) {
      for (final field in [
        'posters',
        'backdrops',
        'logos',
        'profiles',
        'videoCovers',
      ]) {
        final values = raw[field];
        if (values is List) {
          urls.addAll(
            values.whereType<String>().where((url) => url.isNotEmpty),
          );
        }
      }
      for (final row
          in (raw['recommendations'] as List? ?? []).whereType<Map>()) {
        if (row['poster'] is String && (row['poster'] as String).isNotEmpty) {
          urls.add(row['poster'] as String);
        }
      }
    }
    revision++;
    _cache.clear();
    await cache('', null);
    for (final url in urls) {
      final image = NetworkImage(url);
      PaintingBinding.instance.imageCache.evict(image, includeLive: false);
      for (final width in [300, 384]) {
        final key = await ResizeImage.resizeIfNeeded(
          width,
          null,
          image,
        ).obtainKey(ImageConfiguration.empty);
        PaintingBinding.instance.imageCache.evict(key, includeLive: false);
      }
    }
    return count;
  }

  Future<void> disconnect() {
    enabled = false;
    apiKey = '';
    apiProxy = '';
    imageProxy = '';
    return save();
  }

  bool get usesBuiltInKey => apiKey.trim().isEmpty;
  String get _effectiveKey => usesBuiltInKey ? builtInApiKey : apiKey.trim();
  bool get configured => enabled && credential.isNotEmpty;
  String get credential => _effectiveKey.replaceFirst(
    RegExp(r'^Bearer\s+', caseSensitive: false),
    '',
  );
  bool get usesBearer =>
      _effectiveKey.toLowerCase().startsWith('bearer ') ||
      (credential.startsWith('eyJ') && credential.split('.').length == 3);
  static Uri address(String raw, String fallback) {
    var value = raw.trim();
    if (value.isEmpty) value = fallback;
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 地址');
    }
    return uri;
  }

  Uri apiUri(
    String endpoint, {
    Uri? base,
    Map<String, String> query = const {},
  }) {
    final root = base ?? address(apiProxy, 'https://api.themoviedb.org');
    final prefix = root.path.replaceAll(RegExp(r'/+$'), '');
    return root.replace(
      path: '$prefix${prefix.endsWith('/3') ? '' : '/3'}/$endpoint',
      queryParameters: {
        ...root.queryParameters,
        ...query,
        if (!usesBearer) 'api_key': credential,
      },
    );
  }

  String imageUrl(String path, {TmdbImageKind kind = TmdbImageKind.poster}) {
    final base = address(imageProxy, 'https://image.tmdb.org/t/p/');
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base
        .replace(
          path:
              '$prefix/${imageSize(kind)}/${path.replaceFirst(RegExp(r'^/+'), '')}',
        )
        .toString();
  }
}

class TmdbRecommendation {
  const TmdbRecommendation({required this.title, required this.poster});
  final String title, poster;
  Map<String, dynamic> toJson() => {'title': title, 'poster': poster};
  factory TmdbRecommendation.fromJson(Map<String, dynamic> data) =>
      TmdbRecommendation(
        title: data['title'] as String? ?? '',
        poster: data['poster'] as String? ?? '',
      );
}

class TmdbMetadata {
  const TmdbMetadata({
    required this.overview,
    required this.posters,
    this.backdrops = const [],
    this.logos = const [],
    this.profiles = const [],
    this.videoCovers = const [],
    this.cast = const [],
    this.recommendations = const [],
    this.rating = 0,
    this.voteCount = 0,
    this.year = '',
    this.genres = const [],
    this.episodeCount = 0,
    this.preferredPoster,
  });
  final String overview;
  final List<String> posters, backdrops, cast, logos, profiles, videoCovers;
  final List<TmdbRecommendation> recommendations;
  final double rating;
  final int voteCount;
  final String year;
  final List<String> genres;
  final int episodeCount;
  final String? preferredPoster;
  Map<String, dynamic> toJson() => {
    'overview': overview,
    'posters': posters,
    'backdrops': backdrops,
    'logos': logos,
    'profiles': profiles,
    'videoCovers': videoCovers,
    'cast': cast,
    'recommendations': recommendations.map((item) => item.toJson()).toList(),
    'rating': rating,
    'voteCount': voteCount,
    'year': year,
    'genres': genres,
    'episodeCount': episodeCount,
    if (preferredPoster != null) 'preferredPoster': preferredPoster,
  };
  factory TmdbMetadata.fromJson(Map<String, dynamic> data) => TmdbMetadata(
    recommendations: (data['recommendations'] as List? ?? [])
        .whereType<Map>()
        .map(
          (row) => TmdbRecommendation.fromJson(Map<String, dynamic>.from(row)),
        )
        .where((item) => item.title.trim().isNotEmpty)
        .toList(),
    overview: data['overview'] as String? ?? '',
    posters: (data['posters'] as List? ?? []).whereType<String>().toList(),
    backdrops: (data['backdrops'] as List? ?? []).whereType<String>().toList(),
    cast: (data['cast'] as List? ?? []).whereType<String>().toList(),
    logos: (data['logos'] as List? ?? []).whereType<String>().toList(),
    profiles: (data['profiles'] as List? ?? []).whereType<String>().toList(),
    videoCovers: (data['videoCovers'] as List? ?? [])
        .whereType<String>()
        .toList(),
    rating: (data['rating'] as num?)?.toDouble() ?? 0,
    voteCount: (data['voteCount'] as num?)?.toInt() ?? 0,
    year: data['year'] as String? ?? '',
    genres: (data['genres'] as List? ?? []).whereType<String>().toList(),
    episodeCount: (data['episodeCount'] as num?)?.toInt() ?? 0,
    preferredPoster: data['preferredPoster'] as String?,
  );
}

class TmdbMatchCandidate {
  const TmdbMatchCandidate({
    required this.id,
    required this.mediaType,
    required this.title,
    this.year = '',
    this.overview = '',
  });
  final int id;
  final String mediaType, title, year, overview;
  String get label =>
      '${mediaType == 'tv' ? '剧集' : '电影'} · ${year.isEmpty ? '年份未知' : year}';
}

class TmdbClient {
  TmdbClient(this.settings, {http.Client? client}) : _injected = client {
    settings.addListener(_changed);
  }
  final TmdbSettings settings;
  final http.Client? _injected;
  final _active = <http.Client>{};
  http.Client? _owned;
  final _pending = <String, Future<TmdbMetadata?>>{};
  bool lastLookupRetryable = false;
  void _changed() {
    for (final client in _active.toList()) {
      client.close();
    }
    _active.clear();
    _owned?.close();
    _owned = null;
    _pending.clear();
  }

  void dispose() {
    settings.removeListener(_changed);
    _changed();
  }

  Future<http.Response> _get(Uri uri, int revision, {bool head = false}) async {
    if (!settings.enabled || settings.revision != revision) {
      throw StateError('TMDB 已关闭或配置已改变');
    }
    final client = _injected ?? (_owned ??= _networkClient());
    _active.add(client);
    try {
      final request = http.Request(head ? 'HEAD' : 'GET', uri)
        ..followRedirects = !head;
      if (!head && settings.usesBearer) {
        request.headers['Authorization'] = 'Bearer ${settings.credential}';
      }
      // One budget covers connection, response headers and body together.
      final response = await (() async {
        final stream = await client.send(request);
        return http.Response.fromStream(stream);
      })().timeout(const Duration(seconds: 12));
      if (!settings.enabled || settings.revision != revision) {
        throw StateError('TMDB 已关闭或配置已改变');
      }
      return response;
    } catch (_) {
      if (_injected == null) {
        client.close();
        if (identical(_owned, client)) _owned = null;
      }
      rethrow;
    } finally {
      _active.remove(client);
    }
  }

  http.Client _networkClient() {
    final proxy = LumeNet.settings.proxy.trim();
    if (proxy.isEmpty) return http.Client();
    final uri = Uri.tryParse(proxy);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw StateError('TMDB 需要有效的全局 HTTP 代理，或使用 TMDB API 代理地址');
    }
    final port = uri.hasPort
        ? uri.port
        : uri.scheme == 'https'
        ? 443
        : 80;
    return IOClient(HttpClient()..findProxy = (_) => 'PROXY ${uri.host}:$port');
  }

  Future<Uri?> _resolvedBase(int revision) async {
    var uri = TmdbSettings.address(
      settings.apiProxy,
      'https://api.themoviedb.org',
    );
    if (uri.host != 'shturl.cc') return uri;
    for (var i = 0; i < 5; i++) {
      final response = await _get(uri, revision, head: true);
      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return uri;
      throw StateError('API 代理短链解析失败（HTTP ${response.statusCode}）');
    }
    throw StateError('API 代理重定向次数过多');
  }

  Future<Map<String, dynamic>> _json(
    String path,
    int revision,
    Uri? base, {
    Map<String, String> query = const {},
  }) async {
    late http.Response response;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        response = await _get(
          settings.apiUri(path, base: base, query: query),
          revision,
        );
        if (attempt == 0 &&
            (response.statusCode >= 500 || response.statusCode == 429)) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
        break;
      } on Exception catch (error) {
        if (attempt > 0 ||
            !(error is TimeoutException ||
                error is SocketException ||
                error is http.ClientException)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 401) {
        throw StateError(
          settings.usesBuiltInKey
              ? 'TMDB 鉴权失败（HTTP 401）。内置密钥未被当前服务接受，可填写自己的 v3 Key 或 v4 Token。'
              : 'TMDB 鉴权失败（HTTP 401）。请检查自定义 v3 Key 或 v4 Token。',
        );
      }
      if (response.statusCode == 403) {
        throw StateError('TMDB 拒绝访问（HTTP 403），请检查服务权限、代理及网络出口。');
      }
      if (response.statusCode == 429) {
        throw StateError('TMDB 请求过于频繁（HTTP 429），请稍后重试。');
      }
      throw StateError('TMDB 请求失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) throw StateError('TMDB 返回了无效的 JSON');
    return data;
  }

  Future<void> testApi() async {
    if (!settings.configured) throw StateError('请先启用 TMDB');
    final revision = settings.revision;
    final base = await _resolvedBase(revision);
    final data = await _json('configuration', revision, base);
    if (data['images'] is! Map) throw StateError('代理未返回有效的 TMDB 配置信息');
  }

  Future<List<int>> testImage() async {
    if (!settings.enabled) throw StateError('请先启用 TMDB');
    final response = await _get(
      Uri.parse(settings.imageUrl('/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg')),
      settings.revision,
    );
    if (response.statusCode != 200) {
      throw StateError('图片代理请求失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  String? lastError;
  Future<List<TmdbMatchCandidate>> searchMatches(String title) async {
    lastError = null;
    if (!settings.configured || title.trim().isEmpty) return [];
    final revision = settings.revision;
    try {
      final base = await _resolvedBase(revision);
      final data = await _json(
        'search/multi',
        revision,
        base,
        query: {'query': cleanTitle(title), 'language': 'zh-CN'},
      );
      if (!settings.configured || settings.revision != revision) return [];
      final seen = <String>{};
      return (data['results'] as List? ?? [])
          .whereType<Map>()
          .where(
            (row) =>
                ['movie', 'tv'].contains(row['media_type']) &&
                row['id'] is int &&
                seen.add('${row['media_type']}/${row['id']}'),
          )
          .map(
            (row) => TmdbMatchCandidate(
              id: row['id'] as int,
              mediaType: row['media_type'] as String,
              title: '${row['title'] ?? row['name'] ?? ''}',
              year:
                  RegExp(r'^\d{4}').stringMatch(
                    '${row['first_air_date'] ?? row['release_date'] ?? ''}',
                  ) ??
                  '',
              overview: '${row['overview'] ?? ''}',
            ),
          )
          .where((row) => row.title.trim().isNotEmpty)
          .toList();
    } catch (error) {
      lastError = error is StateError
          ? error.message.toString()
          : 'TMDB 搜索失败，请检查网络或 API 代理后重试';
      return [];
    }
  }

  Future<TmdbMetadata?> selectMatch(
    String title,
    TmdbMatchCandidate candidate, {
    String? year,
    String? mediaType,
  }) =>
      _lookup(title, selected: candidate, yearHint: year, mediaType: mediaType);

  static String cleanTitle(String value) {
    var title = SearchSettings.toSimplified(value).trim();
    for (var i = 0; i < 3; i++) {
      title = title
          .replaceAll(
            RegExp(
              r'[\s._-]*[（(\[]?(?:国语|粤语|普通话|中字|字幕|高清|超清|蓝光|完整版|更新至\d+集?|全\d+集|第\d+集|2160[pP]|1080[pP]|720[pP]|4[kK])[）)\]]?\s*$',
            ),
            '',
          )
          .trim();
      title = title
          .replaceAll(RegExp(r'[（(\[](?:19|20)\d{2}[）)\]]'), '')
          .replaceAll(RegExp(r'\s+(?:19|20)\d{2}$'), '')
          .trim();
    }
    return title;
  }

  static String normalized(String value) =>
      SearchSettings.toSimplified(value)
          .toLowerCase()
          .replaceAll(RegExp(r'[\s·:：\-《》、，,。.!！?？（）()\[\]]'), '');
  static String? titleYear(String title) =>
      RegExp(r'(?:\s|[（(\[]|^)((?:19|20)\d{2})(?=[）)\]\s]|$)')
          .firstMatch(title)
          ?.group(1);

  Future<TmdbMetadata?> lookup(
    String title, {
    bool force = false,
    String? year,
    String? mediaType,
  }) {
    if (!settings.configured) return Future.value(null);
    final key =
        '${settings.revision}:${settings.cacheKey(title, year: year, mediaType: mediaType)}';
    if (!force && _pending[key] != null) return _pending[key]!;
    final task = _lookup(
      title,
      force: force,
      yearHint: year,
      mediaType: mediaType,
    );
    _pending[key] = task;
    return task.whenComplete(() {
      if (identical(_pending[key], task)) _pending.remove(key);
    });
  }

  Future<TmdbMetadata?> _lookup(
    String title, {
    bool force = false,
    String? yearHint,
    String? mediaType,
    TmdbMatchCandidate? selected,
  }) async {
    lastError = null;
    lastLookupRetryable = false;
    if (!settings.configured) return null;
    final revision = settings.revision;
    final cacheKey = settings.cacheKey(
      title,
      year: yearHint,
      mediaType: mediaType,
    );
    try {
      final cached = await settings.cached(cacheKey);
      if (!settings.configured || settings.revision != revision) return null;
      if (selected == null && !force && cached != null) return cached;
      if (selected == null && force) await settings.cache(cacheKey, null);
      final base = await _resolvedBase(revision);
      Map? match = selected == null
          ? null
          : {'id': selected.id, 'media_type': selected.mediaType};
      Map<String, dynamic>? matchedDetails;
      final cleaned = cleanTitle(title);
      final year = yearHint ?? titleYear(title);
      for (final query
          in selected == null ? <String>{cleaned, title.trim()} : <String>{}) {
        if (query.isEmpty) continue;
        final data = await _json(
          'search/multi',
          revision,
          base,
          query: {'query': query, 'language': 'zh-CN'},
        );
        final candidates = (data['results'] as List? ?? [])
            .whereType<Map>()
            .where(
              (row) =>
                  ['movie', 'tv'].contains(row['media_type']) &&
                  row['id'] is int &&
                  (mediaType == null || row['media_type'] == mediaType) &&
                  (year == null ||
                      '${row['release_date'] ?? row['first_air_date'] ?? ''}'
                          .isEmpty ||
                      '${row['release_date'] ?? row['first_air_date'] ?? ''}'
                          .startsWith(year)),
            )
            .toList();
        bool same(Object? name) =>
            name is String &&
            normalized(cleanTitle(name)) == normalized(cleaned);
        final exact = candidates
            .where(
              (row) => [
                row['title'],
                row['name'],
                row['original_title'],
                row['original_name'],
              ].any(same),
            )
            .toList();
        if (exact.length > 1) {
          lastError = 'TMDB 有多个同名版本，缺少足够年份或影片类型信息，已保留源资料';
          return null;
        }
        if (exact.length == 1) {
          match = exact.single;
          break;
        }
        // Check a bounded number of translated aliases; never accept the first search hit blindly.
        final checked = await Future.wait(
          candidates.take(3).map((candidate) async {
            final details = await _json(
              '${candidate['media_type']}/${candidate['id']}',
              revision,
              base,
              query: {
                'language': 'zh-CN',
                'include_image_language': 'zh,en,null',
                'append_to_response': 'credits,alternative_titles,translations,recommendations,images',
              },
            );
            final alternatives = details['alternative_titles'] as Map? ?? {};
            final translations =
                (details['translations'] as Map?)?['translations'] as List? ??
                [];
            final aliases = <Object?>[
              details['title'],
              details['name'],
              details['original_title'],
              details['original_name'],
              ...(alternatives['titles'] as List? ??
                      alternatives['results'] as List? ??
                      [])
                  .whereType<Map>()
                  .map((row) => row['title']),
              ...translations.whereType<Map>().expand(
                (row) => [
                  (row['data'] as Map?)?['title'],
                  (row['data'] as Map?)?['name'],
                ],
              ),
            ];
            final candidateYear =
                '${details['first_air_date'] ?? details['release_date'] ?? candidate['first_air_date'] ?? candidate['release_date'] ?? ''}';
            if (aliases.any(same) &&
                (year == null || candidateYear.startsWith(year))) {
              return (candidate, details);
            }
            return null;
          }),
        );
        final verified = checked
            .whereType<(Map, Map<String, dynamic>)>()
            .toList();
        if (verified.length > 1) {
          lastError = 'TMDB 别名存在多个匹配版本，已保留源资料';
          return null;
        }
        if (verified.length == 1) {
          match = verified.single.$1;
          matchedDetails = verified.single.$2;
          break;
        }
      }
      if (match == null) {
        lastLookupRetryable = true;
        return null;
      }
      final type = match['media_type'], id = match['id'];
      final details =
          matchedDetails ??
          await _json(
            '$type/$id',
            revision,
            base,
            query: {
              'language': 'zh-CN',
              'include_image_language': 'zh,en,null',
              'append_to_response': 'credits,alternative_titles,translations,recommendations,images',
            },
          );
      final actualYear =
          '${details['first_air_date'] ?? details['release_date'] ?? match['first_air_date'] ?? match['release_date'] ?? ''}';
      if (selected == null && year != null && !actualYear.startsWith(year)) {
        lastError = 'TMDB 年份与源信息不一致，已保留源资料';
        return null;
      }
      // Standard TMDB combines artwork with details. Older API proxies may omit
      // appended images; only those need a separate compatibility request.
      Map<String, dynamic> images = details['images'] is Map
          ? Map<String, dynamic>.from(details['images'] as Map)
          : {};
      if (details['images'] is! Map) {
        try {
          images = await _json('$type/$id/images', revision, base);
        } catch (_) {
          lastError = 'TMDB 图片列表暂时无法获取，已保留其他影片资料';
        }
      }
      List<String> paths(String field, Object? fallback, TmdbImageKind kind) {
        final artwork = (images[field] as List? ?? [])
            .whereType<Map>()
            .toList();
        // Prefer Chinese title artwork while keeping TMDB's ranking within
        // each language. Users can still select any supplied poster.
        if (field == 'posters') {
          int rank(Map row) => switch (row['iso_639_1']) {
            'zh' => 0,
            null => 1,
            'en' => 2,
            _ => 3,
          };
          final indexed = artwork.indexed.toList()
            ..sort((a, b) {
              final language = rank(a.$2).compareTo(rank(b.$2));
              return language == 0 ? a.$1.compareTo(b.$1) : language;
            });
          artwork
            ..clear()
            ..addAll(indexed.map((row) => row.$2));
        }
        final values = artwork
            .map((row) => row['file_path'])
            .whereType<String>()
            .where((path) => path.startsWith('/'))
            .toList();
        if (values.isEmpty && fallback is String && fallback.startsWith('/')) {
          values.add(fallback);
        }
        return values
            .map((path) => settings.imageUrl(path, kind: kind))
            .toList();
      }

      if (!settings.configured || settings.revision != revision) return null;
      final seenRecommendations = <String>{};
      final result = TmdbMetadata(
        recommendations:
            ((details['recommendations'] as Map?)?['results'] as List? ?? [])
                .whereType<Map>()
                .where((row) => row['adult'] != true && row['id'] != id)
                .map(
                  (row) => TmdbRecommendation(
                    title: '${row['title'] ?? row['name'] ?? ''}'.trim(),
                    poster:
                        row['poster_path'] is String &&
                            (row['poster_path'] as String).startsWith('/')
                        ? settings.imageUrl(row['poster_path'] as String)
                        : '',
                  ),
                )
                .where(
                  (item) =>
                      item.title.isNotEmpty &&
                      seenRecommendations.add(normalized(item.title)),
                )
                .take(12)
                .toList(),
        overview: (details['overview'] as String?)?.trim().isNotEmpty == true
            ? details['overview'] as String
            : match['overview'] as String? ?? '',
        posters: paths(
          'posters',
          details['poster_path'] ?? match['poster_path'],
          TmdbImageKind.poster,
        ),
        backdrops: paths(
          'backdrops',
          details['backdrop_path'] ?? match['backdrop_path'],
          TmdbImageKind.backdrop,
        ),
        logos: paths('logos', null, TmdbImageKind.logo),
        videoCovers: paths(
          'stills',
          details['still_path'],
          TmdbImageKind.video,
        ),
        profiles: ((details['credits'] as Map?)?['cast'] as List? ?? [])
            .whereType<Map>()
            .map((row) => row['profile_path'])
            .map(
              (path) => path is String && path.startsWith('/')
                  ? settings.imageUrl(path, kind: TmdbImageKind.profile)
                  : '',
            )
            .toList(),
        rating:
            ((details['vote_average'] ?? match['vote_average']) as num?)
                ?.toDouble() ??
            0,
        voteCount:
            ((details['vote_count'] ?? match['vote_count']) as num?)?.toInt() ??
            0,
        year:
            RegExp(r'^\d{4}').stringMatch(
              '${details['first_air_date'] ?? details['release_date'] ?? match['first_air_date'] ?? match['release_date'] ?? ''}',
            ) ??
            '',
        genres: (details['genres'] as List? ?? [])
            .whereType<Map>()
            .map((row) => '${row['name'] ?? ''}'.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList(),
        episodeCount: (details['number_of_episodes'] as num?)?.toInt() ?? 0,
        cast: ((details['credits'] as Map?)?['cast'] as List? ?? [])
            .whereType<Map>()
            .map((row) => row['name'])
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toList(),
      );
      await settings.cache(cacheKey, result, waitForDisk: false);
      return settings.configured && settings.revision == revision
          ? result
          : null;
    } catch (error) {
      // Do not expose URLs or API keys in UI or logs.
      lastLookupRetryable =
          error is TimeoutException ||
          error is SocketException ||
          error is http.ClientException ||
          (error is StateError &&
              RegExp(r'HTTP (429|5\d\d)').hasMatch(error.message));
      lastError = error is StateError
          ? error.message.toString()
          : error is FormatException
          ? 'TMDB 返回内容无效，请检查 API 代理'
          : 'TMDB 网络请求失败，请检查 API 代理后重试';
      return null;
    }
  }
}
