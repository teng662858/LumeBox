import 'dart:convert';

/// 图源脚本声明的元信息。脚本以全局 `LumeSource` 的 id / name / version 字段提供。
class SourceMetadata {
  const SourceMetadata({
    required this.id,
    required this.name,
    required this.version,
  });

  final String id;
  final String name;
  final String version;

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
