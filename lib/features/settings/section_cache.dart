import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/session/section.dart';
import '../../core/session/section_scope.dart';
import '../../core/util/lume_log.dart';

/// 单个板块的缓存统计。
///
/// 「缓存」＝该板块目录下可再生、可清理的数据（图片缓存与板块缓存目录）；
/// 用户保存的图片（`reading_cache/exports`）只统计、不清理。
class SectionCacheStats {
  const SectionCacheStats({
    required this.section,
    required this.cacheBytes,
    required this.cacheFiles,
    required this.savedBytes,
    required this.savedFiles,
  });

  final Section section;

  /// 可清理的缓存字节数与文件数。
  final int cacheBytes;
  final int cacheFiles;

  /// 用户保存的图片：只展示，不参与清理。
  final int savedBytes;
  final int savedFiles;

  bool get hasCache => cacheBytes > 0;
}

/// 分板块缓存统计与清理。
///
/// 每个板块只看自己目录下的两类路径（都经 [SectionScope.resolve] 校验，
/// 越界即抛错）：
/// - 可清理：`cache/` 与 `reading_cache/images`；
/// - 保留：`reading_cache/exports`（用户长按保存的图片）。
///
/// 因此四个板块的缓存互相独立（宪法第 3 条）：清理一个板块不会碰另一个板块
/// 的任何文件，统计也不会把别的板块算进来。
class SectionCacheService {
  const SectionCacheService();

  /// 缓存根目录名（与阅读底座一致）。
  static const String readingCacheRoot = 'reading_cache';

  /// 四个板块的统计，按 `Section.values` 顺序返回。
  Future<List<SectionCacheStats>> inspectAll() async {
    final stats = <SectionCacheStats>[];
    for (final section in Section.values) {
      stats.add(await inspect(section));
    }
    return stats;
  }

  Future<SectionCacheStats> inspect(Section section) async {
    final scope = await SectionScope.open(section);
    var cacheBytes = 0;
    var cacheFiles = 0;
    for (final dir in _clearableDirs(scope)) {
      final measured = _measure(dir);
      cacheBytes += measured.bytes;
      cacheFiles += measured.files;
    }
    final saved = _measure(_exportDir(scope));
    return SectionCacheStats(
      section: section,
      cacheBytes: cacheBytes,
      cacheFiles: cacheFiles,
      savedBytes: saved.bytes,
      savedFiles: saved.files,
    );
  }

  /// 清理一个板块的缓存（用户保存的图片不动），返回释放的字节数。
  Future<int> clear(Section section) async {
    final scope = await SectionScope.open(section);
    var freed = 0;
    for (final path in _clearableDirs(scope)) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        try {
          freed += _measure(entity.path).bytes;
          entity.deleteSync(recursive: true);
        } catch (error, stackTrace) {
          // 单个文件删不掉不阻断其余清理；原因写进日志，页面按剩余量重算。
          LumeLog.error(error, stackTrace);
        }
      }
    }
    return freed;
  }

  /// 一个板块可清理的目录（都已通过板块作用域校验）。
  List<String> _clearableDirs(SectionScope scope) => <String>[
        // 板块缓存目录（SectionScope 为每个板块准备的标准缓存位）。
        scope.resolve('cache'),
        // 阅读图片缓存（四板块共用同一套阅读底座，但目录各在各的板块下）。
        scope.resolve(p.join(readingCacheRoot, 'images')),
      ];

  /// 用户保存的图片目录（只统计不清理）。
  String _exportDir(SectionScope scope) =>
      scope.resolve(p.join(readingCacheRoot, 'exports'));

  /// 统计一个路径：文件算它自己，目录递归算里面的文件；不存在算 0。
  static ({int bytes, int files}) _measure(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return (bytes: 0, files: 0);
    if (type == FileSystemEntityType.file) {
      return (bytes: File(path).lengthSync(), files: 1);
    }
    var bytes = 0;
    var files = 0;
    for (final entity in Directory(path)
        .listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        bytes += entity.lengthSync();
        files += 1;
      }
    }
    return (bytes: bytes, files: files);
  }
}
