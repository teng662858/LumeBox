import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'reading_models.dart';
import 'reading_identity.dart';

/// 板块独占的阅读库：书架、阅读进度、阅读设置。
///
/// 与图源库（`<id>.db`）分开存放在 `sections/<id>/reading.db`，理由有二：
/// 一是阅读体系与图源体系的表结构互不牵连，各自演进；二是库文件级隔离比同库
/// 分表更硬——阅读数据不会因为图源库迁移、清理而被牵连。
///
/// 隔离约束与图源库一致，且一样是三重：
/// - **目录**：所有文件都在本板块的 [SectionScope] 之内，路径经 [SectionScope.resolve] 校验；
/// - **归属标记**：库内自证 `owner_section`，不符即拒绝打开（库文件被挪也不误用）；
/// - **写入拦截**：条目与进度都带板块标记，跨板块写入直接抛错。
///
/// 缓存目录同样独占：`sections/<id>/reading_cache/`，其下 `images/` 放图片缓存，
/// `exports/` 保留用户手动保存的图片，不参与缓存清理。
class ReadingStore {
  ReadingStore._(this.section, this._scope, this._db);

  /// 库内自证键：本库属于哪个板块。
  static const String _ownerKey = 'owner_section';

  static const int _schemaVersion = 5;

  /// 板块内阅读数据根目录（相对板块根）。
  static const String cacheRootName = 'reading_cache';

  static const String _schema = '''
CREATE TABLE IF NOT EXISTS library_item (
  item_id            TEXT PRIMARY KEY,
  section            TEXT NOT NULL,
  source_id          TEXT NOT NULL,
  title              TEXT NOT NULL,
  cover              TEXT,
  subtitle           TEXT,
  chapter_count      INTEGER NOT NULL DEFAULT 0,
  read_chapter_index INTEGER NOT NULL DEFAULT -1,
  added_at           INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS reading_progress (
  item_id        TEXT PRIMARY KEY,
  section        TEXT NOT NULL,
  chapter_index  INTEGER NOT NULL,
  chapter_id     TEXT NOT NULL,
  chapter_title TEXT NOT NULL DEFAULT '',
  position       INTEGER NOT NULL DEFAULT 0,
  fraction       REAL NOT NULL DEFAULT 0,
  chapter_length INTEGER NOT NULL DEFAULT 0,
  progress_kind  TEXT NOT NULL DEFAULT '',
  updated_at     INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS reading_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

  final Section section;
  final SectionScope _scope;
  final Database _db;

  /// Copy first, then let the relocation coordinator remove the old source.
  /// Destination checkpoints win when newer; source/item identity is unchanged.
  void copySourceTo(String sourceId, ReadingStore target) {
    target._db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in [
        'library_item',
        'reading_progress',
        'video_episode_progress',
      ]) {
        for (final row in _db.select('SELECT * FROM $table WHERE source_id=?', [
          sourceId,
        ])) {
          final names = row.keys.toList();
          final keys = [
            'source_id',
            'item_id',
            if (table == 'video_episode_progress') 'chapter_id',
          ];
          final update = names
              .where((key) => !keys.contains(key))
              .map(
                (key) => key == 'favorite'
                    ? 'favorite=MAX($table.favorite,excluded.favorite)'
                    : '$key=excluded.$key',
              )
              .join(',');
          target._db.execute(
            'INSERT INTO $table (${names.join(',')}) VALUES (${List.filled(names.length, '?').join(',')}) '
            'ON CONFLICT(${keys.join(',')}) DO UPDATE SET $update WHERE excluded.updated_at >= $table.updated_at',
            [
              for (final key in names)
                key == 'section' ? target.section.id : row[key],
            ],
          );
        }
      }
      for (final row in _db.select('SELECT * FROM reading_setting')) {
        final key = row['key'] as String;
        if (key == 'source.preferences.$sourceId' ||
            key == 'reader.chapterDescending.$sourceId' ||
            key.startsWith('video.player.')) {
          target._db.execute(
            'INSERT OR IGNORE INTO reading_setting(key,value) VALUES (?,?)',
            [key, row['value']],
          );
        }
      }
      final folders = setting('favorites.folders');
      if (folders != null) {
        final oldFolders = jsonDecode(folders) as Map;
        final newFolders = Map<String, dynamic>.from(
          jsonDecode(target.setting('favorites.folders') ?? '{}') as Map,
        );
        for (final entry in oldFolders.entries) {
          final members = (entry.value as List)
              .whereType<String>()
              .where((id) => ReadingIdentity.decode(id)?.first == sourceId)
              .toList();
          if (members.isNotEmpty) {
            newFolders['${entry.key}'] = {
              ...(newFolders['${entry.key}'] as List? ?? []),
              ...members,
            }.toList();
          }
        }
        target.setSetting('favorites.folders', jsonEncode(newFolders));
      }
      target._db.execute('COMMIT');
    } catch (_) {
      target._db.execute('ROLLBACK');
      rethrow;
    }
  }

  void removeRelocatedSource(String sourceId) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in [
        'library_item',
        'reading_progress',
        'video_episode_progress',
      ]) {
        _db.execute('DELETE FROM $table WHERE source_id=?', [sourceId]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static final Map<String, ReadingStore> _opened = <String, ReadingStore>{};
  static final Map<String, Future<ReadingStore>> _opening = {};

  /// 库是否已释放。
  ///
  /// 页面晚于库释放而退出是正常时序（资源宿主先于页面回收、或测试里先关库再
  /// 卸树），此时读写一律静默降级：读返回空、写不做。进度是尽力而为的数据，
  /// 不该因为「库先关了」把退出流程炸掉。
  bool _closed = false;

  /// 库已释放时返回 true。
  bool get isClosed => _closed;

  /// 打开（必要时创建）板块阅读库。同一板块重复调用返回同一实例。
  static Future<ReadingStore> open(Section section) async {
    final existing = _opened[section.id];
    if (existing != null) return existing;
    return _opening.putIfAbsent(
      section.id,
      () => _open(section).whenComplete(() {
        _opening.remove(section.id);
      }),
    );
  }

  static Future<ReadingStore> _open(Section section) async {
    final scope = await SectionScope.open(section);
    final store = ReadingStore._(
      section,
      scope,
      sqlite3.open(_readingDbPath(scope)),
    );
    try {
      store._migrate();
      store._prepareDirectories();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      store.dispose();
      rethrow;
    }
    _opened[section.id] = store;
    return store;
  }

  /// 阅读库文件路径：与图源库同目录、不同文件。
  static String _readingDbPath(SectionScope scope) =>
      scope.resolve('reading.db');

  /// 板块内图片缓存目录。
  String get imageCacheDir => _resolveUnderCache('images');

  /// 用户长按保存的图片目录（不参与缓存清理）。
  String get exportDir => _resolveUnderCache('exports');

  String _resolveUnderCache(String name) =>
      _scope.resolve(p.join(cacheRootName, name));

  void _prepareDirectories() {
    for (final dir in <String>[imageCacheDir, exportDir]) {
      Directory(dir).createSync(recursive: true);
    }
  }

  void _migrate() {
    _db.select('PRAGMA journal_mode = WAL');
    final version =
        _db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 1) {
      _db.execute(_schema);
    }
    if (version < 2 &&
        !_db
            .select('PRAGMA table_info(reading_progress)')
            .any((row) => row['name'] == 'progress_kind')) {
      _db.execute(
        "ALTER TABLE reading_progress ADD COLUMN progress_kind TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!_db
        .select('PRAGMA table_info(library_item)')
        .any((row) => row['name'] == 'favorite')) {
      _db.execute(
        'ALTER TABLE library_item ADD COLUMN favorite INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (version < 4) {
      _db.execute(
        'CREATE TABLE IF NOT EXISTS video_episode_progress AS SELECT * FROM reading_progress WHERE 0',
      );
      _db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS video_episode_identity ON video_episode_progress(item_id, chapter_id, section)',
      );
      _db.execute(
        "INSERT OR IGNORE INTO video_episode_progress SELECT * FROM reading_progress WHERE progress_kind = 'video'",
      );
    }
    if (version < 5) _migrateIdentity();
    if (version < _schemaVersion) {
      _db.execute('PRAGMA user_version = $_schemaVersion');
    }
    _claimSection();
    _db.execute(
      'CREATE INDEX IF NOT EXISTS library_item_recent ON library_item(section, updated_at DESC)',
    );
  }

  void _migrateIdentity() {
    // A separate SQLite snapshot remains available if migration is interrupted.
    final backup = File('${_readingDbPath(_scope)}.before-identity-v5');
    if (!backup.existsSync()) {
      _db.execute("VACUUM INTO '${backup.path.replaceAll("'", "''")}'");
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in [
        'library_item',
        'reading_progress',
        'video_episode_progress',
      ]) {
        final info = _db.select('PRAGMA table_info($table)');
        if (info.any((r) => r['name'] == 'source_id' && (r['pk'] as int) > 0)) {
          continue;
        }
        var sql =
            _db.select(
                  'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
                  ['table', table],
                ).first['sql']
                as String;
        _db.execute('ALTER TABLE $table RENAME TO ${table}_legacy_v4');
        sql = sql.replaceFirst(
          RegExp(
            r'CREATE TABLE\s+(?:IF NOT EXISTS\s+)?"?' + table + r'"?',
            caseSensitive: false,
          ),
          'CREATE TABLE $table',
        );
        sql = sql.replaceFirst(
          RegExp(r'item_id\s+TEXT\s+PRIMARY KEY', caseSensitive: false),
          'item_id TEXT NOT NULL',
        );
        if (!info.any((r) => r['name'] == 'source_id')) {
          sql = sql.replaceFirst('(', "(source_id TEXT NOT NULL DEFAULT '',");
        }
        final end = sql.lastIndexOf(')');
        sql =
            '${sql.substring(0, end)}, PRIMARY KEY(source_id,item_id${table == 'video_episode_progress' ? ',chapter_id' : ''})${sql.substring(end)}';
        _db.execute(sql);
        final columns = _db
            .select('PRAGMA table_info(${table}_legacy_v4)')
            .map((r) => r['name'] as String)
            .toList();
        if (columns.contains('source_id')) {
          _db.execute(
            'INSERT INTO $table (${columns.join(',')}) SELECT ${columns.join(',')} FROM ${table}_legacy_v4',
          );
        } else {
          _db.execute(
            "INSERT INTO $table (source_id,${columns.join(',')}) SELECT COALESCE((SELECT source_id FROM library_item WHERE item_id = old.item_id),''),${columns.map((c) => 'old.$c').join(',')} FROM ${table}_legacy_v4 old",
          );
        }
      }
      for (final table in [
        'video_episode_progress',
        'reading_progress',
        'library_item',
      ]) {
        _db.execute('DROP TABLE IF EXISTS ${table}_legacy_v4');
        _db.execute(
          'CREATE INDEX IF NOT EXISTS ${table}_lookup ON $table(item_id)',
        );
      }
      final owners = _db.select('SELECT item_id, source_id FROM library_item');
      final folders = setting('favorites.folders');
      if (folders != null) {
        try {
          final data = jsonDecode(folders) as Map;
          final updated = data.map(
            (name, ids) => MapEntry(
              name,
              (ids as List).map((id) {
                final match = owners.where((r) => r['item_id'] == id).toList();
                return match.length == 1
                    ? ReadingIdentity.key(
                        match.single['source_id'] as String,
                        '$id',
                      )
                    : id;
              }).toList(),
            ),
          );
          setSetting('favorites.folders', jsonEncode(updated));
        } catch (_) {
          /* A damaged folder cannot block progress migration. */
        }
      }
      for (final row in owners) {
        final item = row['item_id'] as String;
        if (owners.where((r) => r['item_id'] == item).length != 1) continue;
        final id = ReadingIdentity.key(row['source_id'] as String, item);
        for (final prefix in [
          'favorite.updated.',
          'bangumi.binding.',
          'skip.marks.',
          'comic.bookmarks.',
          'comic.annotations.',
        ]) {
          final value = setting('$prefix$item');
          if (value != null) {
            setSetting('$prefix$id', value);
            _db.execute('DELETE FROM reading_setting WHERE key = ?', [
              '$prefix$item',
            ]);
          }
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Legacy callers may resolve an ID only when ownership is unambiguous.
  String? sourceFor(String itemId, [String? sourceId]) {
    if (_closed) return sourceId;
    final identity = ReadingIdentity.decode(itemId);
    if (identity != null) return identity[0];
    if (sourceId != null) return sourceId;
    final rows = _db.select(
      'SELECT DISTINCT source_id FROM library_item WHERE item_id = ? UNION SELECT DISTINCT source_id FROM reading_progress WHERE item_id = ?',
      [itemId, itemId],
    );
    return rows.length == 1
        ? rows.single['source_id'] as String
        : rows.isEmpty
        ? ''
        : null;
  }

  String rawId(String id) => ReadingIdentity.decode(id)?[1] ?? id;

  /// 库文件自证：库内声明所属板块，缺失则落记号，不符即拒绝打开。
  void _claimSection() {
    final owner = setting(_ownerKey);
    if (owner == null) {
      setSetting(_ownerKey, section.id);
      return;
    }
    if (owner != section.id) {
      throw StateError('阅读库归属不符：库中标记为「$owner」，不能以「${section.id}」打开');
    }
  }

  // ------------------------------------------------------------------ 书架

  /// 书架条目，最近加入或阅读的在前。
  List<LibraryItem> shelf({bool includeHistoryOnly = false}) {
    if (_closed) return const <LibraryItem>[];
    final rows = _db.select(
      'SELECT * FROM library_item WHERE section = ? ${includeHistoryOnly ? '' : 'AND favorite = 1'} ORDER BY updated_at DESC',
      <Object?>[section.id],
    );
    final items = <LibraryItem>[];
    for (final row in rows) {
      final item = _itemFromRow(row);
      if (item != null) items.add(item);
    }
    return List<LibraryItem>.unmodifiable(items);
  }

  /// Filter history in one indexed query instead of querying twice per item.
  List<LibraryItem> historyItems() {
    if (_closed) return [];
    return [
      for (final row in _db.select(
        "SELECT l.* FROM library_item l WHERE l.section = ? AND (l.favorite = 0 OR EXISTS (SELECT 1 FROM reading_progress p WHERE p.source_id = l.source_id AND p.item_id = l.item_id AND p.section = l.section AND (l.section != 'cat' OR p.progress_kind IN ('comic','video')))) ORDER BY l.updated_at DESC",
        [section.id],
      ))
        ?_itemFromRow(row),
    ];
  }

  bool isFavorite(String itemId, {String? sourceId}) =>
      !_closed &&
      _db.select(
        'SELECT 1 FROM library_item WHERE item_id = ? AND section = ? AND source_id = ? AND favorite = 1',
        [rawId(itemId), section.id, sourceFor(itemId, sourceId)],
      ).isNotEmpty;

  void removeFavorite(String itemId, {String? sourceId}) {
    if (_closed) return;
    _db.execute(
      'UPDATE library_item SET favorite = 0 WHERE item_id = ? AND section = ? AND source_id = ?',
      [rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
  }

  /// 单条书架条目。不存在或归属不符时返回 null。
  LibraryItem? item(String itemId, {String? sourceId}) {
    if (_closed) return null;
    final rows = _db.select(
      'SELECT * FROM library_item WHERE item_id = ? AND source_id = ?',
      <Object?>[rawId(itemId), sourceFor(itemId, sourceId)],
    );
    return rows.isEmpty ? null : _itemFromRow(rows.first);
  }

  /// 写入（或更新）书架条目。
  ///
  /// 更新语义刻意保守：章节总数只在拿到非零值时覆盖（图源偶发少返章节时
  /// 不缩水，未读角标才不会乱跳），已读章节序号与加入时间都不被触碰。
  void _adoptLegacyProgress(LibraryItem item) {
    if (item.sourceId.isEmpty ||
        _db.select(
          'SELECT 1 FROM library_item WHERE item_id = ? AND source_id != ?',
          [item.itemId, item.sourceId],
        ).isNotEmpty) {
      return;
    }
    for (final table in ['reading_progress', 'video_episode_progress']) {
      _db.execute(
        'UPDATE OR IGNORE $table SET source_id = ? WHERE item_id = ? AND source_id = ?',
        [item.sourceId, item.itemId, ''],
      );
    }
  }

  void upsertItem(LibraryItem item) {
    if (_closed) return;
    _requireOwn(item.section);
    _adoptLegacyProgress(item);
    _db.execute(
      'INSERT INTO library_item (item_id, section, source_id, title, cover, '
      'subtitle, chapter_count, read_chapter_index, added_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(source_id,item_id) DO UPDATE SET '
      'favorite = 1, source_id = excluded.source_id, '
      'title = excluded.title, '
      'cover = excluded.cover, '
      'subtitle = excluded.subtitle, '
      'chapter_count = CASE WHEN excluded.chapter_count > 0 '
      '  THEN excluded.chapter_count ELSE library_item.chapter_count END, '
      'updated_at = excluded.updated_at',
      <Object?>[
        item.itemId,
        item.section.id,
        item.sourceId,
        item.title,
        item.cover,
        item.subtitle,
        item.chapterCount,
        item.readChapterIndex,
        item.addedAt.millisecondsSinceEpoch,
        item.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// 只写「历史」需要的作品元数据：新行 favorite = 0，已有行保留原收藏状态。
  ///
  /// 播放进度落库必须走这里，**绝不**碰收藏。只有用户明确加书架
  /// （[upsertItem]）才把 favorite 置 1——否则「播过 = 收藏」会把收藏页污染掉。
  void ensureHistoryItem(LibraryItem item) {
    if (_closed) return;
    _requireOwn(item.section);
    _adoptLegacyProgress(item);
    _db.execute(
      'INSERT INTO library_item (item_id, section, source_id, title, cover, '
      'subtitle, chapter_count, read_chapter_index, added_at, updated_at, '
      'favorite) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) '
      'ON CONFLICT(source_id,item_id) DO UPDATE SET '
      'source_id = excluded.source_id, '
      'title = excluded.title, '
      'cover = excluded.cover, '
      'subtitle = excluded.subtitle, '
      'chapter_count = CASE WHEN excluded.chapter_count > 0 '
      '  THEN excluded.chapter_count ELSE library_item.chapter_count END, '
      'updated_at = excluded.updated_at',
      <Object?>[
        item.itemId,
        item.section.id,
        item.sourceId,
        item.title,
        item.cover,
        item.subtitle,
        item.chapterCount,
        item.readChapterIndex,
        item.addedAt.millisecondsSinceEpoch,
        item.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  void removeItem(String itemId, {String? sourceId}) {
    if (_closed) return;
    _db.execute(
      'DELETE FROM library_item WHERE item_id = ? AND section = ? AND source_id = ?',
      <Object?>[rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
  }

  /// 同步章节总数（详情页拿到章节列表时调用）。
  void setChapterCount(String itemId, int chapterCount, {String? sourceId}) {
    if (_closed || chapterCount <= 0) return;
    _db.execute(
      'UPDATE library_item SET chapter_count = ? WHERE item_id = ? '
      'AND section = ? AND source_id = ?',
      <Object?>[
        chapterCount,
        rawId(itemId),
        section.id,
        sourceFor(itemId, sourceId),
      ],
    );
  }

  /// 记「已读到第几章」。只前进不回退：回翻旧章节不会让未读角标重新涨起来，
  /// 同时刷新排序时间，让它回到书架最前。
  void markChapterRead(
    String itemId,
    int chapterIndex, {
    DateTime? at,
    String? sourceId,
  }) {
    if (_closed || chapterIndex < 0) return;
    _db.execute(
      'UPDATE library_item SET '
      'read_chapter_index = MAX(read_chapter_index, ?), updated_at = ? '
      'WHERE item_id = ? AND section = ? AND source_id = ?',
      <Object?>[
        chapterIndex,
        (at ?? DateTime.now()).millisecondsSinceEpoch,
        rawId(itemId),
        section.id,
        sourceFor(itemId, sourceId),
      ],
    );
  }

  // ------------------------------------------------------------------ 进度

  /// 阅读进度。没有记录时返回 null。
  ReadingProgress? progress(String itemId, {String? sourceId}) {
    if (_closed) return null;
    final rows = _db.select(
      'SELECT * FROM reading_progress WHERE item_id = ? AND section = ? AND source_id = ?',
      <Object?>[rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
    return rows.isEmpty ? null : _progressFromRow(rows.first);
  }

  Map<String, VideoProgress> videoEpisodes(String itemId, {String? sourceId}) {
    if (_closed) return {};
    final result = <String, VideoProgress>{};
    for (final row in _db.select(
      'SELECT * FROM video_episode_progress WHERE item_id = ? AND section = ? AND source_id = ?',
      [rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    )) {
      final progress = _progressFromRow(row);
      if (progress is VideoProgress) result[progress.chapterId] = progress;
    }
    return result;
  }

  VideoProgress? videoEpisode(
    String itemId,
    String chapterId, {
    String? sourceId,
  }) {
    if (_closed) return null;
    final rows = _db.select(
      'SELECT * FROM video_episode_progress WHERE item_id = ? AND chapter_id = ? AND section = ? AND source_id = ?',
      [rawId(itemId), chapterId, section.id, sourceFor(itemId, sourceId)],
    );
    final progress = rows.isEmpty ? null : _progressFromRow(rows.first);
    return progress is VideoProgress ? progress : null;
  }

  /// 保存阅读进度（同一作品一条，覆盖写）。
  void saveProgress(ReadingProgress progress) {
    if (_closed) return;
    final owner = sourceFor(
      progress.itemId,
      progress.sourceId.isEmpty ? null : progress.sourceId,
    );
    if (owner == null) throw StateError('进度缺少源身份');
    if (_closed) return;
    _requireOwn(progress.section);
    final (position, fraction, chapterLength) = switch (progress) {
      ComicProgress(:final page, :final pageFraction) => (
        page,
        pageFraction,
        0,
      ),
      NovelProgress(:final offset, :final textLength) => (
        offset,
        0.0,
        textLength,
      ),
      VideoProgress(:final position, :final duration) => (
        position.inMilliseconds,
        duration.inMilliseconds.toDouble(),
        0,
      ),
    };
    final kind = switch (progress) {
      NovelProgress() => 'novel',
      ComicProgress() => 'comic',
      VideoProgress() => 'video',
    };
    _db.execute(
      'INSERT INTO reading_progress (item_id, section, source_id, chapter_index, '
      'chapter_id, chapter_title, position, fraction, chapter_length, '
      'progress_kind, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(source_id,item_id) DO UPDATE SET '
      'section = excluded.section, '
      'chapter_index = excluded.chapter_index, '
      'chapter_id = excluded.chapter_id, '
      'chapter_title = excluded.chapter_title, '
      'position = excluded.position, '
      'fraction = excluded.fraction, '
      'chapter_length = excluded.chapter_length, '
      'progress_kind = excluded.progress_kind, '
      'updated_at = excluded.updated_at',
      <Object?>[
        rawId(progress.itemId),
        progress.section.id,
        owner,
        progress.chapterIndex,
        progress.chapterId,
        progress.chapterTitle,
        position,
        fraction,
        chapterLength,
        kind,
        progress.updatedAt.millisecondsSinceEpoch,
      ],
    );
    if (progress is VideoProgress) {
      _db.execute(
        'INSERT OR REPLACE INTO video_episode_progress '
        '(item_id, section, source_id, chapter_index, chapter_id, chapter_title, position, fraction, chapter_length, progress_kind, updated_at) '
        'SELECT item_id, section, source_id, chapter_index, chapter_id, chapter_title, position, fraction, chapter_length, progress_kind, updated_at '
        'FROM reading_progress WHERE item_id = ? AND section = ? AND source_id = ?',
        [rawId(progress.itemId), section.id, owner],
      );
    }
  }

  void clearProgress(String itemId, {String? sourceId}) {
    if (_closed) return;
    _db.execute(
      'DELETE FROM video_episode_progress WHERE item_id = ? AND section = ? AND source_id = ?',
      [rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
    _db.execute(
      'DELETE FROM reading_progress WHERE item_id = ? AND section = ? AND source_id = ?',
      <Object?>[rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
    _db.execute(
      'UPDATE library_item SET read_chapter_index = -1 WHERE item_id = ? AND section = ? AND source_id = ?',
      [rawId(itemId), section.id, sourceFor(itemId, sourceId)],
    );
  }

  // ------------------------------------------------------------------ 设置

  Map<String, String> exportSettings() => {
    for (final row in _db.select('SELECT key, value FROM reading_setting'))
      if (!(row['key'] as String).startsWith('waf.') &&
          !(row['key'] as String).startsWith('rex.widget.') &&
          !(row['key'] as String).startsWith('history.lock'))
        row['key'] as String: row['value'] as String,
  };

  String? setting(String key) {
    if (_closed) return null;
    final rows = _db.select('SELECT value FROM reading_setting WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Station credentials/preferences only. Shelf, progress and app settings survive.
  void clearStationSettings() {
    if (_closed) return;
    _db.execute(
      "DELETE FROM reading_setting WHERE key LIKE 'source.preferences.%' OR key LIKE 'source.runtime.storage.%' OR key LIKE 'waf.cookies.%' OR key LIKE 'waf.ua.%' OR key LIKE 'rex.widget.private.%' OR key LIKE 'rex.widget.params.%' OR key = 'rex.widget.shared'",
    );
    setSetting('search.aggregate.sourceIds', 'null');
  }

  void setSetting(String key, String value) {
    if (_closed) return;
    _db.execute(
      'INSERT INTO reading_setting (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      <Object?>[key, value],
    );
  }

  /// Cloud sync reads rows through this store, never copies a live SQLite file.
  Map<String, Object?> cloudRecords({required bool includeSettings}) {
    final result = <String, Object?>{};
    for (final table in [
      'library_item',
      'reading_progress',
      'video_episode_progress',
    ]) {
      for (final row in _db.select('SELECT * FROM $table WHERE section = ?', [
        section.id,
      ])) {
        result[jsonEncode([section.id, table, cloudIdentity(table, row)])] =
            Map<String, Object?>.from(row);
      }
    }
    for (final entry in exportSettings().entries) {
      if (entry.key == 'favorites.folders' ||
          includeSettings && cloudSettingAllowed(entry.key)) {
        result[jsonEncode([section.id, 'reading_setting', entry.key])] = {
          'key': entry.key,
          'value': entry.value,
        };
      }
    }
    return result;
  }

  static bool cloudSettingAllowed(String key) =>
      !RegExp(
        r'key|token|password|secret|cookie|authorization|waf|lock',
        caseSensitive: false,
      ).hasMatch(key) &&
      (key.startsWith('video.player.') ||
          key.startsWith('comic.') ||
          key.startsWith('speech.') ||
          key.startsWith('favorites.') ||
          key.startsWith('reader.') ||
          key.startsWith('browse.'));

  static String cloudIdentity(String table, Map row) =>
      table == 'video_episode_progress'
      ? 'lume:item:${jsonEncode([row['source_id'], row['item_id'], row['chapter_id']])}'
      : ReadingIdentity.key('${row['source_id']}', '${row['item_id']}');

  /// Upgrade legacy raw-ID cloud records before comparing baselines or merging.
  Map<String, Object?> normalizeCloudRecords(Map<String, Object?> records) {
    final result = <String, Object?>{};
    final owners = <String, Set<String>>{};
    for (final value in records.values) {
      if (value is Map &&
          value['source_id'] is String &&
          value['item_id'] is String) {
        owners
            .putIfAbsent('${value['item_id']}', () => {})
            .add(value['source_id'] as String);
      }
    }
    for (final entry in records.entries) {
      final key = jsonDecode(entry.key);
      if (key is! List ||
          key.length != 3 ||
          key[0] != section.id ||
          key[2] is! String) {
        throw const FormatException('阅读记录身份无效');
      }
      if (key[1] == 'reading_setting') {
        result[entry.key] = entry.value;
        continue;
      }
      final identity = ReadingIdentity.decode(key[2]);
      final row = entry.value == null
          ? null
          : Map<String, Object?>.from(entry.value as Map);
      final item =
          row?['item_id'] as String? ?? identity?[1] ?? key[2] as String;
      final owner =
          row?['source_id'] as String? ??
          identity?[0] ??
          (owners[item]?.length == 1 ? owners[item]!.single : null) ??
          sourceFor(item) ??
          '';
      if (identity != null &&
          row != null &&
          (row['item_id'] != identity[1] ||
              row['source_id'] != null && row['source_id'] != identity[0] ||
              key[1] == 'video_episode_progress' &&
                  (identity.length != 3 || row['chapter_id'] != identity[2]))) {
        throw const FormatException('阅读记录内容与身份不一致');
      }
      if (row != null) row['source_id'] = owner;
      final id = row == null
          ? identity == null
                ? ReadingIdentity.key(owner, item)
                : key[2]
          : cloudIdentity('${key[1]}', row);
      // Legacy raw keys must still agree with the payload before migration.
      if (identity == null && row != null && row['item_id'] != key[2]) {
        throw const FormatException('阅读记录内容与身份不一致');
      }
      result[jsonEncode([section.id, key[1], id])] = row;
    }
    return result;
  }

  void applyCloudRecords(
    Map<String, Object?> records, {
    bool validateOnly = false,
    bool allowAllSettings = false,
  }) {
    const progressColumns = [
      'item_id',
      'section',
      'source_id',
      'chapter_index',
      'chapter_id',
      'chapter_title',
      'position',
      'fraction',
      'chapter_length',
      'progress_kind',
      'updated_at',
    ];
    const columns = {
      'library_item': [
        'item_id',
        'section',
        'source_id',
        'title',
        'cover',
        'subtitle',
        'chapter_count',
        'read_chapter_index',
        'added_at',
        'updated_at',
        'favorite',
      ],
      'reading_progress': progressColumns,
      'video_episode_progress': progressColumns,
      'reading_setting': ['key', 'value'],
    };
    final operations = <(String, List<String>, Map<String, Object?>?)>[];
    for (final entry in normalizeCloudRecords(records).entries) {
      final key = (jsonDecode(entry.key) as List).cast<String>();
      final table = key[1];
      if (!columns.containsKey(table)) {
        throw const FormatException('云端阅读记录类型无效');
      }
      if (table == 'reading_setting' &&
          !allowAllSettings &&
          !cloudSettingAllowed(key[2])) {
        throw const FormatException('云端设置不在允许范围');
      }
      final row = entry.value == null
          ? null
          : Map<String, Object?>.from(entry.value as Map);
      final identity = table == 'reading_setting'
          ? [key[2]]
          : ReadingIdentity.decode(key[2]);
      if (identity == null ||
          (table == 'video_episode_progress'
              ? identity.length != 3
              : table != 'reading_setting' && identity.length != 2)) {
        throw const FormatException('云端身份无效');
      }
      if (row != null) {
        final names = columns[table]!;
        if (row.length != names.length ||
            names.any((n) => !row.containsKey(n)) ||
            row.values.any((v) => v != null && v is! String && v is! num) ||
            row.values.whereType<num>().any((v) => !v.isFinite)) {
          throw const FormatException('云端记录结构不兼容');
        }
        if (table == 'reading_setting') {
          if (row['key'] != key[2] || row['value'] is! String) {
            throw const FormatException('设置格式无效');
          }
        } else {
          if (row['section'] != section.id ||
              row['source_id'] != identity[0] ||
              row['item_id'] != identity[1] ||
              table == 'video_episode_progress' &&
                  row['chapter_id'] != identity[2]) {
            throw const FormatException('云端身份与内容不一致');
          }
          final strings = table == 'library_item'
              ? ['item_id', 'section', 'source_id', 'title']
              : [
                  'item_id',
                  'section',
                  'source_id',
                  'chapter_id',
                  'chapter_title',
                  'progress_kind',
                ];
          final integers = table == 'library_item'
              ? [
                  'chapter_count',
                  'read_chapter_index',
                  'added_at',
                  'updated_at',
                  'favorite',
                ]
              : ['chapter_index', 'position', 'chapter_length', 'updated_at'];
          if (strings.any((n) => row[n] is! String) ||
              integers.any((n) => row[n] is! int) ||
              table == 'library_item' &&
                  (!const [0, 1].contains(row['favorite']) ||
                      [
                        'cover',
                        'subtitle',
                      ].any((n) => row[n] != null && row[n] is! String)) ||
              table != 'library_item' && row['fraction'] is! num) {
            throw const FormatException('云端字段类型不兼容');
          }
        }
      }
      operations.add((table, identity, row));
    }
    if (validateOnly) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final (table, id, row) in operations) {
        if (row == null) {
          if (table == 'reading_setting') {
            _db.execute('DELETE FROM reading_setting WHERE key = ?', id);
          } else {
            _db.execute(
              'DELETE FROM $table WHERE source_id = ? AND item_id = ?${table == 'video_episode_progress' ? ' AND chapter_id = ?' : ''}',
              id,
            );
            if (table == 'reading_progress') {
              _db.execute(
                'DELETE FROM video_episode_progress WHERE source_id = ? AND item_id = ?',
                id,
              );
            }
          }
        } else {
          final names = columns[table]!;
          _db.execute(
            'INSERT OR REPLACE INTO $table (${names.join(',')}) VALUES (${List.filled(names.length, '?').join(',')})',
            [for (final n in names) row[n]],
          );
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------------ 缓存

  /// 图片缓存文件路径。同一 URL 得到同一路径，跨会话复用。
  String imageCacheFile(String url) =>
      p.join(imageCacheDir, '${cacheKey(url)}.img');

  /// 图片缓存的落盘键：URL → 文件名。
  ///
  /// 用 FNV-1a 64 位（掩到 62 位保持正数）而不是加密哈希：无需新依赖，
  /// 确定性、无路径字符，碰撞概率对缓存够用。板块隔离由目录体现，不由键体现。
  static String cacheKey(String url) {
    const mask = 0x3FFFFFFFFFFFFFFF; // 62 位，避开 int64 符号位
    var hash = 0xcbf29ce484222325 & mask;
    for (final byte in utf8.encode(url)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// 当前图片缓存占用（字节）。
  int cacheBytes() {
    final dir = Directory(imageCacheDir);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// 清理图片缓存。用户保存的图片（exports）不在清理范围内。
  void clearCache() {
    final dir = Directory(imageCacheDir);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      try {
        entity.deleteSync(recursive: true);
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
  }

  /// 写出用户保存的图片（长按保存）。同名文件自动加序号，不覆盖既有文件。
  File writeExport(String fileName, Uint8List bytes) {
    final safe = safeName(fileName);
    var target = File(p.join(exportDir, safe));
    var index = 1;
    while (target.existsSync()) {
      target = File(
        p.join(
          exportDir,
          '${p.basenameWithoutExtension(safe)}'
          '_$index${p.extension(safe)}',
        ),
      );
      index++;
    }
    target.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
    return target;
  }

  Future<File> _exportWriting = Future.value(File(''));
  Future<File> writeExportAsync(String fileName, Uint8List bytes) {
    final task = _exportWriting.catchError((Object _) => File('')).then((
      _,
    ) async {
      final safe = safeName(fileName);
      var target = File(p.join(exportDir, safe));
      var index = 1;
      while (await target.exists()) {
        target = File(
          p.join(
            exportDir,
            '${p.basenameWithoutExtension(safe)}_${index++}${p.extension(safe)}',
          ),
        );
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      return target;
    });
    _exportWriting = task;
    return task;
  }

  Future<File> writeDownloadAsync(
    String folder,
    String name,
    Uint8List bytes,
  ) async {
    final target = File(
      p.join(exportDir, safeRelativeDir(folder), safeName(name)),
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
    return target;
  }

  /// 写出批量下载的图片：落在 `exports/<folder>/<fileName>`，**同名直接覆盖**。
  ///
  /// 与 [writeExport] 的两点差别都是为了「下载可以重跑」：
  /// 1. **分目录**（作品 / 章节）——一次下载几十上百张图不会全堆在一个目录里；
  /// 2. **覆盖而不加序号**——重跑一次不会多出一整套 `_1` 副本。
  ///
  /// [folder] 是 `exports/` 之下的相对目录（可含多级），逐段清洗（[safeRelativeDir]）；
  /// 因此调用方可以**预先算出落盘路径**判断「已下载」。
  File writeDownload(String folder, String fileName, Uint8List bytes) {
    final dir = Directory(p.join(exportDir, safeRelativeDir(folder)));
    dir.createSync(recursive: true);
    final target = File(p.join(dir.path, safeName(fileName)));
    target.writeAsBytesSync(bytes, flush: true);
    return target;
  }

  /// 落盘名清洗：路径分隔符与保留字符换成下划线，超长截断。
  ///
  /// 幂等——洗过的名字再洗一次不变，因此调用方用它预算路径是安全的。
  static String safeName(String raw) {
    final trimmed = raw.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    if (cleaned.isEmpty) return 'lume_image.jpg';
    return cleaned.length <= 96 ? cleaned : cleaned.substring(0, 96);
  }

  /// 下载子目录名（单层）：在 [safeName] 之上再去掉首尾的点。
  ///
  /// 首尾的点必须去掉：`..` 会被当成上一级目录，`.` 开头的目录在桌面端是隐藏
  /// 目录——两者都不是下载目录该有的形态。全是点的名字退回 `lume`。
  static String safeFolderName(String raw) {
    final cleaned = safeName(raw).replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    return cleaned.isEmpty ? 'lume' : cleaned;
  }

  /// 下载落盘目录：`exports/` 之下的相对路径，**逐段**清洗后拼起来。
  ///
  /// 逐段清洗而不是整体清洗：整体清洗会把分隔符一起换成下划线，多级目录会被
  /// 压成一层。空段直接丢掉（`a//b` 与 `a/b` 等价），因此 `..` 这类段洗过之后
  /// 要么变成普通名字、要么被丢掉，路径不会跑出导出目录。
  ///
  /// 幂等：洗过的路径再洗一次得到同一个结果。
  static String safeRelativeDir(String raw) {
    final segments = <String>[];
    for (final piece in raw.split(RegExp(r'[\\/]+'))) {
      if (piece.trim().isEmpty) continue;
      segments.add(safeFolderName(piece));
    }
    return segments.isEmpty ? 'lume' : segments.join('/');
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

  static void disposeAll() {
    for (final store in _opened.values.toList(growable: false)) {
      store.dispose();
    }
    _opened.clear();
  }

  // ------------------------------------------------------------------ 内部

  void _requireOwn(Section other) {
    if (other.id != section.id) {
      throw ArgumentError('拒绝跨板块写入阅读库：记录归属「${other.id}」，本库属于「${section.id}」');
    }
  }

  /// 行 → 条目。归属不符或板块 id 非法的行按「不存在」处理并记日志。
  LibraryItem? _itemFromRow(Row row) {
    final item = _tryParse(() => LibraryItem.fromRow(row));
    if (item == null) return null;
    if (item.section.id != section.id) {
      LumeLog.warn(
        '[${section.id}] 拒绝跨板块书架条目: ${item.itemId} 归属「${item.section.id}」',
      );
      return null;
    }
    return item;
  }

  ReadingProgress? _progressFromRow(Row row) {
    final other = sectionFromId(row['section'] as String);
    if (other == null || other.id != section.id) {
      LumeLog.warn(
        '[${section.id}] 拒绝跨板块阅读进度: ${row['item_id']} 归属「${row['section']}」',
      );
      return null;
    }
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(
      row['updated_at'] as int,
    );
    final common = (
      itemId: row['item_id'] as String,
      chapterIndex: row['chapter_index'] as int,
      chapterId: row['chapter_id'] as String,
      chapterTitle: row['chapter_title'] as String,
      updatedAt: updatedAt,
    );
    final progressKind = row['progress_kind'] as String;
    if (progressKind == 'novel') {
      return NovelProgress(
        section: section,
        sourceId: row['source_id'] as String,
        itemId: common.itemId,
        chapterIndex: common.chapterIndex,
        chapterId: common.chapterId,
        chapterTitle: common.chapterTitle,
        updatedAt: updatedAt,
        offset: row['position'] as int,
        textLength: row['chapter_length'] as int,
      );
    }
    final kind =
        sectionFromId(progressKind) ??
        (section == Section.cat ? null : section);
    return switch (kind) {
      Section.comic => ComicProgress(
        section: section,
        itemId: common.itemId,
        sourceId: row['source_id'] as String,
        chapterIndex: common.chapterIndex,
        chapterId: common.chapterId,
        chapterTitle: common.chapterTitle,
        updatedAt: common.updatedAt,
        page: row['position'] as int,
        pageFraction: (row['fraction'] as num).toDouble(),
      ),
      Section.video => VideoProgress(
        section: section,
        itemId: common.itemId,
        sourceId: row['source_id'] as String,
        chapterIndex: common.chapterIndex,
        chapterId: common.chapterId,
        chapterTitle: common.chapterTitle,
        updatedAt: common.updatedAt,
        position: Duration(milliseconds: row['position'] as int),
        // 时长借 fraction 列存（该列在视频口径下不再表示页内比例）。
        duration: Duration(milliseconds: (row['fraction'] as num).round()),
      ),
      // 猫源板块的进度形状尚未定义（站点切换等形态未定），如实返回 null。
      Section.cat || null => null,
    };
  }

  static T? _tryParse<T>(T Function() parse) {
    try {
      return parse();
    } on Object catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return null;
    }
  }
}
