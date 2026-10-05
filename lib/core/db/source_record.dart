import 'package:sqlite3/sqlite3.dart';

import '../net/network_settings.dart';

/// 图源的持久化模型。每个板块的库中各自保存，图源不跨板块共享。
class SourceRecord {
  const SourceRecord({
    required this.id,
    required this.name,
    required this.version,
    required this.section,
    required this.script,
    required this.enabled,
    this.network = NetworkProfile.none,
  });

  final String id;
  final String name;
  final String version;

  /// 归属板块标记：导入时落库，读取路径据此拒绝跨板块记录。
  final String section;

  final String script;
  final bool enabled;

  /// 单图源网络覆盖（UA / Cookie / 代理）；空项继承全局设置。
  final NetworkProfile network;

  factory SourceRecord.fromRow(Row row) => SourceRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        version: row['version'] as String,
        section: row['section'] as String,
        script: row['script'] as String,
        enabled: (row['enabled'] as int) != 0,
        network: NetworkProfile(
          userAgent: '${row['user_agent'] ?? ''}',
          cookie: '${row['cookie'] ?? ''}',
          proxy: '${row['proxy'] ?? ''}',
        ),
      );
}
