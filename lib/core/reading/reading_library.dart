import 'dart:io';
import 'dart:typed_data';

import '../session/section.dart';
import 'reading_models.dart';
import 'reading_store.dart';

/// 阅读体系门面：书架与阅读进度。四个阅读页面（两个书架、两个阅读器）
/// 共用这一套语义，页面不认识 sqlite、表结构与缓存目录。
///
/// 一个实例只服务一个板块，实例之间不共享任何状态；跨板块写入在 [ReadingStore]
/// 入口被拒绝。方法保持同步——sqlite 本地读写在毫秒级，页面不必为书架和进度
/// 引入 FutureBuilder；只有 [open] 是异步的（需要先拿到板块目录）。
class ReadingLibrary {
  ReadingLibrary._(this._store);

  final ReadingStore _store;

  static final Map<String, ReadingLibrary> _opened = <String, ReadingLibrary>{};

  /// 打开（必要时创建）板块阅读门面。同一板块重复调用返回同一实例。
  static Future<ReadingLibrary> open(Section section) async {
    final existing = _opened[section.id];
    if (existing != null) return existing;
    final library = ReadingLibrary._(await ReadingStore.open(section));
    _opened[section.id] = library;
    return library;
  }

  /// 已打开的门面；未打开时返回 null（页面正常路径用 [open]）。
  static ReadingLibrary? find(Section section) => _opened[section.id];

  Section get section => _store.section;

  /// 本板块图片缓存目录（可清理）。
  String get imageCacheDir => _store.imageCacheDir;

  /// 本板块用户保存图片目录（不随缓存清理）。
  String get exportDir => _store.exportDir;

  // ------------------------------------------------------------------ 书架

  /// 书架条目，最近加入或阅读的在前。
  List<LibraryItem> shelf() => _store.shelf();

  LibraryItem? item(String itemId) => _store.item(itemId);

  bool onShelf(String itemId) => _store.item(itemId) != null;

  /// 加入书架。已在架时只补全信息（封面、简介、章节数），阅读记录不受影响。
  LibraryItem shelve({
    required String sourceId,
    required String itemId,
    required String title,
    String? cover,
    String? subtitle,
    int chapterCount = 0,
  }) {
    final existing = _store.item(itemId);
    final now = DateTime.now();
    final item = LibraryItem(
      section: section,
      itemId: itemId,
      sourceId: sourceId,
      title: title,
      cover: cover,
      subtitle: subtitle,
      chapterCount: chapterCount > 0 ? chapterCount : existing?.chapterCount ?? 0,
      readChapterIndex: existing?.readChapterIndex ?? -1,
      addedAt: existing?.addedAt ?? now,
      updatedAt: now,
    );
    _store.upsertItem(item);
    return _store.item(itemId) ?? item;
  }

  void unshelve(String itemId) {
    _store.removeItem(itemId);
    _store.clearProgress(itemId);
  }

  /// 同步章节总数（详情页拿到章节列表后调用）。为 0 时忽略，避免图源偶发
  /// 少返章节把角标算错。
  void syncChapters(String itemId, int chapterCount) {
    if (chapterCount <= 0) return;
    final existing = _store.item(itemId);
    if (existing == null) return;
    _store.setChapterCount(itemId, chapterCount);
    // 章节数变了，排序时间不动——同步目录不算一次阅读。
  }

  // ------------------------------------------------------------------ 进度

  ReadingProgress? progress(String itemId) => _store.progress(itemId);

  /// 已保存的漫画进度；进度形状不符（例如库被改坏）时返回 null。
  ComicProgress? comicProgress(String itemId) {
    final saved = _store.progress(itemId);
    return saved is ComicProgress ? saved : null;
  }

  /// 已保存的小说进度；形状不符时返回 null。
  NovelProgress? novelProgress(String itemId) {
    final saved = _store.progress(itemId);
    return saved is NovelProgress ? saved : null;
  }

  /// 已保存的视频进度；形状不符时返回 null。
  VideoProgress? videoProgress(String itemId) {
    final saved = _store.progress(itemId);
    return saved is VideoProgress ? saved : null;
  }

  /// 「继续观看」列表：有播放记录的作品，按最近播放倒序。
  ///
  /// 只取有进度的条目——没有播放记录的作品不该出现在继续观看里。
  /// 已播完（≥95%）的也保留：用户可能想重看，标「已看完」比直接藏掉更好。
  List<LibraryItem> continueWatching({int limit = 20}) {
    final items = <LibraryItem>[];
    for (final item in _store.shelf()) {
      final progress = _store.progress(item.itemId);
      if (progress is! VideoProgress) continue;
      items.add(item);
      if (items.length >= limit) break;
    }
    return List<LibraryItem>.unmodifiable(items);
  }

  /// 保存阅读进度，并同步书架上的「已读到第几章」。
  ///
  /// 两件事必须一起做：未读角标的口径来自书架，位置来自进度表；
  /// 分开写迟早会不一致。进度写入前的类型由调用方按板块选定。
  void saveProgress(ReadingProgress progress) {
    _store.saveProgress(progress);
    _store.markChapterRead(
      progress.itemId,
      progress.chapterIndex,
      at: progress.updatedAt,
    );
  }

  // ------------------------------------------------------------------ 设置

  String? setting(String key) => _store.setting(key);

  void setSetting(String key, String value) => _store.setSetting(key, value);

  // ------------------------------------------------------------------ 缓存

  int cacheBytes() => _store.cacheBytes();

  /// 清空图片缓存（用户保存的图片不动）。
  void clearCache() => _store.clearCache();

  /// 保存图片（阅读器长按保存）。返回落盘文件。
  File saveImage(String fileName, Uint8List bytes) =>
      _store.writeExport(fileName, bytes);

  /// 保存批量下载的图片（按作品 / 章节分目录，同名覆盖）。返回落盘文件。
  ///
  /// 目录与文件名由调用方先经 [ReadingStore.safeFolderName] / [ReadingStore.safeName]
  /// 算好再传进来——下载器要按同一套名字判断「这张已经下过了」，
  /// 两边必须用同一份清洗结果（清洗是幂等的，重复调用不会漂移）。
  File saveDownload(String folder, String fileName, Uint8List bytes) =>
      _store.writeDownload(folder, fileName, bytes);

  // ------------------------------------------------------------------ 生命周期

  /// 释放本板块的阅读库（板块页面退出时调用）。
  ///
  /// 释放的是 sqlite 句柄与内存缓存：数据都已在磁盘上，下次 [open] 会重新打开
  /// 同一个库文件，书架与进度照旧。释放后仍持有旧引用的页面不会因此崩——
  /// [ReadingStore] 对已关闭库的读写一律静默降级。可重复调用。
  static void close(Section section) => _opened.remove(section.id)?.dispose();

  void dispose() {
    _opened.removeWhere((_, value) => identical(value, this));
    _store.dispose();
  }

  static void disposeAll() {
    for (final library in _opened.values.toList(growable: false)) {
      library.dispose();
    }
    _opened.clear();
  }
}
