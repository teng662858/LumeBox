import 'dart:convert';


/// 图源可视化编辑器的表单模型：把「脚本」与「表单」双向转换。
///
/// 设计取舍：**不试图解析任意脚本**（那需要完整的 JS 解析器，且图源写法千奇百怪）。
/// 这里只做一件事——生成一份**规范的函数式图源脚本**（本项目的桥接对象支持
/// `getList` / `getDetail` / `getChapters` / `getContent` 这套顶层函数写法）。
///
/// 因此编辑器定位是「**新建图源的脚手架**」：
/// - 用户填标题 / 接口地址 / 选择器或 JSON 字段路径，得到一份能跑的脚本；
/// - 生成后仍可在脚本编辑框里继续手改（表单是起点，不是牢笼）；
/// - 反向解析只认「本编辑器生成的脚本」（带 `@lume-form` 标记），不猜别的写法。
///
/// 与文档「图源可视化编辑器」的对应：文档要求「UI 表单 + 高级 JSON 模式切换」，
/// 这里表单模式生成脚本，高级模式就是直接编辑生成的脚本原文。
class SourceFormDraft {
  const SourceFormDraft({
    this.id = '',
    this.name = '',
    this.version = '1.0.0',
    this.baseUrl = '',
    this.listPath = '/list',
    this.detailPath = '/detail',
    this.searchKeywordParam = 'wd',
    this.pageParam = 'page',
    this.jsonListField = '',
    this.jsonTitleField = 'title',
    this.jsonIdField = 'id',
    this.jsonCoverField = 'cover',
    this.listTemplate = SourceListTemplate.json,
    this.headers = '',
  });

  /// 图源 id（字母数字与 `-` `_`；文档口径）。
  final String id;

  /// 显示名。
  final String name;

  final String version;

  /// 站点根地址（生成脚本里的 base）。
  final String baseUrl;

  /// 列表接口路径。
  final String listPath;

  /// 详情接口路径。
  final String detailPath;

  /// 搜索关键词参数名。
  final String searchKeywordParam;

  /// 页码参数名。
  final String pageParam;

  /// JSON 模式下列表所在字段（空表示响应本身是数组）。
  final String jsonListField;

  final String jsonTitleField;
  final String jsonIdField;
  final String jsonCoverField;

  /// 列表来源形态。
  final SourceListTemplate listTemplate;

  /// 附加请求头（每行 `Name: Value`）。
  final String headers;

  /// 表单标记：生成脚本里带上它，才能被 [parse] 反解回表单。
  static const String marker = '@lume-form';

  /// 校验：返回 null 表示合法，否则给出可读原因。
  String? validate() {
    if (id.trim().isEmpty) return '请填写源 id';
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id.trim())) {
      return 'id 只允许英文字母、数字、短横「-」、下划线「_」';
    }
    if (name.trim().isEmpty) return '请填写源名称';
    if (baseUrl.trim().isEmpty) return '请填写站点地址';
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme) return '站点地址要以 http:// 或 https:// 开头';
    if (listTemplate == SourceListTemplate.json && jsonTitleField.trim().isEmpty) {
      return '请填写标题字段名（用于从响应里取标题）';
    }
    return null;
  }

  SourceFormDraft copyWith({
    String? id,
    String? name,
    String? version,
    String? baseUrl,
    String? listPath,
    String? detailPath,
    String? searchKeywordParam,
    String? pageParam,
    String? jsonListField,
    String? jsonTitleField,
    String? jsonIdField,
    String? jsonCoverField,
    SourceListTemplate? listTemplate,
    String? headers,
  }) {
    return SourceFormDraft(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      baseUrl: baseUrl ?? this.baseUrl,
      listPath: listPath ?? this.listPath,
      detailPath: detailPath ?? this.detailPath,
      searchKeywordParam: searchKeywordParam ?? this.searchKeywordParam,
      pageParam: pageParam ?? this.pageParam,
      jsonListField: jsonListField ?? this.jsonListField,
      jsonTitleField: jsonTitleField ?? this.jsonTitleField,
      jsonIdField: jsonIdField ?? this.jsonIdField,
      jsonCoverField: jsonCoverField ?? this.jsonCoverField,
      listTemplate: listTemplate ?? this.listTemplate,
      headers: headers ?? this.headers,
    );
  }

  /// 生成脚本。
  ///
  /// 产出的是**函数式图源脚本**（顶层 `getList` 等），因为这是最不需要样板代码的
  /// 写法；头部带元信息注释与表单标记（供反解）。
  String buildScript() {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final headerMap = _parseHeaders(headers);
    final headerJson = headerMap.isEmpty ? '{}' : jsonEncode(headerMap);

    return '''
// LumeSource: ${jsonEncode(<String, String>{'id': id.trim(), 'name': name.trim(), 'version': version.trim()})}
// $marker ${jsonEncode(_formJson())}
//
// 由 Lume Box 图源编辑器生成（函数式契约）：
//   getList(page) / getSearch(keyword, page) / getDetail(id) / getChapters(id) / getContent(id, chapterId)
// 生成后可直接在本文件里继续修改；改完保存即可导入。

var BASE = '${_escape(base)}';
var HEADERS = $headerJson;

function url(path, params) {
  var target = BASE + path;
  var query = [];
  for (var key in (params || {})) {
    var value = params[key];
    if (value === undefined || value === null || value === '') continue;
    query.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
  }
  return query.length ? target + '?' + query.join('&') : target;
}

async function fetchJson(target) {
  var reply = await fetch(target, { headers: HEADERS });
  var text = await reply.text();
  try { return JSON.parse(text); } catch (error) {
    throw new Error('响应不是 JSON：' + text.slice(0, 120));
  }
}
${_buildListFunction()}
async function getDetail(id) {
  var data = await fetchJson(url('${_escape(detailPath.trim())}', { id: id }));
  var item = ${_extractExpression('data')};
  return {
    id: String(item.${_field(jsonIdField)} || id),
    title: String(item.${_field(jsonTitleField)} || ''),
    cover: item.${_field(jsonCoverField)} ? String(item.${_field(jsonCoverField)}) : null,
    description: item.desc || item.description || null
  };
}

async function getChapters(id) {
  var data = await fetchJson(url('${_escape(detailPath.trim())}', { id: id }));
  var list = data.chapters || data.list || data.episodes || [];
  return list.map(function (item, index) {
    return { id: String(item.id || index), title: String(item.title || item.name || ('第 ' + (index + 1) + ' 集')) };
  });
}

async function getContent(id, chapterId) {
  var data = await fetchJson(url('${_escape(detailPath.trim())}', { id: id, chapterId: chapterId }));
  var playUrl = data.url || data.playUrl || data.video || '';
  if (!playUrl) throw new Error('详情里没有找到播放地址字段（url / playUrl / video）');
  return { kind: 'video', url: String(playUrl) };
}
''';
  }

  /// 列表函数：按形态生成（JSON 字段 / 直接数组 / HTML 正则）。
  String _buildListFunction() {
    final listField = jsonListField.trim();
    final pick = switch (listTemplate) {
      SourceListTemplate.json => listField.isEmpty
          ? 'var list = Array.isArray(data) ? data : (data.list || data.items || []);'
          : 'var list = data${_pathAccess(listField)} || [];',
      SourceListTemplate.html => '''var html = await (await fetch(url('${_escape(listPath.trim())}', { page: page, wd: keyword }), { headers: HEADERS })).text();
  var list = [];
  var pattern = /<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\\/a>/g;
  var match;
  while ((match = pattern.exec(html)) !== null) {
    list.push({ id: match[1], title: match[2].trim() });
  }''',
    };
    final body = listTemplate == SourceListTemplate.html
        ? pick
        : '''var data = await fetchJson(url('${_escape(listPath.trim())}', { page: page, wd: keyword }));
  $pick''';

    return '''
async function getList(page) {
  page = page || 1;
  $body
  return {
    list: list.map(function (item) {
      return {
        id: String(item.${_field(jsonIdField)} || item.url || item.link || ''),
        title: String(item.${_field(jsonTitleField)} || item.name || ''),
        cover: item.${_field(jsonCoverField)} ? String(item.${_field(jsonCoverField)}) : null
      };
    }),
    hasMore: list.length > 0
  };
}

async function getSearch(keyword, page) {
  page = page || 1;
  var data = await fetchJson(url('${_escape(listPath.trim())}', { '${_escape(searchKeywordParam.trim())}': keyword, '${_escape(pageParam.trim())}': page }));
  ${listTemplate == SourceListTemplate.html ? 'var list = [];' : _listExtract()}
  return {
    list: list.map(function (item) {
      return {
        id: String(item.${_field(jsonIdField)} || ''),
        title: String(item.${_field(jsonTitleField)} || item.name || '')
      };
    })
  };
}
''';
  }

  String _listExtract() {
    final listField = jsonListField.trim();
    if (listField.isEmpty) {
      return 'var list = Array.isArray(data) ? data : (data.list || data.items || []);';
    }
    return 'var list = data${_pathAccess(listField)} || [];';
  }

  /// 生成「从响应里取条目」的表达式（JSON 模式支持点路径）。
  String _extractExpression(String root) {
    final field = jsonListField.trim();
    if (field.isEmpty) return '$root.data || $root';
    return '$root${_pathAccess(field)} || $root';
  }

  /// `a.b.c` → `.a.b.c`（表单里允许点路径）。
  static String _pathAccess(String path) {
    final parts = path
        .split('.')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);
    return parts.map((part) => '.$part').join();
  }

  /// 字段名 → 安全的属性访问写法（非法标识符用方括号）。
  static String _field(String name) {
    final value = name.trim();
    if (value.isEmpty) return 'title';
    if (RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(value)) return value;
    return "['${_escape(value)}']";
  }

  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n');

  /// `Name: Value` 每行一条 → 头表。
  static Map<String, String> _parseHeaders(String raw) {
    final result = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.contains(':')) continue;
      final index = trimmed.indexOf(':');
      final name = trimmed.substring(0, index).trim();
      final value = trimmed.substring(index + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      result[name] = value;
    }
    return result;
  }

  Map<String, Object?> _formJson() => <String, Object?>{
        'id': id.trim(),
        'name': name.trim(),
        'version': version.trim(),
        'baseUrl': baseUrl.trim(),
        'listPath': listPath.trim(),
        'detailPath': detailPath.trim(),
        'searchKeywordParam': searchKeywordParam.trim(),
        'pageParam': pageParam.trim(),
        'jsonListField': jsonListField.trim(),
        'jsonTitleField': jsonTitleField.trim(),
        'jsonIdField': jsonIdField.trim(),
        'jsonCoverField': jsonCoverField.trim(),
        'listTemplate': listTemplate.id,
        'headers': headers,
      };

  /// 反解：只认带表单标记的脚本（本编辑器生成的）。
  ///
  /// 解析不出来（用户手改过、或不是本编辑器生成的）返回 null——此时编辑器
  /// 退回「高级模式」只编辑脚本文本，不假装能还原表单。
  static SourceFormDraft? parse(String script) {
    final pattern = RegExp('//\\s*$marker\\s*(\\{.*\\})');
    final match = pattern.firstMatch(script);
    if (match == null) return null;
    try {
      final json = jsonDecode(match.group(1)!);
      if (json is! Map) return null;
      return SourceFormDraft(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        version: '${json['version'] ?? '1.0.0'}',
        baseUrl: '${json['baseUrl'] ?? ''}',
        listPath: '${json['listPath'] ?? ''}',
        detailPath: '${json['detailPath'] ?? ''}',
        searchKeywordParam: '${json['searchKeywordParam'] ?? 'wd'}',
        pageParam: '${json['pageParam'] ?? 'page'}',
        jsonListField: '${json['jsonListField'] ?? ''}',
        jsonTitleField: '${json['jsonTitleField'] ?? 'title'}',
        jsonIdField: '${json['jsonIdField'] ?? 'id'}',
        jsonCoverField: '${json['jsonCoverField'] ?? 'cover'}',
        listTemplate: SourceListTemplate.fromId('${json['listTemplate'] ?? ''}'),
        headers: '${json['headers'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SourceFormDraft && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 列表来源形态。
enum SourceListTemplate {
  /// JSON 接口（默认）。
  json('json', 'JSON 接口'),

  /// HTML 页面（用正则抓链接）。
  html('html', 'HTML 页面');

  const SourceListTemplate(this.id, this.label);

  final String id;
  final String label;

  static SourceListTemplate fromId(String id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    return SourceListTemplate.json;
  }
}

/// 编辑器草稿的持久化（暂存，避免误退出丢内容）。
///
/// 存本板块阅读库（`reading_setting` 表）：草稿是「正在编辑的内容」，
/// 与图源库的正式记录分开——没点保存就不该进图源列表。
class SourceDraftStore {
  const SourceDraftStore(this._library);

  static const String keyPrefix = 'source.draft.';

  final dynamic _library;

  static String keyFor(String sectionId) => '$keyPrefix$sectionId';

  /// 读草稿脚本原文；没有草稿返回 null。
  String? loadScript(String sectionId) {
    final raw = _library.setting(keyFor(sectionId)) as String?;
    return (raw == null || raw.trim().isEmpty) ? null : raw;
  }

  void saveScript(String sectionId, String script) {
    _library.setSetting(keyFor(sectionId), script);
  }

  void clear(String sectionId) {
    _library.setSetting(keyFor(sectionId), '');
  }
}
