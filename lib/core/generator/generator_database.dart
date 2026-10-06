import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../session/section.dart';
import '../util/lume_log.dart';

/// 一条「图源生成器」的爬虫配置草稿。
///
/// **这是预留结构，不是可用能力**：字段先按「可视化爬虫」将来要存的东西摆好
/// （目标网址、列表 / 详情 / 正文三处规则、分页与请求头），当前没有任何代码
/// 会读它去发请求——Phase2 明确不做爬虫业务逻辑。
///
/// 与图源记录的关系：**生成器产物最终仍走各板块的正常导入链路**。这张表只存
/// 「规则草稿」，不存可运行的图源；因此它既不是图源库的一部分，也不构成任何
/// 绕开板块隔离的旁路（[section] 只是标记这条草稿打算生成给哪个板块用，
/// 写入图源时依然由目标板块的导入校验把关）。
class CrawlerConfigRecord {
  const CrawlerConfigRecord({
    required this.id,
    required this.name,
    required this.targetUrl,
    this.section = '',
    this.listRule = '',
    this.detailRule = '',
    this.contentRule = '',
    this.pageParam = '',
    this.encoding = 'utf-8',
    this.headersJson = '{}',
    this.generatedScript = '',
    this.createdAt,
    this.updatedAt,
  });

  /// 草稿 id（板块内唯一由调用方决定，这里不做业务校验）。
  final String id;

  /// 草稿名（给用户看的）。
  final String name;

  /// 目标网址（列表页 / 接口地址）。
  final String targetUrl;

  /// 打算生成给哪个板块（[Section.id]）；空串表示还没选。
  final String section;

  /// 列表页规则（选择器 / 正则，形态待定）。
  final String listRule;

  /// 详情页规则。
  final String detailRule;

  /// 正文（小说文本 / 漫画图片 / 视频地址）规则。
  final String contentRule;

  /// 分页参数名（如 `page`）。
  final String pageParam;

  /// 页面编码（如 `utf-8` / `gbk`）。
  final String encoding;

  /// 附加请求头（JSON 文本：UA / Referer / Cookie 等）。
  final String headersJson;

  /// 生成出来的脚本草稿（将来由生成器填充；当前恒为空串）。
  final String generatedScript;

  final int? createdAt;
  final int? updatedAt;

  /// 从数据库行还原。缺列按默认值处理，便于将来加列时不破坏旧数据。
  static CrawlerConfigRecord fromRow(Row row) => CrawlerConfigRecord(
        id: '${row['id']}',
        name: '${row['name'] ?? ''}',
        targetUrl: '${row['target_url'] ?? ''}',
        section: '${row['section'] ?? ''}',
        listRule: '${row['list_rule'] ?? ''}',
        detailRule: '${row['detail_rule'] ?? ''}',
        contentRule: '${row['content_rule'] ?? ''}',
        pageParam: '${row['page_param'] ?? ''}',
        encoding: '${row['encoding'] ?? 'utf-8'}',
        headersJson: '${row['headers_json'] ?? '{}'}',
        generatedScript: '${row['generated_script'] ?? ''}',
        createdAt: row['created_at'] as int?,
        updatedAt: row['updated_at'] as int?,
      );
}

/// 图源生成器（可视化爬虫模块）的**预留**存储。
///
/// ## 定位
///
/// 生成器是设置页里的工具附属功能，不是阅读板块：它的配置不属于任何一个板块，
/// 因此库文件落在应用支持目录根部（`generator.db`），**不进 `sections/<id>/`**
/// ——放进去会被误读成「某个板块的数据」，与四板块隔离的口径冲突。
///
/// ## 当前状态（Phase2 收尾）
///
/// 只有建表与最小读写：表结构按将来的爬虫配置字段摆好，供后续迭代直接落数据。
/// **不包含任何爬虫业务逻辑**（不发请求、不解析页面、不生成脚本）——那是后续
/// 迭代的事，本轮只保证「表在、字段齐、写入路径可用」。
///
/// ## 不变式
///
/// - 生成的图源**必须**经目标板块的正常导入链路写入（`SourceRegistry.import`），
///   本模块不提供任何直接写图源表的入口——板块隔离由那条链路把关，不在这里开口子；
/// - 本库只存规则草稿，删掉它不影响任何已导入的图源。
class GeneratorDatabase {
  GeneratorDatabase._(this._db);

  /// 当前 schema 版本。加列 / 加表时递增，并在 [_migrate] 里补迁移。
  static const int schemaVersion = 1;

  static const String fileName = 'generator.db';

  /// 预留表名：爬虫配置。文档与后续迭代都按这个名字引用。
  static const String configTable = 'crawler_config';

  /// 预留的爬虫配置表。
  ///
  /// 字段按「可视化爬虫」需要存的东西摆好（目标网址 / 三处规则 / 分页 / 编码 /
  /// 请求头 / 生成结果）。当前没有任何代码会拿它们去抓取——**预留字段先落地，
  /// 后续迭代再填充能力**，避免将来做迁移。
  static const String _schema = '''
CREATE TABLE IF NOT EXISTS crawler_config (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL DEFAULT '',
  target_url       TEXT NOT NULL DEFAULT '',
  section          TEXT NOT NULL DEFAULT '',
  list_rule        TEXT NOT NULL DEFAULT '',
  detail_rule      TEXT NOT NULL DEFAULT '',
  content_rule     TEXT NOT NULL DEFAULT '',
  page_param       TEXT NOT NULL DEFAULT '',
  encoding         TEXT NOT NULL DEFAULT 'utf-8',
  headers_json     TEXT NOT NULL DEFAULT '{}',
  generated_script TEXT NOT NULL DEFAULT '',
  created_at       INTEGER NOT NULL DEFAULT 0,
  updated_at       INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS generator_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

  final Database _db;

  static GeneratorDatabase? _opened;

  /// 打开（必要时创建）生成器库。重复调用返回同一实例。
  static Future<GeneratorDatabase> open() async {
    final existing = _opened;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final database = GeneratorDatabase._(
      sqlite3.open(p.join(base.path, fileName)),
    );
    try {
      database._migrate();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      database.dispose();
      rethrow;
    }
    _opened = database;
    return database;
  }

  void _migrate() {
    _db.select('PRAGMA journal_mode = WAL');
    final version =
        _db.select('PRAGMA user_version').first['user_version'] as int;
    // 与板块库同一口径：全新库直接按当前 schema 建表（表里已含全部列），
    // 因此迁移段只处理真正的旧库，不在新库上重复 ALTER 出假告警。
    if (version < 1) {
      _db.execute(_schema);
    }
    if (version < schemaVersion) {
      _db.execute('PRAGMA user_version = $schemaVersion');
    }
  }

  /// 已保存的规则草稿（按更新时间倒序）。
  List<CrawlerConfigRecord> configs() => _db
      .select('SELECT * FROM $configTable ORDER BY updated_at DESC')
      .map(CrawlerConfigRecord.fromRow)
      .toList(growable: false);

  CrawlerConfigRecord? config(String id) {
    final rows = _db.select('SELECT * FROM $configTable WHERE id = ?', [id]);
    return rows.isEmpty ? null : CrawlerConfigRecord.fromRow(rows.first);
  }

  /// 保存（新增或覆盖）一条规则草稿。
  ///
  /// 只做存储，不做任何规则合法性判断——校验属于将来的生成器能力。
  void saveConfig(CrawlerConfigRecord record) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO $configTable (id, name, target_url, section, list_rule, '
      'detail_rule, content_rule, page_param, encoding, headers_json, '
      'generated_script, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'target_url = excluded.target_url, section = excluded.section, '
      'list_rule = excluded.list_rule, detail_rule = excluded.detail_rule, '
      'content_rule = excluded.content_rule, page_param = excluded.page_param, '
      'encoding = excluded.encoding, headers_json = excluded.headers_json, '
      'generated_script = excluded.generated_script, '
      'updated_at = excluded.updated_at',
      [
        record.id,
        record.name,
        record.targetUrl,
        record.section,
        record.listRule,
        record.detailRule,
        record.contentRule,
        record.pageParam,
        record.encoding,
        record.headersJson,
        record.generatedScript,
        record.createdAt ?? now,
        now,
      ],
    );
  }

  void deleteConfig(String id) =>
      _db.execute('DELETE FROM $configTable WHERE id = ?', [id]);

  /// 某板块的草稿（`section` 为空串的是「还没选板块」的草稿，两者都返回）。
  List<CrawlerConfigRecord> configsFor(Section section) => _db
      .select(
        'SELECT * FROM $configTable WHERE section = ? OR section = ? '
        'ORDER BY updated_at DESC',
        [section.id, ''],
      )
      .map(CrawlerConfigRecord.fromRow)
      .toList(growable: false);

  String? setting(String key) {
    final rows =
        _db.select('SELECT value FROM generator_setting WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) => _db.execute(
        'INSERT INTO generator_setting (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  void dispose() {
    if (identical(_opened, this)) _opened = null;
    try {
      _db.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  /// 释放全部实例（测试隔离 / 进程退出用）。
  static void disposeAll() {
    _opened?.dispose();
    _opened = null;
  }

  /// 仅测试用：关闭并丢弃实例缓存（换目录后重新打开）。
  ///
  /// 必须先 dispose 再清引用：只清引用会把 sqlite 句柄漏在那里，Windows 上
  /// 临时目录随即删不掉（「另一个程序正在使用此文件」）。
  static void resetForTesting() {
    _opened?.dispose();
    _opened = null;
  }
}
