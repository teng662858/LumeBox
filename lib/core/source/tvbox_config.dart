import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../js/source_script.dart';

enum TvBoxKind { cms, python, live, unsupported }

class TvBoxEntry {
  const TvBoxEntry({
    required this.id,
    required this.name,
    required this.kind,
    this.api = '',
    this.type = 1,
    this.ext = '',
    this.headers = const {},
    this.groups = const [],
    this.reason = '',
  });
  final String id, name, api, reason;
  final TvBoxKind kind;
  final int type;
  final Object? ext;
  final Map<String, String> headers;
  final List<Map<String, dynamic>> groups;
  bool get supported => kind != TvBoxKind.unsupported;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'api': api,
    'type': type,
    'ext': ext,
    'headers': headers,
    'groups': groups,
  };
  factory TvBoxEntry.fromJson(Map value) => TvBoxEntry(
    id: '${value['id']}',
    name: '${value['name']}',
    kind: TvBoxKind.values.byName('${value['kind']}'),
    api: '${value['api'] ?? ''}',
    type: int.tryParse('${value['type']}') ?? 1,
    ext: value['ext'],
    headers: (value['headers'] as Map? ?? {}).map(
      (k, v) => MapEntry('$k', '$v'),
    ),
    groups: (value['groups'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );
  Map<String, Object?> get metadata => {
    'id': id,
    'name': name,
    'version': '1.0.0',
    'category': 'video',
  };
  String get script =>
      '// LumeSource: ${jsonEncode(metadata)}\n// LumeTVBox: ${jsonEncode(toJson())}\n';

  /// Keep original bytes (including PEP263 encodings), identity and init extend.
  String pythonScript(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('Python 文件为空或超过 4MB');
    }
    return '# LumeRuntime: python\n# LumeSource: ${jsonEncode({...metadata, 'version': sha256.convert(bytes).toString().substring(0, 12)})}\n'
        '# LumeTVBox: ${jsonEncode(toJson())}\n# LumeTVBoxExtend: ${jsonEncode(ext ?? '')}\n'
        '# LumePythonBytes: ${base64Encode(bytes)}';
  }

  static TvBoxEntry? fromScript(String script) {
    final match = RegExp(
      r'^\s*(?://|#) LumeTVBox: (\{[^\r\n]+\})',
      multiLine: true,
    ).firstMatch(script);
    if (match == null) return null;
    try {
      return TvBoxEntry.fromJson(jsonDecode(match[1]!) as Map);
    } catch (_) {
      throw const FormatException('TVBox 源描述无效，请重新导入配置');
    }
  }
}

class TvBoxConfig {
  const TvBoxConfig(this.entries, this.notes);
  final List<TvBoxEntry> entries;
  final List<String> notes;
  static const maxEntries = 2000;

  static bool isHttp(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static String resolve(String value, String origin) {
    if (value.trim().isEmpty) return '';
    if (isHttp(value)) return value;
    if (origin.isNotEmpty && isHttp(origin)) {
      final result = Uri.parse(origin).resolve(value).toString();
      if (isHttp(result)) return result;
    }
    return '';
  }

  static TvBoxConfig parse(String text, {String origin = ''}) {
    if (utf8.encode(text).length > 4 * 1024 * 1024) {
      throw const FormatException('配置文件超过 4MB');
    }
    final value = jsonDecode(stripScriptBom(text));
    if (value is! Map || (value['sites'] is! List && value['lives'] is! List)) {
      throw const FormatException('请选择包含 sites 或 lives 的 TVBox 聚合 JSON');
    }
    final rows = <TvBoxEntry>[];
    final ids = <String>{};
    final notes = <String>[];
    final sites = value['sites'] as List? ?? [];
    final lives = value['lives'] as List? ?? [];
    if (sites.length + lives.length > maxEntries) {
      throw const FormatException('配置条目超过 2000 项');
    }
    String identity(String key, String api, String kind) =>
        'tvbox_${sha256.convert(utf8.encode('$kind|$key|$api')).toString().substring(0, 24)}';
    Map<String, String> headers(Map row) {
      final result = <String, String>{};
      for (final entry
          in (row['header'] is Map ? row['header'] as Map : const {}).entries) {
        if (!RegExp(r'[\r\n]').hasMatch('${entry.key}${entry.value}')) {
          result['${entry.key}'] = '${entry.value}';
        }
      }
      if ('${row['ua'] ?? ''}'.isNotEmpty) {
        result['User-Agent'] = '${row['ua']}';
      }
      return result;
    }

    void add(TvBoxEntry entry) {
      if (!ids.add(entry.id)) {
        notes.add('已跳过重复条目：${entry.name}');
        return;
      }
      rows.add(entry);
    }

    for (var i = 0; i < sites.length; i++) {
      final raw = sites[i];
      if (raw is! Map) {
        add(
          TvBoxEntry(
            id: 'invalid_site_$i',
            name: '站点 ${i + 1}',
            kind: TvBoxKind.unsupported,
            reason: '条目不是对象',
          ),
        );
        continue;
      }
      final key = '${raw['key'] ?? raw['name'] ?? i}';
      final name = '${raw['name'] ?? key}';
      final api = '${raw['api'] ?? ''}'.trim();
      final type = int.tryParse('${raw['type']}') ?? -1;
      final resolved = api.startsWith('csp_') ? '' : resolve(api, origin);
      var kind = TvBoxKind.unsupported;
      var reason = '不支持此站点类型（type=$type）';
      if (api.startsWith('csp_') || api.toLowerCase().endsWith('.jar')) {
        reason = '依赖 JAR/CSP 插件，iOS 不执行 Android Java 插件';
      } else if (resolved.isEmpty) {
        reason = '接口不是有效 HTTP(S) 地址；本地相对路径需要在线配置地址';
      } else if (type == 3 &&
          (Uri.parse(resolved).path.toLowerCase().endsWith('.py') ||
              resolved.toLowerCase().endsWith('.py'))) {
        kind = TvBoxKind.python;
        reason = '';
      } else if (type == 0 || type == 1) {
        kind = TvBoxKind.cms;
        reason = '';
      }
      add(
        TvBoxEntry(
          id: identity(key, resolved.isEmpty ? api : resolved, kind.name),
          name: name,
          kind: kind,
          api: resolved,
          type: type,
          ext: raw['ext'] ?? '',
          headers: headers(raw),
          reason: reason,
        ),
      );
    }
    final inline = <Map<String, dynamic>>[];
    for (var i = 0; i < lives.length; i++) {
      final raw = lives[i];
      if (raw is! Map) {
        add(
          TvBoxEntry(
            id: 'invalid_live_$i',
            name: '直播列表 ${i + 1}',
            kind: TvBoxKind.unsupported,
            reason: '条目不是对象',
          ),
        );
        continue;
      }
      if (raw['channels'] is List) {
        inline.add(Map<String, dynamic>.from(raw));
        continue;
      }
      final name = '${raw['name'] ?? '直播列表 ${i + 1}'}';
      var api = '${raw['url'] ?? ''}'.trim();
      if (api.startsWith('proxy://')) {
        try {
          final encoded = Uri.parse(api).queryParameters['ext'] ?? '';
          api = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
        } catch (_) {
          api = '';
        }
      }
      api = resolve(api, origin);
      add(
        TvBoxEntry(
          id: identity(name, api, 'live'),
          name: name,
          kind: api.isEmpty ? TvBoxKind.unsupported : TvBoxKind.live,
          api: api,
          headers: headers(raw),
          reason: api.isEmpty ? '直播列表地址无效或代理格式不受支持' : '',
        ),
      );
    }
    if (inline.isNotEmpty) {
      add(
        TvBoxEntry(
          id: identity(
            'inline',
            origin.isEmpty ? jsonEncode(inline) : origin,
            'live',
          ),
          name: '直播频道',
          kind: TvBoxKind.live,
          groups: inline,
        ),
      );
    }
    for (final key in [
      'spider',
      'parses',
      'rules',
      'doh',
      'hosts',
      'flags',
      'ijk',
      'ads',
    ]) {
      final field = value[key];
      if (field != null && '$field' != '[]' && '$field'.isNotEmpty) {
        notes.add('$key：保留 App 自身网络、解析与播放器设置，不执行 TVBox 专属配置');
      }
    }
    return TvBoxConfig(rows, notes);
  }
}
