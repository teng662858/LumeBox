import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'reading_models.dart';

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
/// 缓存目录同样独占：`sections/<id>/reading_cache/`，其下 `images/` 放图片缓存
/// （可清理），`exports/` 放用户长按保存的图片（不参与清理）。小说大章节文本
/// 与排版结果只在内存里缓存，因此不需要额外的磁盘目录。
class ReadingStore {
  ReadingStore._(this.section, this._scope, this._db);

  /// 库内自证键：本库属于哪个板块。
  static const String _ownerKey = 'owner_section';

  static const int _schemaVersion = 1;

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

  static final Map<String, ReadingStore> _opened = <String, ReadingStore>{};

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
    final scope = await SectionScope.open(section);
    final store = ReadingStore._(section, scope, sqlite3.open(_readingDbPath(scope)));
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
    if (version < _schemaVersion) {
      _db.execute('PRAGMA user_version = $_schemaVersion');
    }
    _claimSection();
  }

  /// 库文件自证：库内声明所属板块，缺失则落记号，不符即拒绝打开。
  void _claimSection() {
    final owner = setting(_ownerKey);
    if (owner == null) {
      setSetting(_ownerKey, section.id);
      return;
    }
    if (owner != section.id) {
      throw StateError(
        '阅读库归属不符：库中标记为「$owner」，不能以「${section.id}」打开',
      );
    }
  }

  // ------------------------------------------------------------------ 书架

  /// 书架条目，最近加入或阅读的在前。
  List<LibraryItem> shelf() {
    if (_closed) return const <LibraryItem>[];
    final rows = _db.select(
      'SELECT * FROM library_item WHERE section = ? ORDER BY updated_at DESC',
      <Object?>[section.id],
    );
    final items = <LibraryItem>[];
    for (final row in rows) {
      final item = _itemFromRow(row);
      if (item != null) items.add(item);
    }
    return List<LibraryItem>.unmodifiable(items);
  }

  /// 单条书架条目。不存在或归属不符时返回 null。
  LibraryItem? item(String itemId) {
    if (_closed) return null;
    final rows = _db.select(
      'SELECT * FROM library_item WHERE item_id = ?',
      <Object?>[itemId],
    );
    return rows.isEmpty ? null : _itemFromRow(rows.first);
  }

  /// 写入（或更新）书架条目。
  ///
  /// 更新语义刻意保守：章节总数只在拿到非零值时覆盖（图源偶发少返章节时
  /// 不缩水，未读角标才不会乱跳），已读章节序号与加入时间都不被触碰。
  void upsertItem(LibraryItem item) {
    if (_closed) return;
    _requireOwn(item.section);
    _db.execute(
      'INSERT INTO library_item (item_id, section, source_id, title, cover, '
      'subtitle, chapter_count, read_chapter_index, added_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(item_id) DO UPDATE SET '
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

  void removeItem(String itemId) {
    if (_closed) return;
    _db.execute(
      'DELETE FROM library_item WHERE item_id = ? AND section = ?',
      <Object?>[itemId, section.id],
    );
  }

  /// 同步章节总数（详情页拿到章节列表时调用）。
  void setChapterCount(String itemId, int chapterCount) {
    if (_closed || chapterCount <= 0) return;
    _db.execute(
      'UPDATE library_item SET chapter_count = ? WHERE item_id = ? '
      'AND section = ?',
      <Object?>[chapterCount, itemId, section.id],
    );
  }

  /// 记「已读到第几章」。只前进不回退：回翻旧章节不会让未读角标重新涨起来，
  /// 同时刷新排序时间，让它回到书架最前。
  void markChapterRead(
    String itemId,
    int chapterIndex, {
    DateTime? at,
  }) {
    if (_closed || chapterIndex < 0) return;
    _db.execute(
      'UPDATE library_item SET '
      'read_chapter_index = MAX(read_chapter_index, ?), updated_at = ? '
      'WHERE item_id = ? AND section = ?',
      <Object?>[
        chapterIndex,
        (at ?? DateTime.now()).millisecondsSinceEpoch,
        itemId,
        section.id,
      ],
    );
  }

  // ------------------------------------------------------------------ 进度

  /// 阅读进度。没有记录时返回 null。
  ReadingProgress? progress(String itemId) {
    if (_closed) return null;
    final rows = _db.select(
      'SELECT * FROM reading_progress WHERE item_id = ? AND section = ?',
      <Object?>[itemId, section.id],
    );
    return rows.isEmpty ? null : _progressFromRow(rows.first);
  }

  /// 保存阅读进度（同一作品一条，覆盖写）。
  void saveProgress(ReadingProgress progress) {
    if (_closed) return;
    _requireOwn(progress.section);
    // position 的含义按形状而定：漫画是页序号、小说是字符偏移、视频是播放毫秒。
    final (position, fraction, chapterLength) = switch (progress) {
      ComicProgress(:final page, :final pageFraction) => (page, pageFraction, 0),
      NovelProgress(:final charOffset, :final chapterLength) =>
        (charOffset, 0.0, chapterLength),
      VideoProgress(:final position, :final duration) => (
          position.inMilliseconds,
          duration.inMilliseconds.toDouble(),
          0,
        ),
    };
    _db.execute(
      'INSERT INTO reading_progress (item_id, section, chapter_index, '
      'chapter_id, chapter_title, position, fraction, chapter_length, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(item_id) DO UPDATE SET '
      'section = excluded.section, '
      'chapter_index = excluded.chapter_index, '
      'chapter_id = excluded.chapter_id, '
      'chapter_title = excluded.chapter_title, '
      'position = excluded.position, '
      'fraction = excluded.fraction, '
      'chapter_length = excluded.chapter_length, '
      'updated_at = excluded.updated_at',
      <Object?>[
        progress.itemId,
        progress.section.id,
        progress.chapterIndex,
        progress.chapterId,
        progress.chapterTitle,
        position,
        fraction,
        chapterLength,
        progress.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  void clearProgress(String itemId) {
    if (_closed) return;
    _db.execute(
      'DELETE FROM reading_progress WHERE item_id = ? AND section = ?',
      <Object?>[itemId, section.id],
    );
  }

  // ------------------------------------------------------------------ 设置

  String? setting(String key) {
    if (_closed) return null;
    final rows =
        _db.select('SELECT value FROM reading_setting WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) {
    if (_closed) return;
    _db.execute(
      'INSERT INTO reading_setting (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      <Object?>[key, value],
    );
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
    final safe = _safeFileName(fileName);
    var target = File(p.join(exportDir, safe));
    var index = 1;
    while (target.existsSync()) {
      target = File(p.join(exportDir, '${p.basenameWithoutExtension(safe)}'
          '_$index${p.extension(safe)}'));
      index++;
    }
    target.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
    return target;
  }

  static String _safeFileName(String raw) {
    final trimmed = raw.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    if (cleaned.isEmpty) return 'lume_image.jpg';
    return cleaned.length <= 96 ? cleaned : cleaned.substring(0, 96);
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
      throw ArgumentError(
        '拒绝跨板块写入阅读库：记录归属「${other.id}」，本库属于「${section.id}」',
      );
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
    final updatedAt =
        DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int);
    final common = (
      itemId: row['item_id'] as String,
      chapterIndex: row['chapter_index'] as int,
      chapterId: row['chapter_id'] as String,
      chapterTitle: row['chapter_title'] as String,
      updatedAt: updatedAt,
    );
    // 进度形状由板块决定：漫画存页位置，小说存字符偏移。
    return switch (section) {
      Section.comic => ComicProgress(
          section: section,
          itemId: common.itemId,
          chapterIndex: common.chapterIndex,
          chapterId: common.chapterId,
          chapterTitle: common.chapterTitle,
          updatedAt: common.updatedAt,
          page: row['position'] as int,
          pageFraction: (row['fraction'] as num).toDouble(),
        ),
      Section.novel => NovelProgress(
          section: section,
          itemId: common.itemId,
          chapterIndex: common.chapterIndex,
          chapterId: common.chapterId,
          chapterTitle: common.chapterTitle,
          updatedAt: common.updatedAt,
          charOffset: row['position'] as int,
          chapterLength: row['chapter_length'] as int,
        ),
      Section.video => VideoProgress(
          section: section,
          itemId: common.itemId,
          chapterIndex: common.chapterIndex,
          chapterId: common.chapterId,
          chapterTitle: common.chapterTitle,
          updatedAt: common.updatedAt,
          position: Duration(milliseconds: row['position'] as int),
          // 时长借 fraction 列存（该列在视频口径下不再表示页内比例）。
          duration: Duration(
            milliseconds: (row['fraction'] as num).round(),
          ),
        ),
      // 猫源板块的进度形状尚未定义（站点切换等形态未定），如实返回 null。
      Section.cat => null,
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
