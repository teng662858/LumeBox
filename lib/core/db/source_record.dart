import 'package:sqlite3/sqlite3.dart';

/// 图源的持久化模型。每个板块的库中各自保存，图源不跨板块共享。
class SourceRecord {
  const SourceRecord({
    required this.id,
    required this.name,
    required this.version,
    required this.section,
    required this.script,
    required this.enabled,
  });

  final String id;
  final String name;
  final String version;

  /// 归属板块标记：导入时落库，读取路径据此拒绝跨板块记录。
  final String section;

  final String script;
  final bool enabled;

  factory SourceRecord.fromRow(Row row) => SourceRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        version: row['version'] as String,
        section: row['section'] as String,
        script: row['script'] as String,
        enabled: (row['enabled'] as int) != 0,
      );
}
