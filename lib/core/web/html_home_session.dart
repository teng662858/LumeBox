import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../net/lume_http.dart';
import '../net/network_settings.dart';
import 'html_home_sdk.dart';
import 'web_home_sources.dart';

class HtmlHomePlayback {
  const HtmlHomePlayback(
    this.uri,
    this.title,
    this.headers,
    this.shareLink, {
    this.password = '',
    this.playlistId = '',
    this.itemId = '',
    this.episodes = const [],
    this.selected = 0,
    this.cover,
    this.description = '',
  });
  final Uri uri;
  final String title;
  final Map<String, String> headers;
  final bool shareLink;
  final String password, playlistId, itemId, description;
  final List<({String title, String line})> episodes;
  final int selected;
  final String? cover;

  static HtmlHomePlayback parse(Map args) {
    var url = '${args['url'] ?? ''}'.trim();
    final share = url.startsWith('push://');
    if (share) url = url.substring(7);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https', 'magnet'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme != 'magnet' && uri.host.isEmpty)) {
      throw const FormatException('播放地址需为 HTTP(S)、网盘分享或磁力链接');
    }
    final options = args['options'];
    final playlist = options is Map ? options['playlist'] : null;
    final episodes = <({String title, String line})>[];
    var selected = 0;
    if (playlist != null) {
      if (playlist is! Map ||
          playlist['id'] is! String ||
          (playlist['id'] as String).length > 96 ||
          playlist['episodes'] is! List ||
          (playlist['episodes'] as List).isEmpty ||
          (playlist['episodes'] as List).length > 2000 ||
          playlist['selected'] is! int) {
        throw const FormatException('网页选集格式无效');
      }
      selected = playlist['selected'] as int;
      for (final raw in playlist['episodes'] as List) {
        if (raw is! Map) throw const FormatException('网页剧集格式无效');
        episodes.add((
          title: '${raw['title'] ?? ''}',
          line: '${raw['line'] ?? ''}',
        ));
      }
      if (selected < 0 || selected >= episodes.length) {
        throw const FormatException('网页选集下标无效');
      }
    }
    return HtmlHomePlayback(
      uri,
      '${args['title'] ?? ''}',
      htmlHomeHeaders(options is Map ? options['headers'] : null),
      share,
      password: options is Map ? '${options['password'] ?? ''}' : '',
      playlistId: playlist is Map ? '${playlist['id']}' : '',
      itemId: playlist is Map ? '${playlist['itemId'] ?? ''}' : '',
      episodes: List.unmodifiable(episodes),
      selected: selected,
      cover: playlist is Map ? '${playlist['cover'] ?? ''}' : null,
      description: playlist is Map ? '${playlist['description'] ?? ''}' : '',
    );
  }
}

Map<String, String> htmlHomeHeaders(Object? raw) {
  if (raw == null) return {};
  if (raw is! Map || raw.length > 64) throw const FormatException('请求头格式无效');
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final key = '${entry.key}', value = '${entry.value}';
    if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9a-zA-Z-]+$').hasMatch(key) ||
        value.contains(RegExp(r'[\r\n]')) ||
        value.length > 8192) {
      throw const FormatException('请求头包含无效字符或过长');
    }
    if (!['host', 'content-length', 'connection'].contains(key.toLowerCase())) {
      result[key] = value;
    }
  }
  return result;
}

/// Session-scoped HTTP home and resource proxy. It binds IPv4 loopback only,
/// authenticates paths with an unpredictable token and closes with its page.
/// RPC uses same-origin fetch so it does not need a privileged global JS channel.
class HtmlHomeSession {
  HtmlHomeSession._(
    this.source,
    this.store,
    this._server,
    this._http,
    this.onPlay,
    this.onChrome,
    this.viewport,
  ) : _token = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );

  final WebHomeSource source;
  final WebHomeStore store;
  final HttpServer _server;
  final LumeHttp _http;
  final Future<void> Function(HtmlHomePlayback) onPlay;
  final Future<Map<String, dynamic>> Function(Map) onChrome;
  Map<String, dynamic> viewport;
  final String _token;
  final _episodeRequests = <int, Completer<HtmlHomePlayback>>{};
  int _episodeSequence = 0;
  Future<HtmlHomePlayback> resolveEpisode(
    String playlist,
    int index,
    Future<void> Function(String) evaluate,
  ) async {
    if (_closed) throw StateError('网页已关闭');
    final job = ++_episodeSequence;
    final pending = Completer<HtmlHomePlayback>();
    _episodeRequests[job] = pending;
    try {
      unawaited(
        Future<void>.sync(
          () => evaluate(
            'window.__lumeResolveHomeEpisode($job,${jsonEncode(playlist)},$index);',
          ),
        ).catchError((Object error, StackTrace stack) {
          if (!pending.isCompleted) pending.completeError(error, stack);
        }),
      );
      return await pending.future.timeout(const Duration(seconds: 30));
    } finally {
      _episodeRequests.remove(job);
    }
  }

  bool _closed = false;
  int _active = 0;
  static const maxResponseBytes = 8 * 1024 * 1024;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/$_token/');
  Uri get page => base.resolve('index.html');

  static Future<HtmlHomeSession> start({
    required WebHomeSource source,
    required WebHomeStore store,
    required Future<void> Function(HtmlHomePlayback) onPlay,
    required Future<Map<String, dynamic>> Function(Map) onChrome,
    Map<String, dynamic> viewport = const {'chromeMode': 'normal'},
    LumeHttp? http,
  }) async {
    if (!source.isLocal) {
      throw ArgumentError('Only imported HTML enables the SDK');
    }
    final settings = http == null
        ? (await NetworkSettingsStore.open()).load()
        : null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = HtmlHomeSession._(
      source,
      store,
      server,
      http ?? LumeHttp(settings: settings, source: '网页:${source.name}'),
      onPlay,
      onChrome,
      Map.of(viewport),
    );
    server.listen(
      (request) => unawaited(session._handle(request)),
      onError: (_) {},
    );
    return session;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final request in _episodeRequests.values) {
      if (!request.isCompleted) request.completeError(StateError('网页已关闭'));
    }
    _http.dispose();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      if (_closed ||
          request.headers.value('host') != base.authority ||
          !request.uri.path.startsWith('/$_token/')) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      final path = request.uri.path.substring('/$_token/'.length);
      if (path == 'index.html' && request.method == 'GET') {
        final state = store.readLocalState(source.id)['storage'];
        final sdk = htmlHomeSdk(
          base.resolve('rpc').toString(),
          state is Map<String, dynamic> ? state : {},
          viewport,
        );
        final script = '<script>$sdk</script>';
        final original = source.html!;
        final head = RegExp(
          r'<head\b[^>]*>',
          caseSensitive: false,
        ).firstMatch(original);
        final html = head == null
            ? '$script$original'
            : original.replaceRange(head.end, head.end, script);
        request.response.headers.contentType = ContentType.html;
        request.response.write(html);
        return;
      }
      if (_active >= 24) {
        request.response.statusCode = HttpStatus.tooManyRequests;
        _json(request, {'error': '网页请求过多，请稍后重试'});
        return;
      }
      _active++;
      counted = true;
      if (path == 'rpc' && request.method == 'POST') {
        if (request.headers.value('origin') != base.origin) {
          request.response.statusCode = HttpStatus.forbidden;
          return;
        }
        final bytes = <int>[];
        await for (final chunk in request) {
          if (bytes.length + chunk.length > 512 * 1024) {
            throw const FormatException('网页调用数据不能超过 512 KB');
          }
          bytes.addAll(chunk);
        }
        final call = jsonDecode(utf8.decode(bytes));
        if (call is! Map || call['method'] is! String || call['args'] is! Map) {
          throw const FormatException('网页调用格式无效');
        }
        if (_closed) return;
        _json(request, {
          'result': await dispatch(
            call['method'] as String,
            call['args'] as Map,
          ),
        });
      } else if (path == 'resource' && request.method == 'GET') {
        final url = request.uri.queryParameters['url'] ?? '';
        _validateUrl(url);
        final headers = htmlHomeHeaders(
          jsonDecode(request.uri.queryParameters['headers'] ?? '{}'),
        );
        final response = await _http.send(
          url: url,
          headers: headers,
          timeout: const Duration(seconds: 25),
          maxBytes: maxResponseBytes,
        );
        if (_closed) return;
        request.response.statusCode = response.statusCode;
        request.response.headers.set(
          'Content-Type',
          response.headers['content-type'] ?? 'application/octet-stream',
        );
        request.response.add(response.body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (error) {
      if (!_closed) {
        try {
          request.response.statusCode = HttpStatus.badRequest;
          _json(request, {'error': '$error'});
        } catch (_) {}
      }
    } finally {
      if (counted) _active--;
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _json(HttpRequest request, Object data) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
  }

  void _validateUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请求仅支持 HTTP(S) 地址');
    }
  }

  Future<Object?> dispatch(String method, Map args) async {
    if (_closed) throw StateError('网页已关闭');
    switch (method) {
      case 'request':
        final url = '${args['url'] ?? ''}';
        _validateUrl(url);
        final options = args['options'] is Map
            ? args['options'] as Map
            : const {};
        final verb = '${options['method'] ?? 'GET'}'.toUpperCase();
        if (![
          'GET',
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
          'HEAD',
          'OPTIONS',
        ].contains(verb)) {
          throw const FormatException('不支持的请求方法');
        }
        final headers = htmlHomeHeaders(options['headers']);
        final rawBody = options.containsKey('body')
            ? options['body']
            : options['data'];
        final body = rawBody is Map || rawBody is List
            ? jsonEncode(rawBody)
            : rawBody?.toString();
        if (rawBody is Map || rawBody is List) {
          headers.putIfAbsent('Content-Type', () => 'application/json');
        }
        final seconds = options['timeout'];
        final timeout = seconds is num && seconds.isFinite
            ? seconds.toInt().clamp(1, 60)
            : 20;
        try {
          final response = await _http.send(
            url: url,
            method: verb,
            headers: headers,
            body: verb == 'GET' || verb == 'HEAD' ? null : body,
            timeout: Duration(seconds: timeout),
            maxBytes: maxResponseBytes,
          );
          Object? data = response.text;
          if (options['responseType'] == 'json') {
            data = jsonDecode(response.text);
          }
          return {
            'ok': response.statusCode >= 200 && response.statusCode < 300,
            'status': response.statusCode,
            'body': data,
            'headers': response.headers,
            'url': response.url ?? url,
          };
        } catch (error) {
          return {
            'ok': false,
            'status': 0,
            'body': '',
            'headers': <String, String>{},
            'error': '$error',
          };
        }
      case 'episode.result':
        final pending = _episodeRequests[args['job']];
        if (pending == null || pending.isCompleted) return false;
        if (args['error'] != null) {
          pending.completeError(StateError('${args['error']}'));
        } else {
          try {
            pending.complete(HtmlHomePlayback.parse(args['value'] as Map));
          } catch (error, stack) {
            pending.completeError(error, stack);
          }
        }
        return true;
      case 'play':
        await onPlay(HtmlHomePlayback.parse(args));
        return {'opened': true};
      case 'chrome':
        viewport = await onChrome(args);
        return viewport;
      case 'storage.set':
      case 'storage.remove':
      case 'storage.clear':
      case 'cache.get':
      case 'cache.set':
      case 'cache.remove':
        final state = store.readLocalState(source.id);
        final storage = method.startsWith('storage.');
        final area = storage ? 'storage' : 'cache';
        final raw = state[area];
        final values = raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
        final key = storage
            ? '${args['key'] ?? ''}'
            : jsonEncode([args['scope'] ?? '', args['key'] ?? '']);
        if (key.length > 256) throw const FormatException('缓存键过长');
        if (method == 'cache.get') return values[key];
        if (method == 'storage.clear') {
          values.clear();
        } else if (method.endsWith('.remove')) {
          values.remove(key);
        } else {
          final value = args['value'];
          if (utf8.encode(jsonEncode(value)).length > 256 * 1024) {
            throw const FormatException('单项缓存超过 256 KB');
          }
          values[key] = value;
        }
        state[area] = values;
        store.writeLocalState(source.id, state);
        return true;
      default:
        throw UnsupportedError('不支持的网页接口：$method');
    }
  }
}
