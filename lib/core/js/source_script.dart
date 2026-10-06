import 'dart:convert';

import '../session/section.dart';

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
///
/// 函数式脚本（只写顶层 `getList(page)` 这类函数，见 `LumeSourceBridgePolyfill`）
/// 没有可供读取的对象字段，**必须**用头部注释声明 id / name。
class SourceMetadata {
  const SourceMetadata({
    required this.id,
    required this.name,
    required this.version,
    this.category = '',
  });

  final String id;
  final String name;
  final String version;

  /// 脚本自报的归属板块（**可选**）。声明方式与 id / name 一致：头部注释里的
  /// `category` 字段，或运行时 `LumeSource.category`。
  ///
  /// 空串表示脚本没有自报板块——此时归属完全由导入入口决定，既有脚本不受影响。
  /// 一旦自报，就必须与导入目标板块一致，否则在解析阶段被拒绝（见
  /// [sectionMismatch]）：跨板块混用图源是被严格禁止的。
  final String category;

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

  /// id 的字符白名单：**英文字母、数字、短横「-」、下划线「_」**。
  ///
  /// 刻意不收长破折号（—）、全角符号与其他易混淆字符：它们在脚本里肉眼几乎
  /// 看不出区别，却会让 id 静默失效（图源更新覆盖不生效、当前源选择失配）。
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// id 长度上限。
  static const int maxIdLength = 64;

  /// 校验 id：合法返回 null，否则返回可读原因（点名是哪个字符不合规）。
  static String? idIssue(String? id) {
    final value = (id ?? '').trim();
    if (value.isEmpty) return 'id 为空';
    if (value.length > maxIdLength) return 'id 超过 $maxIdLength 个字符';
    if (_idPattern.hasMatch(value)) return null;
    final illegal = _firstIllegalChar(value);
    if (illegal == null) return 'id 含不允许的字符';
    final code =
        illegal.runes.first.toRadixString(16).toUpperCase().padLeft(4, '0');
    return 'id 含不允许的字符「$illegal」（U+$code）';
  }

  /// 头部注释里声明的原始 id（不做合法性判断，只用于失败诊断点名问题在哪）。
  static String? headerIdOf(String script) {
    final text = stripScriptBom(script);
    for (final pattern in _headerPatterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final body = match.group(1)!.trim();
      if (body.startsWith('{')) {
        try {
          final json = jsonDecode(body);
          if (json is Map && json['id'] != null) return '${json['id']}';
        } catch (_) {
          // JSON 解不开：落回下面的 key=value 形态。
        }
      }
      final value = _parseKeyValues(body)?['id'];
      if (value != null) return '$value';
    }
    return null;
  }

  /// 导入失败时的可读原因：区分「没有元信息」与「id 字符合法性不过」。
  ///
  /// [runtimeMetadata] 是引擎读到的运行时 `LumeSource` 原始值；给了 [script]
  /// 时连头部注释里声明的 id 一起诊断——用户最可能改的就是那一行。
  static String describeImportFailure(
    Object? runtimeMetadata, {
    String? script,
  }) {
    final runtimeId =
        runtimeMetadata is Map ? '${runtimeMetadata['id'] ?? ''}' : '';
    final candidates = <String>[
      runtimeId.trim(),
      if (script != null) (headerIdOf(script) ?? '').trim(),
    ];
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      final issue = idIssue(candidate);
      if (issue == null) continue;
      return '源 id 不合法：「$candidate」$issue。'
          'id 只允许英文字母、数字、短横「-」、下划线「_」；'
          '请检查脚本头部的「// LumeSource」元信息，长破折号与全角符号都会被拒绝。';
    }
    return '脚本缺少 LumeSource 元信息（id / name）：'
        '请在脚本头部写一行「// LumeSource: {"id":"…","name":"…"}」，'
        '或补齐运行时 LumeSource 的 id / name。'
        'id 只允许英文字母、数字、短横「-」、下划线「_」（长破折号、全角符号都会被拒绝）。';
  }

  /// 找出第一个不在白名单里的字符（提示里点名它，用户才知道改哪里）。
  static String? _firstIllegalChar(String value) {
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (RegExp(r'[A-Za-z0-9_-]').hasMatch(char)) continue;
      return char;
    }
    return null;
  }

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

  /// `id=lume-example, name=示例源, version=1.0.0, category=novel` 这类列表写法。
  static Map<String, Object?>? _parseKeyValues(String text) {
    final values = <String, Object?>{};
    for (final pair in text.split(RegExp(r'[,;]'))) {
      final match = RegExp(r'^\s*(id|name|version|category)\s*[:=]\s*(.+?)\s*$')
          .firstMatch(pair);
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
    if (!_idPattern.hasMatch(id)) return null;
    return SourceMetadata(
      id: id,
      name: name,
      version: '${json['version'] ?? ''}'.trim(),
      category: '${json['category'] ?? ''}'.trim(),
    );
  }

  /// 合并两处元信息：头部声明优先，运行时补齐头部没写的字段。
  ///
  /// 为什么需要合并：`category` 允许只写在运行时 `LumeSource.category` 上，
  /// 而头部注释通常只声明 id / name / version。若直接「头部命中就整体采用」，
  /// 头部里没写 category 的脚本会绕过板块校验——脚本自报的板块必须无论写在
  /// 哪一处都被看见。
  static SourceMetadata? merge(SourceMetadata? header, SourceMetadata? runtime) {
    if (header == null) return runtime;
    if (runtime == null) return header;
    return SourceMetadata(
      id: header.id,
      name: header.name,
      version: header.version.isEmpty ? runtime.version : header.version,
      category: header.category.isEmpty ? runtime.category : header.category,
    );
  }

  /// 校验脚本自报的板块与导入目标是否一致。
  ///
  /// 一致（或脚本没自报板块）返回 null；不一致返回可读原因，调用方据此在
  /// **解析阶段**拒绝加载——跨板块混用图源必须被严格拦下，而不是等运行期
  /// 才因为契约不符而莫名其妙地失败。
  ///
  /// 比对用板块的稳定标识（[Section.id]）：`novel` / `comic` / `video` / `cat`。
  /// 中文展示名（[Section.label]）也接受——脚本作者写「小说」比写 `novel` 更自然，
  /// 两者指向同一个板块，不该因此被误判成跨板块。
  String? sectionMismatch(Section target) {
    final declared = category.trim();
    if (declared.isEmpty) return null;
    final normalized = _normalizeSection(declared);
    if (normalized == target.id) return null;
    if (normalized == null) {
      return '源声明的板块「$declared」不是有效板块：'
          '只能是 ${_sectionNames()}（或对应中文名）。'
          '请检查脚本头部的「// LumeSource」元信息或运行时 LumeSource.category。';
    }
    final label = _labelOf(normalized) ?? normalized;
    return '跨板块源被拒绝：脚本声明归属「$label」（$normalized），'
        '当前导入目标是「${target.label}」（${target.id}）。'
        '一个板块只能使用本板块的源，请把脚本导入「$label」板块，'
        '或改正脚本里声明的 category。';
  }

  /// 把脚本声明的板块文本归一成 [Section.id]；无法识别返回 null。
  ///
  /// 大小写与空白不敏感：`Novel`、` novel ` 都认。中文展示名同样认。
  static String? _normalizeSection(String declared) {
    final value = declared.trim().toLowerCase();
    for (final section in Section.values) {
      if (section.id.toLowerCase() == value) return section.id;
      if (section.label == declared.trim()) return section.id;
    }
    return null;
  }

  static String? _labelOf(String id) {
    for (final section in Section.values) {
      if (section.id == id) return section.label;
    }
    return null;
  }

  static String _sectionNames() =>
      Section.values.map((section) => '${section.id}（${section.label}）').join('、');

  String toJson() => jsonEncode(<String, Object?>{
        'id': id,
        'name': name,
        'version': version,
        'category': category,
      });
}
