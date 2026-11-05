import 'reading_identity.dart';

import 'package:flutter/foundation.dart';

import '../media/media_library.dart';

import 'dart:io';

import '../session/privacy_settings.dart';

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

  bool _disposed = false;

  /// 书架 / 进度 / 收藏任一写入后 +1。
  ///
  /// 历史抽屉正在打开时监听它并重建：播放页退出后记录落库，不必切一次 Tab
  /// 才看见（用户口径：打开就应该是新的）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final ValueNotifier<int> settingsRevision = ValueNotifier<int>(0);
  String? lastSettingKey;

  void _touch() {
    if (!_disposed) revision.value++;
  }

  static final Map<String, ReadingLibrary> _opened = <String, ReadingLibrary>{};
  static final Map<String, Future<ReadingLibrary>> _opening = {};
  static final _closePending = <String>{};

  /// 打开（必要时创建）板块阅读门面。同一板块重复调用返回同一实例。
  static Future<ReadingLibrary> open(Section section) async {
    _closePending.remove(section.id);
    final existing = _opened[section.id];
    if (existing != null) return existing;
    return _opening.putIfAbsent(
      section.id,
      () => _open(section).whenComplete(() {
        _opening.remove(section.id);
      }),
    );
  }

  static Future<ReadingLibrary> _open(Section section) async {
    final library = ReadingLibrary._(await ReadingStore.open(section));
    _opened[section.id] = library;
    if (_closePending.remove(section.id)) library.dispose();
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
  List<LibraryItem> shelf() => _store
      .shelf()
      .where(
        (item) =>
            PrivacySettings.instance.allowsSource(item.sourceId, item.title) &&
            MediaLibrary.instance.visibleAtOrigin(
              section,
              item.sourceId,
              item.itemId,
            ),
      )
      .toList();

  LibraryItem? item(String itemId, {String? sourceId}) =>
      _store.item(itemId, sourceId: sourceId);

  /// Resolves old raw-ID preferences only when the current library has one owner.
  String itemSettingKey(String prefix, String id) {
    final entry = item(id);
    final canonical = entry?.identity ?? id;
    final raw = ReadingIdentity.decode(canonical)?[1] ?? id;
    final legacy = setting('$prefix$raw');
    if (canonical != raw &&
        setting('$prefix$canonical') == null &&
        legacy != null &&
        item(raw)?.identity == canonical) {
      setSetting('$prefix$canonical', legacy);
      setSetting('$prefix$raw', '');
    }
    return '$prefix$canonical';
  }

  bool onShelf(String itemId, {String? sourceId}) =>
      _store.isFavorite(itemId, sourceId: sourceId);

  /// 收藏列表（`favorite = 1`）。
  ///
  /// 收藏页、书架页**只能**走这里：历史行虽然也在 `library_item` 表里，但
  /// `favorite = 0`，不能出现在收藏列表。查询条件在 [ReadingStore.shelf] 里
  /// 固定为 `favorite = 1`，这里再留一个有语义的入口，避免调用方拿错查询。
  List<LibraryItem> favorites() => shelf();

  /// 历史列表：有进度的记录 + 只看过详情、还没开始读的记录。
  ///
  /// 与 [continueReading] 的区别只在「没有进度」的行：历史抽屉需要让
  /// 「点进去看过」也留下记录；收藏页不读这个，收藏了但没读的条目仍只在
  /// 收藏页出现（`favorite = 1` 且无进度 → 不算历史）。
  List<LibraryItem> history({int limit = 500}) {
    final items = <LibraryItem>[];
    for (final item in _store.historyItems()) {
      if (!PrivacySettings.instance.allowsSource(item.sourceId, item.title) ||
          !MediaLibrary.instance.visibleAtOrigin(
            section,
            item.sourceId,
            item.itemId,
          )) {
        continue;
      }
      items.add(item);
      if (items.length >= limit) break;
    }
    return List<LibraryItem>.unmodifiable(items);
  }

  void removeFavorite(String itemId, {String? sourceId}) {
    _store.removeFavorite(itemId, sourceId: sourceId);
    _touch();
  }

  void removeHistory(String itemId, {String? sourceId}) {
    final wasFavorite = _store.isFavorite(itemId, sourceId: sourceId);
    _store.clearProgress(itemId, sourceId: sourceId);
    // 只是历史行（没有收藏）时连元数据一起删掉；否则删了进度、条目还在，
    // 下一次 history() 会把它当成「看过详情但没开始」继续显示。
    if (!wasFavorite) _store.removeItem(itemId, sourceId: sourceId);
    _touch();
  }

  /// Includes hidden/history-only rows, without the UI's 500-entry limit.
  int clearHistory() {
    final items = _store.shelf(includeHistoryOnly: true);
    var count = 0;
    for (final item in items) {
      final favorite = _store.isFavorite(item.itemId, sourceId: item.sourceId);
      if (!favorite ||
          _store.progress(item.itemId, sourceId: item.sourceId) != null) {
        count++;
      }
      _store.clearProgress(item.itemId, sourceId: item.sourceId);
      if (!favorite) _store.removeItem(item.itemId, sourceId: item.sourceId);
    }
    _touch();
    return count;
  }

  /// 加入书架。已在架时只补全信息（封面、简介、章节数），阅读记录不受影响。
  LibraryItem shelve({
    required String sourceId,
    required String itemId,
    required String title,
    String? cover,
    String? subtitle,
    int chapterCount = 0,
  }) {
    final existing = _store.item(itemId, sourceId: sourceId);
    final now = DateTime.now();
    final item = LibraryItem(
      section: section,
      itemId: itemId,
      sourceId: sourceId,
      title: title,
      cover: cover,
      subtitle: subtitle,
      chapterCount: chapterCount > 0
          ? chapterCount
          : existing?.chapterCount ?? 0,
      readChapterIndex: existing?.readChapterIndex ?? -1,
      addedAt: existing?.addedAt ?? now,
      updatedAt: now,
    );
    _store.upsertItem(item);
    _touch();
    return _store.item(itemId, sourceId: sourceId) ?? item;
  }

  /// 记录播放 / 阅读 / 查看详情所需的元数据，但**绝不加入收藏**。
  ///
  /// 新行走 `favorite = 0`，已有行保留原收藏状态；收藏只能由用户点
  /// [shelve]（心形 / 加入书架）触发。播放器、阅读器、四个板块的详情页都
  /// 必须走这里，不能再误用 [shelve]。
  ///
  /// 无痕模式下不写历史；显式收藏仍由 [shelve] 负责，不受这里影响。
  void recordHistoryItem({
    required String sourceId,
    required String itemId,
    required String title,
    String? cover,
    String? subtitle,
    int chapterCount = 0,
  }) {
    if (setting('history.incognito') == 'true') return;
    final existing = _store.item(itemId, sourceId: sourceId);
    final now = DateTime.now();
    _store.ensureHistoryItem(
      LibraryItem(
        section: section,
        itemId: itemId,
        sourceId: sourceId,
        title: title,
        cover: cover,
        subtitle: subtitle,
        chapterCount: chapterCount > 0
            ? chapterCount
            : existing?.chapterCount ?? 0,
        readChapterIndex: existing?.readChapterIndex ?? -1,
        addedAt: existing?.addedAt ?? now,
        updatedAt: now,
      ),
    );
    _touch();
  }

  /// 从阅读器 / 播放器 / 详情页返回时主动通知一次。
  ///
  /// `saveProgress` / `recordHistoryItem` 已经会 `_touch`，但「详情页返回」
  /// 这种没有新进度的路径也要让历史抽屉重新取数；调用方在 `await push`
  /// 之后调它即可。
  void refresh() => _touch();

  void unshelve(String itemId, {String? sourceId}) {
    _store.removeItem(itemId, sourceId: sourceId);
    _store.clearProgress(itemId, sourceId: sourceId);
    _touch();
  }

  /// 同步章节总数（详情页拿到章节列表后调用）。为 0 时忽略，避免图源偶发
  /// 少返章节把角标算错。
  void syncChapters(String itemId, int chapterCount, {String? sourceId}) {
    if (chapterCount <= 0) return;
    final existing = _store.item(itemId, sourceId: sourceId);
    if (existing == null) return;
    _store.setChapterCount(itemId, chapterCount, sourceId: sourceId);
    _touch();
    // 章节数变了，排序时间不动——同步目录不算一次阅读。
  }

  // ------------------------------------------------------------------ 进度

  ReadingProgress? progress(String itemId, {String? sourceId}) =>
      _store.progress(itemId, sourceId: sourceId);

  /// 已保存的漫画进度；进度形状不符（例如库被改坏）时返回 null。
  ComicProgress? comicProgress(String itemId, {String? sourceId}) {
    final saved = _store.progress(itemId, sourceId: sourceId);
    return saved is ComicProgress ? saved : null;
  }

  /// 已保存的视频进度；形状不符时返回 null。
  VideoProgress? videoProgress(String itemId, {String? sourceId}) {
    final saved = _store.progress(itemId, sourceId: sourceId);
    return saved is VideoProgress ? saved : null;
  }

  Map<String, VideoProgress> videoEpisodeProgresses(
    String itemId, {
    String? sourceId,
  }) => _store.videoEpisodes(itemId, sourceId: sourceId);
  VideoProgress? videoEpisodeProgress(
    String itemId,
    String chapterId, {
    String? sourceId,
  }) => _store.videoEpisode(itemId, chapterId, sourceId: sourceId);

  /// 「继续观看」列表：有播放记录的作品，按最近播放倒序。
  ///
  /// 只取有进度的条目——没有播放记录的作品不该出现在继续观看里。
  /// 已播完（≥95%）的也保留：用户可能想重看，标「已看完」比直接藏掉更好。
  List<LibraryItem> continueWatching({int limit = 20}) {
    final items = <LibraryItem>[];
    for (final item in _store.shelf(includeHistoryOnly: true)) {
      if (!PrivacySettings.instance.allowsSource(item.sourceId, item.title) ||
          !MediaLibrary.instance.visibleAtOrigin(
            section,
            item.sourceId,
            item.itemId,
          )) {
        continue;
      }
      final progress = _store.progress(item.itemId, sourceId: item.sourceId);
      if (progress is! VideoProgress) continue;
      items.add(item);
      if (items.length >= limit) break;
    }
    return List<LibraryItem>.unmodifiable(items);
  }

  /// 本板块最近的阅读记录（**任何进度形状**：漫画 / 视频），按更新时间倒序。
  ///
  /// 与 [continueWatching] 的区别只有「要不要筛视频进度」：历史抽屉与追更日历都
  /// 要跨形状地看「最近在看什么」，因此这里不带形状过滤；文档形状的取舍由调用方
  List<({LibraryItem item, ReadingProgress progress})> continueReading({
    int limit = 50,
  }) {
    final entries = <({LibraryItem item, ReadingProgress progress})>[];
    for (final item in _store.shelf(includeHistoryOnly: true)) {
      if (!PrivacySettings.instance.allowsSource(item.sourceId, item.title) ||
          !MediaLibrary.instance.visibleAtOrigin(
            section,
            item.sourceId,
            item.itemId,
          )) {
        continue;
      }
      final progress = _store.progress(item.itemId, sourceId: item.sourceId);
      if (progress == null) continue;
      entries.add((item: item, progress: progress));
      if (entries.length >= limit) break;
    }
    return List<({LibraryItem item, ReadingProgress progress})>.unmodifiable(
      entries,
    );
  }

  /// 保存阅读进度，并同步书架上的「已读到第几章」。
  ///
  /// 两件事必须一起做：未读角标的口径来自书架，位置来自进度表；
  /// 分开写迟早会不一致。进度写入前的类型由调用方按板块选定。
  void saveProgress(ReadingProgress progress) {
    if (setting('history.incognito') == 'true') return;
    _store.saveProgress(progress);
    _store.markChapterRead(
      progress.itemId,
      progress.chapterIndex,
      at: progress.updatedAt,
      sourceId: progress.sourceId.isEmpty ? null : progress.sourceId,
    );
    _touch();
  }

  // ------------------------------------------------------------------ 设置

  String? setting(String key) => _store.setting(key);

  Map<String, String> exportSettings() => _store.exportSettings();

  void setSetting(String key, String value) {
    if (_store.setting(key) == value) return;
    _store.setSetting(key, value);
    lastSettingKey = key;
    if (!_disposed) settingsRevision.value++;
  }

  void clearStationSettings() => _store.clearStationSettings();

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

  Future<File> saveImageAsync(String name, Uint8List bytes) =>
      _store.writeExportAsync(name, bytes);
  Future<File> saveDownloadAsync(String folder, String name, Uint8List bytes) =>
      _store.writeDownloadAsync(folder, name, bytes);

  // ------------------------------------------------------------------ 生命周期

  /// 释放本板块的阅读库（板块页面退出时调用）。
  ///
  /// 释放的是 sqlite 句柄与内存缓存：数据都已在磁盘上，下次 [open] 会重新打开
  /// 同一个库文件，书架与进度照旧。释放后仍持有旧引用的页面不会因此崩——
  /// [ReadingStore] 对已关闭库的读写一律静默降级。可重复调用。
  static void close(Section section) {
    final library = _opened.remove(section.id);
    if (library != null) {
      library.dispose();
    } else if (_opening.containsKey(section.id)) {
      _closePending.add(section.id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _opened.removeWhere((_, value) => identical(value, this));
    revision.dispose();
    settingsRevision.dispose();
    _store.dispose();
  }

  static void disposeAll() {
    _closePending.addAll(_opening.keys);
    for (final library in _opened.values.toList(growable: false)) {
      library.dispose();
    }
    _opened.clear();
  }
}
