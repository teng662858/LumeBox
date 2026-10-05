import 'package:sqlite3/sqlite3.dart';

import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'source_record.dart';

/// 板块独占数据库。每个板块一个独立 sqlite 文件，表结构不跨板块共享。
///
/// schema v2 起库文件自证归属：图源记录带归属板块标记（`source.section`），
/// 库内另记一份 `owner_section`；标记与打开它的板块不符即拒绝打开，库文件被
/// 挪到别的板块目录下也不会被误用。
class SectionDatabase {
  SectionDatabase._(this._db, this._sectionId);

  static const int _schemaVersion = 3;

  /// 库内自证键：本库属于哪个板块。
  static const String _ownerKey = 'owner_section';

  static const String _schema = '''
CREATE TABLE IF NOT EXISTS source (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  version    TEXT NOT NULL DEFAULT '',
  section    TEXT NOT NULL DEFAULT '',
  script     TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  user_agent TEXT NOT NULL DEFAULT '',
  cookie     TEXT NOT NULL DEFAULT '',
  proxy      TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS section_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

  final Database _db;

  /// 本库所属板块的 id。归属校验与写入拦截都以它为准。
  final String _sectionId;

  static final Map<String, SectionDatabase> _opened = {};

  static Future<SectionDatabase> open(SectionScope scope) async {
    final existing = _opened[scope.section.id];
    if (existing != null) return existing;
    final database =
        SectionDatabase._(sqlite3.open(scope.dbPath), scope.section.id);
    try {
      database._migrate();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      database.dispose();
      rethrow;
    }
    _opened[scope.section.id] = database;
    return database;
  }

  void _migrate() {
    _db.select('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA foreign_keys = ON');
    final version =
        _db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 1) {
      _db.execute(_schema);
    } else if (version < 2) {
      _db.execute(
          "ALTER TABLE source ADD COLUMN section TEXT NOT NULL DEFAULT ''");
      // 旧库的图源归属就是它所在的板块目录，回填即可。
      _db.execute(
        "UPDATE source SET section = ? WHERE section = ''",
        [_sectionId],
      );
    }
    if (version < 3) {
      // 单图源网络覆盖（UA / Cookie / 代理）：空串表示继承全局设置。
      for (final column in <String>['user_agent', 'cookie', 'proxy']) {
        try {
          _db.execute(
              "ALTER TABLE source ADD COLUMN $column TEXT NOT NULL DEFAULT ''");
        } catch (error) {
          // 列已存在（重复迁移或新库）：忽略。
          LumeLog.warn('迁移 source.$column 跳过: $error');
        }
      }
    }
    if (version < _schemaVersion) {
      _db.execute('PRAGMA user_version = $_schemaVersion');
    }
    _claimSection();
  }

  /// 库文件自证：库内声明所属板块。缺失则落记号（兼容旧库），不符即拒绝打开。
  void _claimSection() {
    final owner = setting(_ownerKey);
    if (owner == null) {
      setSetting(_ownerKey, _sectionId);
      return;
    }
    if (owner != _sectionId) {
      throw StateError(
        '板块库归属不符：库中标记为「$owner」，不能以「$_sectionId」打开',
      );
    }
  }

  List<SourceRecord> sources() => _db
      .select('SELECT * FROM source ORDER BY name')
      .map(SourceRecord.fromRow)
      .toList(growable: false);

  SourceRecord? source(String id) {
    final rows = _db.select('SELECT * FROM source WHERE id = ?', [id]);
    return rows.isEmpty ? null : SourceRecord.fromRow(rows.first);
  }

  void upsertSource({
    required String id,
    required String name,
    required String version,
    required String section,
    required String script,
  }) {
    if (section != _sectionId) {
      throw ArgumentError(
        '拒绝跨板块写入：记录归属「$section」，本库属于「$_sectionId」',
      );
    }
    _db.execute(
      'INSERT INTO source (id, name, version, section, script, enabled, '
      'updated_at) VALUES (?, ?, ?, ?, ?, 1, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'version = excluded.version, section = excluded.section, '
      'script = excluded.script, '
      'updated_at = excluded.updated_at',
      [
        id,
        name,
        version,
        section,
        script,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 写入单图源网络覆盖（UA / Cookie / 代理）。空串表示继承全局设置。
  void setSourceNetwork(
    String id, {
    required String userAgent,
    required String cookie,
    required String proxy,
  }) {
    _db.execute(
      'UPDATE source SET user_agent = ?, cookie = ?, proxy = ? WHERE id = ?',
      [userAgent, cookie, proxy, id],
    );
  }

  void setSourceEnabled(String id, bool enabled) {
    _db.execute('UPDATE source SET enabled = ? WHERE id = ?',
        [enabled ? 1 : 0, id]);
  }

  void deleteSource(String id) =>
      _db.execute('DELETE FROM source WHERE id = ?', [id]);

  String? setting(String key) {
    final rows =
        _db.select('SELECT value FROM section_setting WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) => _db.execute(
        'INSERT INTO section_setting (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  void dispose() {
    _opened.removeWhere((_, value) => identical(value, this));
    try {
      _db.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  static void disposeAll() {
    for (final database in _opened.values.toList(growable: false)) {
      database.dispose();
    }
    _opened.clear();
  }
}
