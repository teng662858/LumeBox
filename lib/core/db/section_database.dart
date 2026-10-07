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

  static const int _schemaVersion = 6;

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
  bridge     TEXT NOT NULL DEFAULT '',
  cookie     TEXT NOT NULL DEFAULT '',
  proxy      TEXT NOT NULL DEFAULT '',
  origin_url TEXT NOT NULL DEFAULT '',
  source_group TEXT NOT NULL DEFAULT '',
  failure_count INTEGER NOT NULL DEFAULT 0,
  broken_at  INTEGER NOT NULL DEFAULT 0
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
    // 全新库（user_version = 0）直接按当前 schema 建表，**表里已经带了后续
    // 版本追加的全部列**。若不记住这一点，下面那些 `ALTER TABLE ADD COLUMN`
    // 会在新库上重复执行、撞「duplicate column name」，把每次首次打开板块
    // 都写成四条告警——用户导出错误报告时会看到一堆假故障。
    final createdFresh = version < 1;
    if (createdFresh) {
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
    if (!createdFresh && version < 4) {
      // 订阅来源地址：从订阅链接导入时记下，供「更新订阅源」重新拉取。
      // 本地导入的图源留空（没有可更新的来源）。
      try {
        _db.execute(
            "ALTER TABLE source ADD COLUMN origin_url TEXT NOT NULL DEFAULT ''");
      } catch (error) {
        LumeLog.warn('迁移 source.origin_url 跳过: $error');
      }
    }
    if (!createdFresh && version < 3) {
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
    if (!createdFresh && version < 5) {
      // 图源分组与失效标记（文档「图源导入/导出模块规范」）：
      // - source_group：用户自定的分组名，空串表示未分组；
      // - failure_count / broken_at：连续失败次数与「标记为失效」的时间戳。
      //   失效的源不再参与自动重试（用户可在管理页手动恢复）。
      for (final column in <String>[
        "source_group TEXT NOT NULL DEFAULT ''",
        'failure_count INTEGER NOT NULL DEFAULT 0',
        'broken_at INTEGER NOT NULL DEFAULT 0',
      ]) {
        try {
          _db.execute('ALTER TABLE source ADD COLUMN $column');
        } catch (error) {
          // 列已存在（重复迁移或新库）：忽略。
          LumeLog.warn('迁移 source 列跳过: $error');
        }
      }
    }
    if (!createdFresh && version < 6) {
      // 桥接服务地址（用户口径 2.2）：reCAPTCHA v3 这类源需要一个无头浏览器桥，
      // 地址按图源存，交给脚本去转发请求（见 NetworkProfile.bridge）。
      _db.execute("ALTER TABLE source ADD COLUMN bridge TEXT NOT NULL DEFAULT ''");
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

  /// 记录图源的订阅来源地址（从订阅链接导入时调用）。
  void setSourceOrigin(String id, String url) {
    _db.execute(
      'UPDATE source SET origin_url = ? WHERE id = ?',
      [url.trim(), id],
    );
  }

  /// 写入单图源网络覆盖（UA / Cookie / 代理）。空串表示继承全局设置。
  void setSourceNetwork(
    String id, {
    required String userAgent,
    required String cookie,
    required String proxy,
    String bridge = '',
  }) {
    _db.execute(
      'UPDATE source SET user_agent = ?, cookie = ?, proxy = ?, bridge = ? WHERE id = ?',
      [userAgent, cookie, proxy, bridge, id],
    );
  }

  void setSourceEnabled(String id, bool enabled) {
    _db.execute('UPDATE source SET enabled = ? WHERE id = ?',
        [enabled ? 1 : 0, id]);
  }

  /// 写入图源分组名（空串表示取消分组）。
  void setSourceGroup(String id, String group) {
    _db.execute(
      'UPDATE source SET source_group = ? WHERE id = ?',
      [group.trim(), id],
    );
  }

  /// 记录一次失败：失败计数 +1，达到 [threshold] 即标记失效。
  ///
  /// 返回标记后的记录（未失效时 brokenAt 仍为 0）。
  void recordSourceFailure(String id, {required int threshold}) {
    _db.execute(
      'UPDATE source SET failure_count = failure_count + 1 WHERE id = ?',
      [id],
    );
    final rows = _db.select(
      'SELECT failure_count, broken_at FROM source WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return;
    final count = (rows.first['failure_count'] as int?) ?? 0;
    final alreadyBroken = ((rows.first['broken_at'] as int?) ?? 0) > 0;
    if (count >= threshold && !alreadyBroken) {
      _db.execute(
        'UPDATE source SET broken_at = ? WHERE id = ?',
        [DateTime.now().millisecondsSinceEpoch, id],
      );
    }
  }

  /// 清零失败计数并解除失效标记（用户手动「恢复」时调用）。
  void clearSourceFailure(String id) {
    _db.execute(
      'UPDATE source SET failure_count = 0, broken_at = 0 WHERE id = ?',
      [id],
    );
  }

  /// 清掉一个图源的分组（删除源时不需要，记录整行都会删）。
  void clearSourceGroup(String id) => setSourceGroup(id, '');

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
