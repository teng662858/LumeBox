import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Adapts Kazumi XPath and JSON API rules to source HTTP and bounded WebKit.
/// No additional browser, interpreter or background polling is introduced.
class KazumiRule {
  /// Refresh our generated adapter for already imported rules, preserving IDs.
  /// Raw user JavaScript is never rewritten.
  static String upgradeAdapter(String script) {
    final headerEnd = script.indexOf('\n');
    if (headerEnd < 0 ||
        !script.startsWith('// LumeSource: ') ||
        !script.substring(0, headerEnd).contains('"id":"kazumi_')) {
      return script;
    }
    final lines = const LineSplitter().convert(script);
    if (lines.length < 2 ||
        !lines.first.startsWith('// LumeSource: ') ||
        !lines.first.contains('"id":"kazumi_') ||
        !lines[1].startsWith('const kazumiRule = ') ||
        !lines[1].endsWith(';')) {
      return script;
    }
    final raw = lines[1].substring(
      'const kazumiRule = '.length,
      lines[1].length - 1,
    );
    if (!matches(raw)) return script;
    return '${lines.first}\nconst kazumiRule = $raw;\n$_runtime';
  }

  static const officialIndex =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json';
  static List<String>? indexUrls(String text, String origin) {
    final base = Uri.tryParse(origin);
    if (base == null ||
        base.pathSegments.lastOrNull != 'index.json' ||
        !text.trimLeft().startsWith('[')) {
      return null;
    }
    try {
      final rows = jsonDecode(text);
      if (rows is! List ||
          rows.isEmpty ||
          !rows.every(
            (row) =>
                row is Map &&
                row['name'] is String &&
                row.containsKey('version') &&
                row.containsKey('useNativePlayer'),
          )) {
        return null;
      }
      return rows
          .map((row) {
            final name = row['name'] as String;
            if (!RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.-]{0,99}$')
                .hasMatch(name)) {
              throw const FormatException('Kazumi 索引包含无效规则名');
            }
            return base.resolve('${Uri.encodeComponent(name)}.json').toString();
          })
          .toSet()
          .toList();
    } on FormatException {
      return null;
    }
  }

  static bool matches(String text) {
    if (!text.trimLeft().startsWith('{')) return false;
    try {
      final value = jsonDecode(text);
      return value is Map &&
          value.containsKey('searchList') &&
          value.containsKey('chapterResult') &&
          value.containsKey('baseURL');
    } on FormatException {
      return false;
    }
  }

  static String convert(String text, {String originUrl = ''}) {
    final rule = Map<String, Object?>.from(jsonDecode(text) as Map);
    final api = int.tryParse('${rule['api'] ?? 1}');
    if (api == null || api < 1 || api > 9) {
      throw const FormatException('暂不支持此 Kazumi 规则 API 版本');
    }
    if (rule['deprecated'] == true) {
      throw const FormatException('此 Kazumi 规则已被维护者标记为停用');
    }
    final searchApi = rule['searchMode'] == 'api';
    final chapterApi = rule['chapterMode'] == 'api';
    for (final key in [
      'name',
      'baseURL',
      if (!searchApi) ...[
        'searchURL',
        'searchList',
        'searchName',
        'searchResult',
      ],
      if (!chapterApi) ...['chapterRoads', 'chapterResult'],
    ]) {
      final value = rule[key];
      if (value is! String || value.trim().isEmpty || value.length > 8192) {
        throw FormatException('Kazumi 规则缺少有效 $key');
      }
    }
    for (final key in ['baseURL', if (!searchApi) 'searchURL']) {
      final uri = Uri.tryParse(rule[key] as String);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw FormatException('Kazumi $key 必须是 http(s) 地址');
      }
    }
    if (searchApi) _validateApi(rule['searchApiConfig'], search: true);
    if (chapterApi) _validateApi(rule['chapterApiConfig'], search: false);
    final identity = originUrl.isEmpty ? '${rule['name']}' : originUrl;
    final metadata = {
      'id':
          'kazumi_${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}',
      'name': rule['name'],
      'version': '${rule['version'] ?? '1'}',
      'category': 'kazumi',
      'mirrors': [rule['baseURL']],
    };
    return '// LumeSource: ${jsonEncode(metadata)}\nconst kazumiRule = ${jsonEncode(rule)};\n$_runtime';
  }

  static void _validateApi(Object? value, {required bool search}) {
    if (value is! Map || value['request'] is! Map) {
      throw const FormatException('Kazumi API 规则缺少请求配置');
    }
    final request = value['request'] as Map;
    final url = Uri.tryParse('${request['url'] ?? ''}');
    if (url == null ||
        !['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        ![
          'GET',
          'POST',
        ].contains('${request['method'] ?? 'GET'}'.toUpperCase())) {
      throw const FormatException('Kazumi API 请求需要有效 HTTP(S) 地址和 GET/POST 方法');
    }
    final delimited = !search && value['format'] == 'delimited';
    for (final key
        in search
            ? ['listPath', 'namePath', 'sourcePath']
            : delimited
            ? ['roadNamesPath', 'roadEpisodesPath']
            : [
                'episodesPath',
                'episodeNamePath',
                if (value['episodePage'] == null) 'episodeUrlPath',
              ]) {
      _validatePath(value[key]);
    }
    for (final key in ['roadsPath', 'roadNamePath', 'episodeUrlPath']) {
      if (!search && !delimited && '${value[key] ?? ''}'.isNotEmpty) {
        _validatePath(value[key]);
      }
    }
    if (value['variables'] is Map) {
      for (final path in (value['variables'] as Map).values) {
        _validatePath(path);
      }
    }
    if (delimited) {
      for (final key in [
        'roadSeparator',
        'episodeSeparator',
        'fieldSeparator',
      ]) {
        if (value.containsKey(key) && '${value[key]}'.isEmpty) {
          throw const FormatException('Kazumi 章节分隔符不能为空');
        }
      }
    }
  }

  static void _validatePath(Object? path) {
    if (path is! String ||
        !RegExp(
          r'''^\$(?:(?:\.[A-Za-z0-9_$-]+)|(?:\[(?:\d+|\*|'[^']*'|"[^"]*")\]))*$''',
        ).hasMatch(path)) {
      throw FormatException('Kazumi 不支持此 JSONPath：$path');
    }
  }

  static const _runtime = r'''
function kazumiHeaders(page) {
  const h = {Referer: kazumiRule.referer || page || kazumiRule.baseURL};
  if (kazumiRule.userAgent) h['User-Agent'] = kazumiRule.userAgent;
  return h;
}
async function kazumiPage(url, script, form) {
  const headers = kazumiHeaders(url);
  const options = {url, script, headers, timeoutMs: 8000, includeHtml: false};
  if (form != null) {
    options.method = 'POST'; options.body = form;
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  return LumeSource.web.render(options);
}
function kazumiExtract(mode) {
  return 'const rule = ' + JSON.stringify(kazumiRule) + '; const mode = ' + JSON.stringify(mode) + ';' + `
    function nodes(path, root) {
      // Kazumi evaluates each road's result XPath relative to that road.
      // API8 rules also use /self::... unions, not only // descendants.
      if (root) path = path.replace(/(^|[|]) *[/]/g, '$1 ./');
      return LumeWeb.xpath(path, root || document);
    }
    function href(node) {
      if (!node) return '';
      try { const u = new URL(node.getAttribute('href') || '', location.href); return /^https?:$/.test(u.protocol) ? u.href : ''; } catch (_) { return ''; }
    }
    if (mode === 'home') {
      const seen = new Set(), items = [];
      // Kazumi has no home selectors. Use only real same-site poster links;
      // do not manufacture recommendations from an empty search query.
      for (const a of document.querySelectorAll('a[href]')) {
        if (a.closest('header,footer,nav')) continue;
        const card = a.closest('li,article,.module-item,.public-list-box,.video-item,.video_item,.stui-vodlist__box,.hl-list-item,.myui-vodlist__box') || a;
        const img = a.querySelector('img') || card.querySelector('img');
        if (!img) continue;
        const url = href(a);
        if (!url || seen.has(url)) continue;
        const target = new URL(url);
        if (target.hostname !== location.hostname || target.pathname === '/' ||
            /^(search|vodsearch|tag|type|vodtype|play|vodplay|login|register)$/i.test((target.pathname.split('/')[1] || '').split(/[-.]/)[0])) continue;
        const heading = card.querySelector('h2,h3,h4,h5,.module-poster-item-title,.video_item-title,.title');
        const title = (a.getAttribute('title') || img.getAttribute('alt') || (heading && heading.textContent) || a.textContent || '').trim();
        let cover = img.getAttribute('data-original') || img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('src') || '';
        try { cover = new URL(cover, location.href).href; } catch (_) { continue; }
        if (!title || !/^https?:/i.test(cover) || /^(?:logo|广告|首页)$/i.test(title)) continue;
        seen.add(url); items.push({id:url, title, cover});
        if (items.length >= 120) break;
      }
      return items;
    }
    if (mode === 'search') {
      const seen = new Set();
      return nodes(rule.searchList).map(row => {
        const title = nodes(rule.searchName, row)[0];
        const url = href(nodes(rule.searchResult, row)[0]);
        const img = row.querySelector('img');
        let cover = img && (img.getAttribute('data-original') || img.getAttribute('data-src') || img.getAttribute('src'));
        try { cover = cover ? new URL(cover, location.href).href : ''; } catch (_) { cover = ''; }
        return {id: url, title: (title && title.textContent || '').trim(), cover};
      }).filter(item => item.id && item.title && !seen.has(item.id) && seen.add(item.id));
    }
    const chapters = [], seen = new Set();
    let roads = nodes(rule.chapterRoads);
    if (!roads.length) roads = [document];
    roads.forEach((road, index) => {
      for (const link of nodes(rule.chapterResult, road)) {
        const id = href(link), title = (link.textContent || '').trim();
        if (id && title && !seen.has(id)) { seen.add(id); chapters.push({id, title: (roads.length > 1 ? '线路' + (index+1) + ' · ' : '') + title}); }
      }
    });
    // Some rules deliberately use a document-level XPath for episode links.
    if (!chapters.length) for (const link of nodes(rule.chapterResult)) {
      const id = href(link), title = (link.textContent || '').trim();
      if (id && title && !seen.has(id)) { seen.add(id); chapters.push({id, title}); }
    }
    const meta = document.querySelector('meta[property="og:description"],meta[name="description"]');
    const image = document.querySelector('meta[property="og:image"]');
    return {id: location.href, title: document.title, description: meta ? meta.content : '', cover: image ? image.content : '', chapters};
  `;
}
function kazumiPath(document, path) {
  if (!path || path[0] !== '$') throw new Error('Kazumi JSONPath 必须以 $ 开头');
  let values = [document], at = 1;
  while (at < path.length) {
    const match = /^(?:\.([A-Za-z0-9_$-]+)|\[(\d+|\*|'[^']*'|"[^"]*")\])/.exec(path.slice(at));
    if (!match) throw new Error('Kazumi 不支持此 JSONPath：' + path);
    let key = match[1] == null ? match[2] : match[1];
    const wildcard = match[2] === '*';
    if (key[0] === "'" || key[0] === '"') key = key.slice(1, -1);
    const next = [];
    values.forEach(value => {
      if (wildcard && value && typeof value === 'object') Object.keys(value).forEach(k => next.push(value[k]));
      else if (value != null && Object.prototype.hasOwnProperty.call(Object(value), key)) next.push(value[key]);
    });
    values = next; at += match[0].length;
  }
  return values;
}
function kazumiFirst(document, path) { return path ? kazumiPath(document, path)[0] : null; }
function kazumiText(value) { return value == null ? '' : String(value).trim(); }
function kazumiTemplate(value, variables, encode) {
  return String(value).replace(/(^|[^A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)/g, (_, prefix, key) => {
    if (!Object.prototype.hasOwnProperty.call(variables, key)) throw new Error('Kazumi 缺少模板变量 @' + key);
    const text = variables[key] == null ? '' : String(variables[key]);
    return prefix + (encode ? encodeURIComponent(text) : text);
  });
}
function kazumiValue(value, variables) {
  if (typeof value === 'string') {
    const exact = /^@([A-Za-z_][A-Za-z0-9_]*)$/.exec(value);
    if (exact && Object.prototype.hasOwnProperty.call(variables, exact[1])) return variables[exact[1]];
    return kazumiTemplate(value, variables, false);
  }
  if (Array.isArray(value)) return value.map(v => kazumiValue(v, variables));
  if (value && typeof value === 'object') {
    const result = {};
    Object.keys(value).forEach(key => result[key] = kazumiValue(value[key], variables));
    return result;
  }
  return value;
}
function kazumiQuery(url, query, variables) {
  const parts = [];
  Object.keys(query || {}).forEach(key => parts.push(encodeURIComponent(kazumiTemplate(key, variables, false)) + '=' + encodeURIComponent(String(kazumiValue(query[key], variables)))));
  if (!parts.length) return url;
  const at = url.indexOf('#'), hash = at < 0 ? '' : url.slice(at);
  const base = at < 0 ? url : url.slice(0, at);
  return base + (base.indexOf('?') < 0 ? '?' : '&') + parts.join('&') + hash;
}
function kazumiAbsolute(value) {
  let url = kazumiText(value);
  if (!url) return '';
  if (/^https?:\/\//i.test(url)) return url;
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return '';
  const origin = /^https?:\/\/[^/]+/i.exec(kazumiRule.baseURL)[0];
  if (url.startsWith('//')) return origin.split(':')[0] + ':' + url;
  if (url[0] === '/') return origin + url;
  const base = kazumiRule.baseURL.split(/[?#]/)[0];
  return (base === origin ? base + '/' : base.slice(0, base.lastIndexOf('/') + 1)) + url;
}
async function kazumiApi(config, variables) {
  const request = config.request;
  const method = String(request.method || 'GET').toUpperCase();
  const url = kazumiQuery(kazumiTemplate(request.url, variables, true), request.query, variables);
  const headers = Object.assign(kazumiHeaders(kazumiRule.baseURL), kazumiValue(request.headers || {}, variables));
  let body;
  if (method === 'POST' && request.bodyType === 'json') {
    body = JSON.stringify(kazumiValue(request.body, variables));
    if (!Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
  } else if (method === 'POST' && request.bodyType === 'form') {
    body = kazumiQuery('', request.body || {}, variables).slice(1);
    if (!Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  const response = await LumeSource.http.request({url, method, headers, body});
  if (response.status < 200 || response.status >= 300) throw new Error('Kazumi API HTTP ' + response.status);
  try { return JSON.parse(response.body); } catch (_) { throw new Error('Kazumi API 响应不是有效 JSON'); }
}
const kazumiItems = {};
async function kazumiApiSearch(p) {
  const config = kazumiRule.searchApiConfig;
  const document = await kazumiApi(config, {keyword:p.keyword || '', page:p.page || 1});
  const seen = new Set(), items = [];
  kazumiPath(document, config.listPath).forEach(row => {
    const title = kazumiText(kazumiFirst(row, config.namePath));
    const source = kazumiText(kazumiFirst(row, config.sourcePath));
    let id = config.sourceTemplate ? config.sourceTemplate.replace(/@source/g, encodeURIComponent(source)) : source;
    if (kazumiRule.chapterMode !== 'api') id = kazumiAbsolute(id);
    if (!title || !source || !id || seen.has(id)) return;
    seen.add(id);
    const item = {id, title}; items.push(item); kazumiItems[id] = item;
  });
  while (Object.keys(kazumiItems).length > 200) delete kazumiItems[Object.keys(kazumiItems)[0]];
  return {items, hasMore:false};
}
async function kazumiApiDetail(id) {
  const config = kazumiRule.chapterApiConfig;
  const document = await kazumiApi(config, {source:id});
  const variables = {source:id}, chapters = [], seen = new Set();
  Object.keys(config.variables || {}).forEach(key => {
    const value = kazumiFirst(document, config.variables[key]);
    if (value == null) throw new Error('Kazumi 章节响应变量未匹配：' + key);
    variables[key] = value;
  });
  function append(rawUrl, title, road, roadIndex, episodeIndex) {
    let url = kazumiText(rawUrl);
    if (config.episodePage) {
      const vars = Object.assign({}, variables, {episodeUrl:url, roadIndex, roadNumber:roadIndex+1, episodeIndex, episodeNumber:episodeIndex+1});
      url = kazumiQuery(kazumiTemplate(config.episodePage.url, vars, true), config.episodePage.query, vars);
    }
    url = kazumiAbsolute(url);
    if (!url || seen.has(url)) return;
    seen.add(url);
    chapters.push({id:url, title:(road ? road + ' · ' : '') + (kazumiText(title) || '第' + (episodeIndex+1) + '集')});
  }
  if (config.format === 'delimited') {
    const roadSeparator = config.roadSeparator || '$$$';
    const roadNames = kazumiText(kazumiFirst(document, config.roadNamesPath)).split(roadSeparator);
    const groups = kazumiText(kazumiFirst(document, config.roadEpisodesPath)).split(roadSeparator);
    groups.forEach((group, r) => group.split(config.episodeSeparator || '#').forEach((entry, e) => {
      const separator = config.fieldSeparator || '$', at = entry.indexOf(separator);
      if (at >= 0) append(entry.slice(at+separator.length), entry.slice(0,at), groups.length > 1 ? roadNames[r] || '线路'+(r+1) : '', r, e);
    }));
  } else {
    const roads = config.roadsPath ? kazumiPath(document, config.roadsPath) : [document];
    roads.forEach((road, r) => kazumiPath(road, config.episodesPath).forEach((episode, e) => {
      append(kazumiFirst(episode, config.episodeUrlPath), kazumiFirst(episode, config.episodeNamePath), roads.length > 1 ? kazumiText(kazumiFirst(road,config.roadNamePath)) || '线路'+(r+1) : '', r, e);
    }));
  }
  return Object.assign({id, title:id}, kazumiItems[id] || {}, {chapters});
}
LumeSource = {
  categories: async () => [],
  list: async p => {
    if (p.keyword) return LumeSource.search(p);
    if ((p.page || 1) > 1) return {items: [], hasMore: false};
    const response = await kazumiPage(kazumiRule.baseURL, kazumiExtract('home'));
    return {items: Array.isArray(response.result) ? response.result : [], hasMore: false};
  },
  search: async p => {
    if ((p.page || 1) > 1) return {items: [], hasMore: false};
    if (kazumiRule.searchMode === 'api') return kazumiApiSearch(p);
    let url = kazumiRule.searchURL.replace(/@keyword/g, encodeURIComponent(p.keyword || ''));
    let form;
    if (kazumiRule.usePost) { const at = url.indexOf('?'); form = at < 0 ? '' : url.slice(at + 1); url = at < 0 ? url : url.slice(0, at); }
    const response = await kazumiPage(url, kazumiExtract('search'), form);
    return {items: response.result || [], hasMore: false};
  },
  detail: async p => kazumiRule.chapterMode === 'api' ? kazumiApiDetail(p.id) : (await kazumiPage(p.id, kazumiExtract('detail'))).result,
  chapters: async p => kazumiRule.chapterMode === 'api' ? (await kazumiApiDetail(p.id)).chapters : ((await kazumiPage(p.id, kazumiExtract('detail'))).result || {}).chapters || [],
  content: async p => {
    const page = p.chapterId || p.id;
    if (/\.(m3u8|mp4|mpd|flv)([?#]|$)/i.test(page) && kazumiRule.useNativePlayer !== false) return {kind:'video', url:page, headers:kazumiHeaders(kazumiRule.baseURL)};
    const response = await kazumiPage(page, 'return null;');
    const media = (response.media || []).find(item => /\.(m3u8|mp4|mpd|flv)([?#]|$)/i.test(item.url));
    if (media && kazumiRule.useNativePlayer !== false) return {kind: 'video', url: media.url, headers: Object.assign({}, media.headers || {}, kazumiHeaders(page))};
    return {kind: 'webplayer', pageUrl: page, headers: kazumiHeaders(page)};
  }
};
''';
}
