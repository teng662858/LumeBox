import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../net/lume_http.dart';
import '../source/tvbox_config.dart';
import '../source/tvbox_live_playlist.dart';
import 'sandbox/sandbox_result.dart';
import 'source_engine.dart';

/// Native adapters for data-only CMS/IPTV descriptors. Never executes JSON as JS.
class TvBoxSourceEngine implements SourceEngine, ScriptConfigCapable {
  TvBoxSourceEngine(this.http);
  final LumeHttp http;
  late TvBoxEntry _entry;
  Map<String, Object?> _config = {};
  bool _disposed = false;
  TvBoxLivePlaylist? _playlist;
  DateTime? _liveAt;
  final _details = <String, ({Map value, DateTime at})>{};
  @override
  String get id => 'tvbox';
  @override
  String? loadFailure;
  static bool matches(String script) =>
      RegExp(r'^// LumeTVBox: ', multiLine: true).hasMatch(script);
  @override
  Future<bool> loadScript(String script) async {
    try {
      _entry = TvBoxEntry.fromScript(script)!;
      if (!{TvBoxKind.cms, TvBoxKind.live}.contains(_entry.kind) ||
          (_entry.api.isEmpty && _entry.groups.isEmpty) ||
          (_entry.api.isNotEmpty && !TvBoxConfig.isHttp(_entry.api))) {
        throw const FormatException('无效 TVBox 源描述');
      }
      loadFailure = null;
      return true;
    } catch (_) {
      loadFailure = 'TVBox 源描述无效，请重新导入';
      return false;
    }
  }

  @override
  Future<Set<String>?> contractMethods() async => {
    'categories',
    'home',
    'list',
    'detail',
    'chapters',
    'content',
  };
  @override
  Future<Map<String, Object?>?> metadata() async => _entry.metadata;
  @override
  Future<void> applyScriptConfig(Map<String, Object?> config) async {
    _config = config;
    _details.clear();
    _playlist = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _details.clear();
    _playlist = null;
    http.dispose();
  }

  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) async {
    if (_disposed) {
      return const SandboxFailure(SandboxErrorKind.disposed, '源已释放');
    }
    try {
      final args = argument is Map ? argument : const {};
      return SandboxSuccess(
        _entry.kind == TvBoxKind.live
            ? await _live(method, args)
            : await _cms(method, args),
      );
    } catch (error) {
      return SandboxFailure(
        SandboxErrorKind.script,
        error is FormatException
            ? error.message
            : error is LumeHttpException
            ? error.message
            : '接口响应无效或暂不可用，请检查源地址',
      );
    }
  }

  String get _api {
    final domain = '${_config['domain'] ?? ''}';
    if (!TvBoxConfig.isHttp(domain)) return _entry.api;
    final original = Uri.parse(_entry.api), target = Uri.parse(domain);
    return original
        .replace(
          scheme: target.scheme,
          host: target.host,
          port: target.hasPort ? target.port : null,
        )
        .toString();
  }

  Future<Map> _request(Map<String, String> params) async {
    final base = Uri.parse(_api);
    final query = Map<String, String>.of(base.queryParameters)
      ..removeWhere((k, v) => ['ac', 't', 'pg', 'wd', 'ids'].contains(k));
    query.addAll(params);
    final response = await http.send(
      url: base.replace(queryParameters: query).toString(),
      headers: _entry.headers,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('采集接口返回 HTTP ${response.statusCode}');
    }
    final text = response.text.trim();
    if (text.startsWith('<')) {
      final doc = XmlDocument.parse(text);
      final list = doc.findAllElements('list').firstOrNull;
      final videos = <Map<String, dynamic>>[];
      for (final video in doc.findAllElements('video')) {
        String field(String key) => video.getElement(key)?.innerText ?? '';
        final dds = video.findAllElements('dd').toList();
        videos.add({
          'vod_id': field('id'),
          'vod_name': field('name'),
          'vod_pic': field('pic'),
          'vod_remarks': field('note'),
          'vod_content': field('des'),
          'vod_year': field('year'),
          'vod_play_from': dds
              .map((dd) => dd.getAttribute('flag') ?? '播放')
              .join(r'$$$'),
          'vod_play_url': dds.map((dd) => dd.innerText).join(r'$$$'),
        });
      }
      return {
        'class': [
          for (final ty in doc.findAllElements('ty'))
            {'type_id': ty.getAttribute('id'), 'type_name': ty.innerText},
        ],
        'list': videos,
        'page': list?.getAttribute('page') ?? '1',
        'pagecount': list?.getAttribute('pagecount') ?? '1',
      };
    }
    final raw = jsonDecode(text);
    if (raw is! Map) throw const FormatException('采集接口没有返回 JSON 对象或 XML');
    if (raw['code'] != null &&
        ['0', '-1', '401', '403'].contains('${raw['code']}')) {
      throw const FormatException('采集接口拒绝访问或需要授权');
    }
    return raw;
  }

  List<Map> _rows(Map data) =>
      (data['list'] is List ? data['list'] as List : const [])
          .whereType<Map>()
          .toList();
  Map<String, Object?> _item(Map row) => {
    'id': '${row['vod_id'] ?? ''}',
    'title': '${row['vod_name'] ?? ''}',
    'cover': TvBoxConfig.resolve('${row['vod_pic'] ?? ''}', _api),
    'description': '${row['vod_remarks'] ?? ''}',
    'coverHeaders': _entry.headers,
  };
  Future<Map?> _detail(String id) async {
    final cached = _details[id];
    if (cached != null && DateTime.now().difference(cached.at).inSeconds < 30) {
      return cached.value;
    }
    final rows = _rows(await _request({'ac': 'detail', 'ids': id}));
    final row = rows.where((r) => '${r['vod_id']}' == id).firstOrNull;
    if (row != null) {
      if (_details.length > 32) _details.clear();
      _details[id] = (value: row, at: DateTime.now());
    }
    return row;
  }

  List<({String title, String url, String id})> _episodes(Map row) {
    final flags = '${row['vod_play_from'] ?? ''}'.split(r'$$$');
    final lines = '${row['vod_play_url'] ?? ''}'.split(r'$$$');
    final result = <({String title, String url, String id})>[];
    for (var line = 0; line < lines.length; line++) {
      final episodes = lines[line].split('#');
      for (var ep = 0; ep < episodes.length; ep++) {
        final value = episodes[ep];
        if (value.trim().isEmpty) continue;
        final sep = value.indexOf(r'$');
        final url = sep < 0 ? value : value.substring(sep + 1);
        final title = sep < 0 ? '第 ${ep + 1} 集' : value.substring(0, sep);
        final flag = line < flags.length && flags[line].isNotEmpty
            ? flags[line]
            : '线路 ${line + 1}';
        result.add((title: '$flag · $title', url: url, id: '$line:$ep'));
      }
    }
    return result;
  }

  Future<Object?> _cms(String method, Map args) async {
    if (method == 'categories') {
      final data = await _request({'ac': 'list'});
      return [
        for (final row in (data['class'] as List? ?? []).whereType<Map>())
          if ('${row['type_id'] ?? ''}'.isNotEmpty)
            {'id': '${row['type_id']}', 'title': '${row['type_name'] ?? ''}'},
      ];
    }
    if (method == 'list' || method == 'home') {
      final page = int.tryParse('${args['page'] ?? 1}') ?? 1;
      final data = await _request({
        'ac': 'detail',
        'pg': '$page',
        if ('${args['categoryId'] ?? ''}'.isNotEmpty)
          't': '${args['categoryId']}',
        if ('${args['keyword'] ?? ''}'.trim().isNotEmpty)
          'wd': '${args['keyword']}',
      });
      final items = _rows(data).map(_item).toList();
      return method == 'home'
          ? items
          : {
              'items': items,
              'hasMore': page < (int.tryParse('${data['pagecount']}') ?? page),
            };
    }
    final row = await _detail('${args['id'] ?? ''}');
    if (row == null) return method == 'chapters' ? [] : null;
    if (method == 'detail') {
      return {
        ..._item(row),
        'description': html.parseFragment('${row['vod_content'] ?? ''}').text,
        'year': row['vod_year'],
      };
    }
    final episodes = _episodes(row);
    if (method == 'chapters') {
      return [
        for (final ep in episodes) {'id': ep.id, 'title': ep.title},
      ];
    }
    if (method == 'content') {
      final ep = episodes
          .where((e) => e.id == '${args['chapterId']}')
          .firstOrNull;
      if (ep == null) throw const FormatException('此选集不存在，请刷新详情');
      final url = TvBoxConfig.resolve(ep.url, _api);
      if (url.isEmpty ||
          (!TvBoxConfig.isHttp(ep.url) &&
              !ep.url.startsWith('/') &&
              !ep.url.startsWith('./') &&
              !ep.url.startsWith('../'))) {
        throw const FormatException('此线路需要客户端专属解析，暂不能直接播放');
      }
      final direct = RegExp(
        r'\.(m3u8|mp4|flv|ts|mpd|mkv|m4v|mp3|aac)(?:[?#]|$)',
        caseSensitive: false,
      ).hasMatch(url);
      return {
        'kind': direct ? 'video' : 'webplayer',
        'url': url,
        'headers': _entry.headers,
      };
    }
    throw const FormatException('此接口未实现请求的方法');
  }

  Future<TvBoxLivePlaylist> _loadLive() async {
    if (_playlist != null &&
        _liveAt != null &&
        DateTime.now().difference(_liveAt!).inMinutes < 5) {
      return _playlist!;
    }
    String text, origin = _api;
    if (_entry.groups.isNotEmpty) {
      text = jsonEncode(_entry.groups);
    } else {
      final reply = await http.send(url: _api, headers: _entry.headers);
      if (reply.statusCode < 200 || reply.statusCode >= 300) {
        throw FormatException('直播列表返回 HTTP ${reply.statusCode}');
      }
      text = reply.text;
      origin = reply.url ?? _api;
    }
    _playlist = TvBoxLivePlaylist.parse(
      text,
      origin: origin,
      headers: _entry.headers,
    );
    _liveAt = DateTime.now();
    return _playlist!;
  }

  Future<Object?> _live(String method, Map args) async {
    final playlist = await _loadLive(), channels = playlist.channels;
    final groups = channels.map((e) => e.group).toSet().toList();
    String groupId(String name) =>
        base64UrlEncode(utf8.encode(name)).replaceAll('=', '');
    String channelId(int i) => channels[i].id;
    Map<String, Object?> item(int i) => {
      'id': channelId(i),
      'title': channels[i].name,
      'cover': channels[i].logo,
      'coverHeaders': _entry.headers,
      'description': channels[i].group,
    };
    if (method == 'categories') {
      return [
        for (var i = 0; i < groups.length; i++)
          {'id': groupId(groups[i]), 'title': groups[i]},
      ];
    }
    if (method == 'list' || method == 'home') {
      final category = '${args['categoryId'] ?? ''}',
          keyword = '${args['keyword'] ?? ''}'.toLowerCase();
      final group = groups
          .where((name) => groupId(name) == category)
          .firstOrNull;
      if (category.isNotEmpty && group == null) {
        return {'items': [], 'hasMore': false};
      }
      final matches = [
        for (var i = 0; i < channels.length; i++)
          if ((group == null || channels[i].group == group) &&
              channels[i].name.toLowerCase().contains(keyword))
            item(i),
      ];
      final page = (int.tryParse('${args['page'] ?? 1}') ?? 1).clamp(1, 10000),
          start = (page - 1) * 50;
      final items = matches.skip(start).take(50).toList();
      return method == 'home'
          ? matches.take(50).toList()
          : {'items': items, 'hasMore': start + items.length < matches.length};
    }
    final index = channels.indexWhere((c) => c.id == '${args['id']}');
    if (index < 0) {
      return method == 'chapters' ? [] : null;
    }
    final channel = channels[index];
    if (method == 'detail') return item(index);
    if (method == 'chapters') {
      return [
        for (var i = 0; i < channel.routes.length; i++)
          {'id': '$i', 'title': '${channel.name} · 线路 ${i + 1}'},
      ];
    }
    if (method == 'content') {
      final route = int.tryParse('${args['chapterId']}');
      if (route == null || route < 0 || route >= channel.routes.length) {
        throw const FormatException('直播线路不存在');
      }
      return {
        'kind': 'video',
        'url': channel.routes[route].url,
        'headers': channel.routes[route].headers,
      };
    }
    throw const FormatException('直播源未实现请求的方法');
  }
}
