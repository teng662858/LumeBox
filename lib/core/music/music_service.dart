import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../audio_book/audio_book_track.dart';
import '../net/lume_http.dart';
import '../net/lume_net.dart';
import '../net/network_cancellation.dart';
import '../net/source_subscription.dart';
import 'lx_catalog.dart';
import 'music_library.dart';
import 'music_models.dart';
import 'music_runtime.dart';

class MusicSearchResult {
  const MusicSearchResult(
    this.tracks, {
    this.failures = const [],
    this.hasMore = false,
  });
  final List<MusicTrack> tracks;
  final List<String> failures;
  final bool hasMore;
}

class MusicService {
  MusicService({
    MusicLibrary? library,
    MusicRuntimeFactory? factory,
    Future<SourceFetchResult> Function(String)? fetch,
    LxCatalog? catalog,
  }) : library = library ?? MusicLibrary.instance,
       factory = factory ?? QuickJsMusicRuntime.create,
       fetch = fetch ?? _fetch,
       catalog = catalog ?? LxCatalog();
  static final instance = MusicService();
  final MusicLibrary library;
  final MusicRuntimeFactory factory;
  final Future<SourceFetchResult> Function(String) fetch;
  final LxCatalog catalog;
  final _runtimes = <String, MusicRuntime>{};
  final _pending = <String, Future<void>>{};
  Future<void> _imports = Future.value();
  Object? _networkSettings;
  static Future<SourceFetchResult> _fetch(String url) async {
    final http = LumeHttp(settings: LumeNet.settings);
    try {
      return await SourceSubscription.fetchSubscription(http, url);
    } finally {
      http.dispose();
    }
  }

  Future<Object?> _call(
    MusicPlugin plugin,
    String method,
    Map<String, dynamic> args,
  ) async {
    // A plugin may keep request state in globals; never overlap calls to it.
    final previous = _pending[plugin.id] ?? Future.value();
    final task = previous.then((_) async {
      if (!identical(_networkSettings, LumeNet.settings)) {
        dispose();
        _networkSettings = LumeNet.settings;
      }
      final active = library.plugin(plugin.id);
      if (active == null || !active.enabled) throw StateError('音乐源已停用或删除');
      final runtime = _runtimes[plugin.id] ??= await factory(
        plugin.id,
        await library.script(plugin.id),
        plugin.protocol,
      );
      try {
        return await runtime.call(method, {
          ...args,
          'variables': active.values,
        });
      } catch (_) {
        _runtimes.remove(plugin.id)?.dispose();
        rethrow;
      }
    });
    final settled = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[plugin.id] = settled;
    try {
      return await task;
    } finally {
      if (identical(_pending[plugin.id], settled)) _pending.remove(plugin.id);
      while (_runtimes.length > 4) {
        final idle = _runtimes.keys
            .where((id) => !_pending.containsKey(id))
            .firstOrNull;
        if (idle == null) break;
        _runtimes.remove(idle)?.dispose();
      }
    }
  }

  void invalidate(String id) => _runtimes.remove(id)?.dispose();
  void dispose() {
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
  }

  Future<MusicPlugin> importScript(String script, {String origin = ''}) {
    final task = _imports.then((_) => _importScript(script, origin: origin));
    _imports = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<MusicPlugin> _importScript(String script, {String origin = ''}) async {
    await library.load();
    if (utf8.encode(script).length > 4 * 1024 * 1024) {
      throw const FormatException('音乐插件超过 4 MB');
    }
    final preferred =
        RegExp(r'(?:globalThis\.lx|\blx\s*\.|\}\s*=\s*(?:globalThis\.)?lx\b)')
            .hasMatch(script)
        ? MusicProtocol.lx
        : MusicProtocol.musicFree;
    final temporary = sha256.convert(utf8.encode(script)).toString();
    final inspected = await _inspect(temporary, script, preferred);
    final protocol = inspected.protocol, runtime = inspected.runtime;
    try {
      final info = inspected.info;
      final name = '${info['name'] ?? ''}'.trim();
      if (name.isEmpty) throw const FormatException('音源未提供名称');
      final id = sha256
          .convert(utf8.encode('${protocol.name}:$name'))
          .toString();
      final old = library.plugin(id);
      final plugin = MusicPlugin(
        id: id,
        name: name,
        protocol: protocol,
        version: '${info['version'] ?? ''}',
        origin: origin.isEmpty ? old?.origin ?? '' : origin,
        enabled: old?.enabled ?? true,
        values: old?.values ?? {},
        capabilities: List<String>.from(info['capabilities'] as List? ?? []),
        primaryKey: List<String>.from(info['primaryKey'] as List? ?? ['id']),
        platforms: (info['platforms'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', List<String>.from(v as List)),
        ),
        variables: [
          for (final v in info['variables'] as List? ?? [])
            if (v is Map) Map<String, dynamic>.from(v),
        ],
      );
      invalidate(id);
      await library.install(plugin, script);
      return plugin;
    } finally {
      runtime.dispose();
    }
  }

  Future<
    ({MusicProtocol protocol, MusicRuntime runtime, Map<String, dynamic> info})
  >
  _inspect(String id, String script, MusicProtocol preferred) async {
    final errors = <Object>[];
    for (final protocol in [
      preferred,
      ...MusicProtocol.values.where((p) => p != preferred),
    ]) {
      MusicRuntime? runtime;
      try {
        runtime = await factory(id, script, protocol);
        final info = await runtime.describe();
        return (protocol: protocol, runtime: runtime, info: info);
      } catch (e) {
        runtime?.dispose();
        errors.add(e);
      }
    }
    throw FormatException('无法识别为 MusicFree 或 LX 标准音乐源：${errors.join('；')}');
  }

  Future<({int imported, List<String> failures})> importUrl(String url) async {
    var imported = 0;
    final failures = <String>[];
    final visited = <String>{};
    Future<void> visit(String input, int depth) async {
      if (depth > 3 || visited.length >= 100) {
        throw const FormatException('订阅层级或条目过多');
      }
      final uri = Uri.parse(input);
      if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
        throw const FormatException('请输入 HTTP(S) 脚本或订阅链接');
      }
      if (!visited.add(input)) return;
      final result = await fetch(input);
      if (result.bytes.length > 4 * 1024 * 1024) {
        throw const FormatException('订阅或插件超过 4 MB');
      }
      Object? data;
      try {
        data = jsonDecode(result.text);
      } on FormatException {
        /* JavaScript. */
      }
      final entries = data is Map
          ? data['plugins']
          : data is List
          ? data
          : null;
      if (entries is List) {
        for (final entry in entries) {
          final child = entry is String
              ? entry
              : entry is Map
              ? entry['url'] ?? entry['srcUrl']
              : null;
          if (child is! String) {
            failures.add('订阅条目缺少 url');
            continue;
          }
          try {
            await visit(uri.resolve(child).toString(), depth + 1);
          } catch (e) {
            failures.add('$child：$e');
          }
        }
      } else {
        await importScript(result.text, origin: input);
        imported++;
      }
    }

    await visit(url.trim(), 0);
    return (imported: imported, failures: failures);
  }

  Future<MusicSearchResult> search(
    String keyword, {
    int page = 1,
    String? pluginId,
    String? platform,
  }) async {
    await library.load();
    if (keyword.trim().isEmpty) return const MusicSearchResult([]);
    final enabled = library.plugins
        .where((p) => p.enabled && (pluginId == null || p.id == pluginId))
        .toList();
    final tracks = <MusicTrack>[];
    final failures = <String>[];
    var more = false, cursor = 0;
    Future<void> worker() async {
      while (cursor < enabled.length) {
        NetworkCancellation.current?.check();
        final plugin = enabled[cursor++];
        try {
          if (plugin.protocol == MusicProtocol.musicFree) {
            if (!plugin.capabilities.contains('search')) continue;
            final result = await _call(plugin, 'search', {
              'query': keyword,
              'page': page,
            }) as Map?;
            if (result == null || result['data'] is! List) {
              throw const FormatException('音源未返回有效搜索结果');
            }
            for (final row in result['data'] as List) {
              if (row is Map) {
                tracks.add(
                  MusicTrack.parse(
                    plugin.id,
                    row,
                    primaryKey: plugin.primaryKey,
                  ),
                );
              }
            }
            more |=
                result['isEnd'] != true && (result['data'] as List).isNotEmpty;
          } else {
            for (final key in plugin.platforms.keys.where(
              (p) => platform == null || platform == p,
            )) {
              if (key == 'local') continue;
              try {
                final result = await catalog.search(
                  plugin.id,
                  key,
                  keyword,
                  page,
                );
                tracks.addAll(result.tracks);
                more |= result.hasMore;
              } catch (e) {
                NetworkCancellation.current?.check();
                failures.add('${plugin.name} / ${LxCatalog.label(key)}：$e');
              }
            }
          }
        } catch (e) {
          NetworkCancellation.current?.check();
          failures.add('${plugin.name}：$e');
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 3 && i < enabled.length; i++) worker(),
    ]);
    final seen = <String>{};
    return MusicSearchResult(
      tracks.where((t) => seen.add(t.key)).toList(),
      failures: failures,
      hasMore: more,
    );
  }

  Future<ResolvedAudio> resolve(MusicTrack track) async {
    final plugin = library.plugin(track.pluginId);
    if (plugin == null || !plugin.enabled) throw StateError('请先启用这首歌的音乐源');
    final quality = plugin.protocol == MusicProtocol.musicFree
        ? library.quality
        : _lxQuality(plugin, track.platform);
    final result = await _call(plugin, 'media', {
      'track': track.raw,
      'platform': track.platform,
      'quality': quality,
    });
    final url = result is String
        ? result
        : result is Map
        ? result['url']
        : null;
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw StateError('音源没有返回可播放的 HTTP(S) 地址');
    }
    final headers = result is Map && result['headers'] is Map
        ? (result['headers'] as Map).map((k, v) => MapEntry('$k', '$v'))
        : <String, String>{};
    if (result is Map && result['userAgent'] is String) {
      headers['User-Agent'] = result['userAgent'] as String;
    }
    return ResolvedAudio(uri, headers: headers);
  }

  String _lxQuality(MusicPlugin plugin, String platform) {
    final declared = plugin.platforms[platform] ?? [];
    final preferred = switch (library.quality) {
      'low' => '128k',
      'high' => 'flac',
      'super' => 'flac24bit',
      _ => '320k',
    };
    if (declared.contains(preferred)) return preferred;
    final order = ['128k', '320k', 'flac', 'flac24bit'];
    final limit = order.indexOf(preferred);
    for (var i = limit; i >= 0; i--) {
      if (declared.contains(order[i])) return order[i];
    }
    return declared.isEmpty ? '128k' : declared.first;
  }

  Future<MusicLyrics> lyrics(MusicTrack track) async {
    final plugin = library.plugin(track.pluginId);
    if (plugin == null) return const MusicLyrics();
    // LX only declares lyric for local; catalog lyrics can be added independently.
    if (plugin.protocol == MusicProtocol.lx && track.platform != 'local') {
      return catalog.lyrics(track);
    }
    final result = await _call(plugin, 'lyric', {
      'track': track.raw,
      'platform': track.platform,
    });
    if (result is! Map) return const MusicLyrics();
    var original =
        '${result['rawLrc'] ?? result['lyric'] ?? result['lrc'] ?? ''}';
    var translation = '${result['translation'] ?? result['tlyric'] ?? ''}';
    Future<String> expand(String value) async {
      if (!value.startsWith('http://') && !value.startsWith('https://')) {
        return value;
      }
      return (await fetch(value)).text;
    }

    original = await expand(original);
    translation = await expand(translation);
    return MusicLyrics(original: original, translation: translation);
  }

  Future<List<MusicTrack>> importSheet(String pluginId, String url) async {
    final plugin = library.plugin(pluginId);
    if (plugin == null || !plugin.capabilities.contains('importMusicSheet')) {
      throw StateError('此音乐源不支持导入歌单');
    }
    final result = await _call(plugin, 'importSheet', {'url': url});
    if (result is! List) throw const FormatException('音乐源未返回有效歌单');
    return [
      for (final row in result)
        if (row is Map)
          MusicTrack.parse(pluginId, row, primaryKey: plugin.primaryKey),
    ];
  }
}
