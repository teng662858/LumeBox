import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';

/// 批量下载的范围。
enum ComicDownloadScope {
  /// 整部作品的章节。
  all('全部章节'),

  /// 阅读进度之后的章节（没有进度时等于全部）。
  unread('未读章节'),

  /// 只下当前在读的那一章。
  current('仅当前章');

  const ComicDownloadScope(this.label);

  final String label;

  /// 该范围覆盖的章节下标（正序，升序）。
  ///
  /// [readChapterIndex] 与 [currentIndex] 都是正序下标；越界的值在这里夹回区间内，
  /// 因此图源给出的章节数变动（详情页刚刷新过）也不会算出非法下标。
  List<int> indices({
    required int chapterCount,
    int? readChapterIndex,
    int? currentIndex,
  }) {
    if (chapterCount <= 0) return const <int>[];
    switch (this) {
      case ComicDownloadScope.all:
        return <int>[for (var index = 0; index < chapterCount; index++) index];
      case ComicDownloadScope.unread:
        final read = readChapterIndex;
        if (read == null) {
          return <int>[
            for (var index = 0; index < chapterCount; index++) index,
          ];
        }
        final first = (read + 1).clamp(0, chapterCount);
        return <int>[
          for (var index = first; index < chapterCount; index++) index,
        ];
      case ComicDownloadScope.current:
        final current = (currentIndex ?? 0).clamp(0, chapterCount - 1);
        return <int>[current];
    }
  }
}

/// 下载运行状态。
enum ComicDownloadStatus { idle, running, done, cancelled }

/// 一次批量下载的进度快照（不可变，交给 UI 渲染）。
class ComicDownloadProgress {
  const ComicDownloadProgress({
    this.status = ComicDownloadStatus.idle,
    this.chapterTotal = 0,
    this.chapterDone = 0,
    this.chapterFailed = 0,
    this.currentChapterTitle = '',
    this.currentImageDone = 0,
    this.currentImageTotal = 0,
    this.imageSaved = 0,
    this.imageSkipped = 0,
    this.destination = '',
    this.failures = const <String>[],
  });

  final ComicDownloadStatus status;

  /// 本次要下的章节总数 / 已下完数 / 失败数。
  final int chapterTotal;
  final int chapterDone;
  final int chapterFailed;

  /// 正在下载的章节标题与它的图片进度。
  final String currentChapterTitle;
  final int currentImageDone;
  final int currentImageTotal;

  /// 本次新写入的图片数 / 因已存在而跳过的图片数。
  final int imageSaved;
  final int imageSkipped;

  /// 落盘目录（导出目录内的作品目录），完成提示里展示与复制。
  final String destination;

  /// 失败原因（每章最多一条），按发生顺序。
  final List<String> failures;

  bool get running => status == ComicDownloadStatus.running;

  bool get finished =>
      status == ComicDownloadStatus.done ||
      status == ComicDownloadStatus.cancelled;

  /// 总进度（已下完章节 + 当前章的图片进度）：进度条用。
  ///
  /// 只看章节数的话，下一章几十张图的过程里进度条一动不动；把章内图片折进来，
  /// 进度才是连续走的。
  double get fraction {
    if (chapterTotal == 0) return 0;
    final within =
        currentImageTotal == 0 ? 0.0 : currentImageDone / currentImageTotal;
    return ((chapterDone + within) / chapterTotal).clamp(0.0, 1.0);
  }

  ComicDownloadProgress copyWith({
    ComicDownloadStatus? status,
    int? chapterTotal,
    int? chapterDone,
    int? chapterFailed,
    String? currentChapterTitle,
    int? currentImageDone,
    int? currentImageTotal,
    int? imageSaved,
    int? imageSkipped,
    String? destination,
    List<String>? failures,
  }) {
    return ComicDownloadProgress(
      status: status ?? this.status,
      chapterTotal: chapterTotal ?? this.chapterTotal,
      chapterDone: chapterDone ?? this.chapterDone,
      chapterFailed: chapterFailed ?? this.chapterFailed,
      currentChapterTitle: currentChapterTitle ?? this.currentChapterTitle,
      currentImageDone: currentImageDone ?? this.currentImageDone,
      currentImageTotal: currentImageTotal ?? this.currentImageTotal,
      imageSaved: imageSaved ?? this.imageSaved,
      imageSkipped: imageSkipped ?? this.imageSkipped,
      destination: destination ?? this.destination,
      failures: failures ?? this.failures,
    );
  }
}

/// 单张图片的下载结果。
enum _ImageOutcome { saved, skipped, failed, aborted }

/// 章节图片批量下载器。
///
/// 只做一件事：把选中章节的图片逐张写进本板块的导出目录
/// （`exports/<作品>/<章节>/`）。三条约束：
///
/// 1. **不碰阅读数据**——只写文件，不改书架、进度、书签，也不动图源与沙箱；
/// 2. **可重跑**——落盘路径由章节序号与图片序号确定，已存在的图片直接跳过，
///    因此中途取消 / 离开页面后重进再点一次，接着下剩下的（不产生副本）；
/// 3. **不阻断浏览**——下载在后台推进，页面照常滚动、进阅读器；章节内图片按
///    [maxConcurrentImages] 并发取，实际发送仍受全局网络队列的并发约束。
///
/// 字节来源是注入的 [fetch]（正式路径接图片管线的 `fetch`），
/// 因此下载器的全部行为都能在测试里用确定性数据驱动。
class ComicDownloader extends ChangeNotifier {
  ComicDownloader({
    required this.dataSource,
    required this.itemId,
    required this.works,
    required this.library,
    required this.fetch,
    this.maxConcurrentImages = 4,
  });

  final DataSource dataSource;

  final String itemId;

  /// 作品标题（导出目录名与失败提示都用它）。为空时退回 [itemId]。
  final String works;

  final ReadingLibrary library;

  /// 取字节。返回 null 表示这一张失败（请求失败、超时等）。
  final Future<Uint8List?> Function(String url) fetch;

  /// 章节内同时取图的张数上限。
  final int maxConcurrentImages;

  ComicDownloadProgress _progress = const ComicDownloadProgress();

  ComicDownloadProgress get progress => _progress;

  bool _cancelled = false;
  bool _disposed = false;

  /// 作品目录名（导出目录之内的单层目录名，清洗过）。
  String get worksFolder =>
      ReadingStore.safeFolderName(works.trim().isEmpty ? itemId : works);

  /// 作品目录的绝对路径。
  String get worksDir => p.join(library.exportDir, worksFolder);

  /// 某一章的落盘目录（导出目录之内的相对路径）。
  ///
  /// 只分两层：作品一层、章节一层。章节标题里的分隔符按普通字符清洗掉
  /// （不当作目录层级），因此图源标题里带 `/` 也不会把目录拉深。
  /// 与 [_one] 判断「这张已下过」用的是同一个函数——算出来的路径与写下去的
  /// 路径必然一致。
  String chapterFolder(int index, String title) => p.join(
        worksFolder,
        ReadingStore.safeFolderName('${_number(index)}_$title'),
      );

  /// 开始下载。[indices] 为正序章节下标，[chapters] 为详情页当前的章节列表。
  ///
  /// 正在运行时重复调用直接忽略（一次只跑一个批次）；返回的 Future 在整批
  /// 结束（下完 / 取消）后完成，测试与「完成后再做点什么」的调用方可以 await 它。
  Future<void> start({
    required List<SourceChapter> chapters,
    required List<int> indices,
  }) async {
    if (_progress.running || _disposed) return;
    final planned = <int>[
      for (final index in indices)
        if (index >= 0 && index < chapters.length) index,
    ];
    _cancelled = false;
    _progress = ComicDownloadProgress(
      status: ComicDownloadStatus.running,
      chapterTotal: planned.length,
      destination: worksDir,
    );
    _notify();
    for (final index in planned) {
      if (_cancelled || _disposed) break;
      await _downloadChapter(chapters[index], index);
    }
    _progress = _progress.copyWith(
      status: _cancelled
          ? ComicDownloadStatus.cancelled
          : ComicDownloadStatus.done,
      currentChapterTitle: '',
      currentImageDone: 0,
      currentImageTotal: 0,
    );
    _notify();
  }

  /// 要求停下：当前这一张取完后不再继续（已完成的部分留在磁盘上）。
  void cancel() {
    if (!_progress.running) return;
    _cancelled = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    super.dispose();
  }

  // ------------------------------------------------------------------ 内部

  Future<void> _downloadChapter(SourceChapter chapter, int index) async {
    final label = _chapterLabel(index, chapter.title);
    _progress = _progress.copyWith(
      currentChapterTitle: chapter.title,
      currentImageDone: 0,
      currentImageTotal: 0,
    );
    _notify();
    List<String> urls;
    try {
      final content = await dataSource.content(itemId: itemId, chapterId: chapter.id);
      urls = content is ImageContent ? content.images : const <String>[];
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (_cancelled || _disposed) return;
      _fail('$label：章节内容获取失败');
      return;
    }
    if (_cancelled || _disposed) return;
    if (urls.isEmpty) {
      _fail('$label：该章没有图片内容');
      return;
    }
    final folder = chapterFolder(index, chapter.title);
    _progress = _progress.copyWith(currentImageTotal: urls.length);
    _notify();
    final failed =
        await _downloadImages(urls: urls, folder: folder, label: label);
    if (_cancelled || _disposed) return;
    if (failed > 0) {
      _fail('$label：$failed 张图片未能取到');
      return;
    }
    _progress = _progress.copyWith(chapterDone: _progress.chapterDone + 1);
    _notify();
  }

  /// 章节内图片并发下载（[maxConcurrentImages] 个 worker 抢一个游标）。
  /// 返回本章失败的图片张数。
  Future<int> _downloadImages({
    required List<String> urls,
    required String folder,
    required String label,
  }) async {
    var cursor = 0;
    var failed = 0;
    Future<void> worker() async {
      while (!_cancelled && !_disposed) {
        final index = cursor++;
        if (index >= urls.length) return;
        final outcome = await _one(urls[index], index, folder);
        if (outcome == _ImageOutcome.aborted) return;
        if (outcome == _ImageOutcome.failed) {
          failed++;
        } else {
          _progress = _progress.copyWith(
            currentImageDone: _progress.currentImageDone + 1,
          );
          _notify();
        }
      }
    }

    final workers = maxConcurrentImages < 1 ? 1 : maxConcurrentImages;
    final count = urls.length < workers ? urls.length : workers;
    await Future.wait(<Future<void>>[for (var i = 0; i < count; i++) worker()]);
    return failed;
  }

  /// 取一张并落盘。已存在（非空）的图片直接跳过。
  Future<_ImageOutcome> _one(String url, int index, String folder) async {
    try {
      final fileName = comicImageFileName(url, index);
      final file = File(p.join(library.exportDir, folder, fileName));
      if (file.existsSync() && file.lengthSync() > 0) {
        _progress =
            _progress.copyWith(imageSkipped: _progress.imageSkipped + 1);
        return _ImageOutcome.skipped;
      }
      final bytes = await fetch(url);
      // 取消或页面已关闭时不要把「没取到」记成失败——是这一批不下了。
      if (_cancelled || _disposed) return _ImageOutcome.aborted;
      if (bytes == null || bytes.isEmpty) return _ImageOutcome.failed;
      library.saveDownload(folder, fileName, bytes);
      _progress = _progress.copyWith(imageSaved: _progress.imageSaved + 1);
      return _ImageOutcome.saved;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return _ImageOutcome.failed;
    }
  }

  void _fail(String message) {
    _progress = _progress.copyWith(
      chapterFailed: _progress.chapterFailed + 1,
      failures: <String>[..._progress.failures, message],
    );
    _notify();
  }

  static String _chapterLabel(int index, String title) =>
      '第 ${index + 1} 章「$title」';

  static String _number(int index) => (index + 1).toString().padLeft(3, '0');

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}

/// 章节图片的落盘文件名：三位序号 + 原扩展名。
///
/// 用序号而不是原始文件名，是为了让目录内的文件按阅读顺序自然排序——图床给的
/// 文件名常常是一串哈希，按名字排等于随机顺序。扩展名只在**认得**的时候保留
/// （见 [_imageExtensions]）：脚本类后缀（`.jsp` / `.php`）与无扩展名的图床
/// 一律按 `.jpg` 落盘，导出目录里不会出现一堆看不出是什么的文件。
String comicImageFileName(String url, int index) {
  final path = Uri.tryParse(url.trim())?.path ?? '';
  final extension = p.extension(p.basename(path)).toLowerCase();
  final safe = _imageExtensions.contains(extension) ? extension : '.jpg';
  return '${(index + 1).toString().padLeft(3, '0')}$safe';
}

/// 认得出来的图片扩展名；不在表内的一律按 `.jpg`。
const Set<String> _imageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.avif',
  '.heic',
  '.jfif',
  '.jxl',
  '.tif',
  '.tiff',
};
