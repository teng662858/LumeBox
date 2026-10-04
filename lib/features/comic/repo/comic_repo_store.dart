import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../core/session/section.dart';
import '../../../core/session/section_scope.dart';
import '../../../core/util/lume_log.dart';
import 'comic_repo_models.dart';

/// 漫画扩展仓库的持久化：板块独占的 `sections/comic/repo.db`。
///
/// 隔离三重：
/// - 文件落在漫画板块目录下（与图源库、阅读库都分文件）；
/// - 库内自证 `owner_section = comic`，标记不符拒绝打开（库文件被挪也不误用）；
/// - 本类只服务漫画板块（[open] 不接受 Section 参数），其他板块既没有句柄
///   也调不到这层。
class ComicRepoStore {
  ComicRepoStore._(this._db);

  static const String dbFileName = 'repo.db';

  static const String _ownerKey = 'owner_section';
  static const String _ownerValue = 'comic';
  static const int _schemaVersion = 1;

  static const String _schema = '''
CREATE TABLE IF NOT EXISTS repo_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS comic_repo (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  kind TEXT NOT NULL,
  extension_count INTEGER NOT NULL DEFAULT 0,
  refreshed_at INTEGER
);
CREATE TABLE IF NOT EXISTS comic_extension (
  repo_id TEXT NOT NULL,
  extension_id TEXT NOT NULL,
  name TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '',
  language TEXT NOT NULL DEFAULT '',
  artifact TEXT NOT NULL,
  url TEXT NOT NULL,
  nsfw INTEGER NOT NULL DEFAULT 0,
  source_names TEXT NOT NULL DEFAULT '[]',
  installed_source_id TEXT,
  installed_version TEXT,
  installed_at INTEGER,
  PRIMARY KEY (repo_id, extension_id)
);
''';

  final Database _db;
  bool _closed = false;

  static final Map<String, ComicRepoStore> _opened = <String, ComicRepoStore>{};

  /// 打开（必要时创建）漫画板块的扩展仓库库。重复调用返回同一实例。
  static Future<ComicRepoStore> open() async {
    final existing = _opened[_ownerValue];
    if (existing != null) return existing;
    final scope = await SectionScope.open(Section.comic);
    final store = ComicRepoStore._(sqlite3.open(scope.resolve(dbFileName)));
    try {
      store._migrate();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      store.dispose();
      rethrow;
    }
    _opened[_ownerValue] = store;
    return store;
  }

  /// 已打开的实例；未打开时返回 null。
  static ComicRepoStore? find() => _opened[_ownerValue];

  /// 建表并做库内自证：归属标记不符即拒绝打开（与图源库 / 阅读库同一套纪律）。
  void _migrate() {
    _db.select('PRAGMA journal_mode = WAL');
    final version =
        _db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < _schemaVersion) {
      _db.execute(_schema);
      _db.execute('PRAGMA user_version = $_schemaVersion');
    }
    final rows = _db.select(
      'SELECT value FROM repo_meta WHERE key = ?',
      <Object?>[_ownerKey],
    );
    if (rows.isEmpty) {
      _db.execute(
        'INSERT INTO repo_meta (key, value) VALUES (?, ?)',
        <Object?>[_ownerKey, _ownerValue],
      );
      return;
    }
    final owner = rows.first['value'] as String;
    if (owner != _ownerValue) {
      throw StateError('拒绝打开非漫画板块的仓库库（归属「$owner」）');
    }
  }

  // ------------------------------------------------------------------ 仓库

  /// 全部仓库，按名称排序。
  List<ComicRepo> repos() {
    final rows = _db.select(
      'SELECT id, name, url, kind, extension_count, refreshed_at '
      'FROM comic_repo ORDER BY name COLLATE NOCASE',
    );
    return rows.map(_repoFromRow).toList(growable: false);
  }

  ComicRepo? repo(String repoId) {
    final rows = _db.select(
      'SELECT id, name, url, kind, extension_count, refreshed_at '
      'FROM comic_repo WHERE id = ?',
      <Object?>[repoId],
    );
    return rows.isEmpty ? null : _repoFromRow(rows.first);
  }

  /// 写入 / 覆盖仓库记录（同一地址重复添加即覆盖）。
  void upsertRepo(ComicRepo repo) {
    _db.execute(
      'INSERT INTO comic_repo (id, name, url, kind, extension_count, refreshed_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, url = excluded.url, '
      'kind = excluded.kind, extension_count = excluded.extension_count, '
      'refreshed_at = excluded.refreshed_at',
      <Object?>[
        repo.id,
        repo.name,
        repo.url.toString(),
        repo.kind.id,
        repo.extensionCount,
        repo.refreshedAt?.millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除仓库与其扩展行。
  ///
  /// 已安装的扩展不会被卸载——它们已经是漫画板块图源表里的独立图源，
  /// 由「图源管理」继续管理（调用方负责把这句提示给用户）。
  void removeRepo(String repoId) {
    _db.execute('DELETE FROM comic_extension WHERE repo_id = ?', <Object?>[repoId]);
    _db.execute('DELETE FROM comic_repo WHERE id = ?', <Object?>[repoId]);
  }

  // ------------------------------------------------------------------ 扩展

  /// 仓库里的扩展，按名称排序。
  List<RepoExtension> extensionsOf(String repoId) {
    final rows = _db.select(
      'SELECT extension_id, name, version, language, artifact, url, nsfw, source_names '
      'FROM comic_extension WHERE repo_id = ? ORDER BY name COLLATE NOCASE',
      <Object?>[repoId],
    );
    return rows.map(_extensionFromRow).toList(growable: false);
  }

  /// 刷新写回：现存扩展整批覆盖；索引里已消失且未安装的行删除，
  /// 已安装的行保留（安装记录不能因为上游下架而丢）。
  void replaceExtensions(String repoId, List<RepoExtension> extensions) {
    _db.execute(
      'DELETE FROM comic_extension WHERE repo_id = ? AND installed_source_id IS NULL',
      <Object?>[repoId],
    );
    for (final extension in extensions) {
      _db.execute(
        'INSERT INTO comic_extension '
        '(repo_id, extension_id, name, version, language, artifact, url, nsfw, source_names) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(repo_id, extension_id) DO UPDATE SET '
        'name = excluded.name, version = excluded.version, '
        'language = excluded.language, artifact = excluded.artifact, '
        'url = excluded.url, nsfw = excluded.nsfw, source_names = excluded.source_names',
        <Object?>[
          repoId,
          extension.id,
          extension.name,
          extension.version,
          extension.language,
          extension.artifact.id,
          extension.url.toString(),
          extension.nsfw ? 1 : 0,
          jsonEncode(extension.sourceNames),
        ],
      );
    }
  }

  /// 仓库里已安装的扩展：extensionId → 安装记录。
  Map<String, InstalledExtension> installedOf(String repoId) {
    final rows = _db.select(
      'SELECT extension_id, installed_source_id, installed_version, installed_at '
      'FROM comic_extension WHERE repo_id = ? AND installed_source_id IS NOT NULL',
      <Object?>[repoId],
    );
    final installed = <String, InstalledExtension>{};
    for (final row in rows) {
      final extensionId = row['extension_id'] as String;
      installed[extensionId] = InstalledExtension(
        repoId: repoId,
        extensionId: extensionId,
        sourceId: row['installed_source_id'] as String,
        version: (row['installed_version'] as String?) ?? '',
        installedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['installed_at'] as int?) ?? 0,
        ),
      );
    }
    return installed;
  }

  /// 记一次安装落地（仓库扩展 → 漫画板块图源 id）。
  void markInstalled({
    required String repoId,
    required String extensionId,
    required String sourceId,
    required String version,
  }) {
    _db.execute(
      'UPDATE comic_extension SET installed_source_id = ?, installed_version = ?, '
      'installed_at = ? WHERE repo_id = ? AND extension_id = ?',
      <Object?>[
        sourceId,
        version,
        DateTime.now().millisecondsSinceEpoch,
        repoId,
        extensionId,
      ],
    );
  }

  /// 清除安装记录（卸载扩展时调用）。
  void clearInstalled({required String repoId, required String extensionId}) {
    _db.execute(
      'UPDATE comic_extension SET installed_source_id = NULL, '
      'installed_version = NULL, installed_at = NULL '
      'WHERE repo_id = ? AND extension_id = ?',
      <Object?>[repoId, extensionId],
    );
  }

  // ------------------------------------------------------------------ 生命周期

  void dispose() {
    if (_closed) return;
    _closed = true;
    _opened.removeWhere((_, value) => identical(value, this));
    try {
      _db.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  /// 关闭并释放所有实例（测试与进程退出用）。
  static void disposeAll() {
    for (final store in _opened.values.toList(growable: false)) {
      store.dispose();
    }
    _opened.clear();
  }

  // ------------------------------------------------------------------ 内部

  ComicRepo _repoFromRow(Row row) => ComicRepo(
        id: row['id'] as String,
        name: row['name'] as String,
        url: Uri.parse(row['url'] as String),
        kind: RepoKind.fromId(row['kind'] as String?),
        extensionCount: (row['extension_count'] as int?) ?? 0,
        refreshedAt: switch (row['refreshed_at'] as int?) {
          final int stamp => DateTime.fromMillisecondsSinceEpoch(stamp),
          null => null,
        },
      );

  RepoExtension _extensionFromRow(Row row) => RepoExtension(
        id: row['extension_id'] as String,
        name: row['name'] as String,
        version: (row['version'] as String?) ?? '',
        language: (row['language'] as String?) ?? '',
        artifact: ExtensionArtifact.fromId(row['artifact'] as String?),
        url: Uri.parse(row['url'] as String),
        nsfw: ((row['nsfw'] as int?) ?? 0) != 0,
        sourceNames: _decodeNames(row['source_names'] as String?),
      );

  static List<String> _decodeNames(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.map((item) => '$item').toList(growable: false);
    } on FormatException {
      return const <String>[];
    }
  }
}
