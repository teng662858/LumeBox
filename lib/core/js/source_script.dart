import 'dart:convert';

/// 去掉脚本文本开头的 UTF-8 BOM（`\uFEFF`）。
///
/// 脚本从文件或订阅链接读进来时常带 BOM：它会让锚定行首的头部元信息正则
/// 失配（合法脚本被误报「缺少元信息」），也会被原样交给 JS 引擎。因此
/// 文本进入解析、落库与执行之前一律先剥离 BOM。
String stripScriptBom(String script) {
  var text = script;
  while (text.startsWith(_bom)) {
    text = text.substring(_bom.length);
  }
  return text;
}

/// UTF-8 BOM 解码成 Dart 字符串后剩下的字符（ZERO WIDTH NO-BREAK SPACE）。
const String _bom = '\uFEFF';

/// 图源脚本声明的元信息。
///
/// 两个来源，按此顺序解析：
/// 1. 脚本头部的声明注释 `// LumeSource: {"id":"…","name":"…","version":"…"}`；
/// 2. 脚本全局 `LumeSource` 的 id / name / version 字段（JS 契约 v2）。
class SourceMetadata {
  const SourceMetadata({
    required this.id,
    required this.name,
    required this.version,
  });

  final String id;
  final String name;
  final String version;

  /// 头部声明注释的匹配式：`//` 行注释与 `/* */` 块注释，分隔符 `:` / `=`，
  /// 前缀允许 `@`。第三个式子是 `key=value` 列表写法（`{` 开头的不走这条）。
  static final List<RegExp> _headerPatterns = <RegExp>[
    RegExp(
      r'^[ \t]*//[ \t]*@?LumeSource\b[ \t]*[:=]?[ \t]*(\{[^\r\n]*\})',
      multiLine: true,
    ),
    RegExp(r'/\*[ \t]*@?LumeSource\b[ \t]*[:=]?[ \t]*(\{[\s\S]*?\})[ \t]*\*/'),
    RegExp(
      r'^[ \t]*//[ \t]*@?LumeSource\b[ \t]*[:=]?[ \t]*(.+?)[ \t]*$',
      multiLine: true,
    ),
  ];

  /// 解析脚本头部的元信息注释；没有声明或声明不合法时返回 null。
  ///
  /// 先剔 BOM（[stripScriptBom]）再匹配，带 BOM 的脚本因此不会被误判成
  /// 「缺少元信息」。匹配不到就交给 [parse] 去读运行时的 `LumeSource`。
  static SourceMetadata? parseHeader(String script) {
    final text = stripScriptBom(script);
    for (final pattern in _headerPatterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final metadata = _parseHeaderBody(match.group(1)!);
      if (metadata != null) return metadata;
    }
    return null;
  }

  static SourceMetadata? _parseHeaderBody(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      try {
        return parse(jsonDecode(trimmed));
      } catch (_) {
        return null;
      }
    }
    return parse(_parseKeyValues(trimmed));
  }

  /// `id=lume-example, name=示例源, version=1.0.0` 这类列表写法。
  static Map<String, Object?>? _parseKeyValues(String text) {
    final values = <String, Object?>{};
    for (final pair in text.split(RegExp(r'[,;]'))) {
      final match =
          RegExp(r'^\s*(id|name|version)\s*[:=]\s*(.+?)\s*$').firstMatch(pair);
      if (match == null) continue;
      values[match.group(1)!] = match.group(2)!;
    }
    return values.isEmpty ? null : values;
  }

  static SourceMetadata? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    final name = '${json['name'] ?? ''}'.trim();
    if (id.isEmpty || name.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id)) return null;
    return SourceMetadata(
      id: id,
      name: name,
      version: '${json['version'] ?? ''}'.trim(),
    );
  }

  String toJson() => jsonEncode(<String, Object?>{
        'id': id,
        'name': name,
        'version': version,
      });
}
