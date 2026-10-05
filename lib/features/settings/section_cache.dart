import 'dart:convert';
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

/// 缓存策略：容量上限 + 过期天数（按板块配置）。
///
/// 文档要求「各板块过期时间、最大容量、缓存策略独立配置」。两者都是**上限式**
/// 约束，不是「到点就清空」：
/// - **容量上限**：超过即按「最久未访问」逐个删到上限以下（LRU）；
/// - **过期天数**：超过天数没被访问的文件在清理时一并删除。
///
/// 0 表示不限制（默认）：不配置就不动用户的缓存，避免误删。
class SectionCachePolicy {
  const SectionCachePolicy({this.maxBytes = 0, this.maxAgeDays = 0});

  /// 容量上限（字节）；0 = 不限制。
  final int maxBytes;

  /// 过期天数；0 = 不过期。
  final int maxAgeDays;

  static const SectionCachePolicy unlimited = SectionCachePolicy();

  bool get hasLimit => maxBytes > 0 || maxAgeDays > 0;

  /// 用户可选的容量档位（MB）；0 表示不限制。
  static const List<int> capacityOptionsMb = <int>[0, 50, 100, 200, 500, 1024];

  /// 用户可选的过期档位（天）；0 表示不过期。
  static const List<int> ageOptionsDays = <int>[0, 3, 7, 15, 30];

  SectionCachePolicy copyWith({int? maxBytes, int? maxAgeDays}) =>
      SectionCachePolicy(
        maxBytes: maxBytes ?? this.maxBytes,
        maxAgeDays: maxAgeDays ?? this.maxAgeDays,
      );

  Map<String, Object?> toJson() =>
      <String, Object?>{'maxBytes': maxBytes, 'maxAgeDays': maxAgeDays};

  static SectionCachePolicy fromJson(Object? json) {
    if (json is! Map) return unlimited;
    return SectionCachePolicy(
      maxBytes: _int(json['maxBytes']),
      maxAgeDays: _int(json['maxAgeDays']),
    );
  }

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// 策略文案（设置页展示）。
  String describe() {
    if (!hasLimit) return '不限制';
    final parts = <String>[];
    if (maxBytes > 0) {
      parts.add('上限 ${(maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB');
    }
    if (maxAgeDays > 0) parts.add('$maxAgeDays 天过期');
    return parts.join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is SectionCachePolicy &&
      other.maxBytes == maxBytes &&
      other.maxAgeDays == maxAgeDays;

  @override
  int get hashCode => Object.hash(maxBytes, maxAgeDays);
}

/// 一次策略执行的结论。
class CachePruneResult {
  const CachePruneResult({required this.removedFiles, required this.freedBytes});

  final int removedFiles;
  final int freedBytes;

  bool get isEmpty => removedFiles == 0;

  String describe() {
    if (removedFiles == 0) return '无需清理';
    final mb = freedBytes / (1024 * 1024);
    return '清理 $removedFiles 个文件 · 释放 ${mb.toStringAsFixed(1)} MB';
  }
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

  /// 按策略修剪一个板块的缓存：先删过期文件，再按容量上限做 LRU 回收。
  ///
  /// 只碰可清理目录；用户保存的图片与书架、进度数据都不在范围内。
  Future<CachePruneResult> prune(
    Section section,
    SectionCachePolicy policy,
  ) async {
    if (!policy.hasLimit) {
      return const CachePruneResult(removedFiles: 0, freedBytes: 0);
    }
    final scope = await SectionScope.open(section);
    final files = <({File file, DateTime accessed, int bytes})>[];

    for (final path in _clearableDirs(scope)) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = entity.statSync();
          files.add((
            file: entity,
            // 访问时间不可靠（部分平台不更新）时退回修改时间：
            // 缓存文件写入即访问，两者在缓存场景下等价。
            accessed: stat.accessed.isAfter(stat.modified)
                ? stat.accessed
                : stat.modified,
            bytes: stat.size,
          ));
        } catch (error, stackTrace) {
          LumeLog.error(error, stackTrace);
        }
      }
    }

    var removedFiles = 0;
    var freedBytes = 0;
    var remainingBytes = files.fold<int>(0, (sum, item) => sum + item.bytes);

    // 1) 过期：超过 maxAgeDays 未访问的一律删。
    if (policy.maxAgeDays > 0) {
      final deadline = DateTime.now().subtract(Duration(days: policy.maxAgeDays));
      for (final item in files.toList(growable: false)) {
        if (item.accessed.isAfter(deadline)) continue;
        if (_delete(item.file)) {
          removedFiles++;
          freedBytes += item.bytes;
          remainingBytes -= item.bytes;
          files.remove(item);
        }
      }
    }

    // 2) 容量：仍超上限时按最久未访问先删（LRU），直到降到上限以下。
    if (policy.maxBytes > 0 && remainingBytes > policy.maxBytes) {
      files.sort((a, b) => a.accessed.compareTo(b.accessed));
      for (final item in files) {
        if (remainingBytes <= policy.maxBytes) break;
        if (_delete(item.file)) {
          removedFiles++;
          freedBytes += item.bytes;
          remainingBytes -= item.bytes;
        }
      }
    }

    return CachePruneResult(removedFiles: removedFiles, freedBytes: freedBytes);
  }

  /// 删一个文件（顺带清掉空目录），失败只记日志。
  static bool _delete(File file) {
    try {
      file.deleteSync();
      final parent = file.parent;
      if (parent.existsSync() && parent.listSync(followLinks: false).isEmpty) {
        parent.deleteSync();
      }
      return true;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
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

/// 缓存策略的持久化：落在**每个板块自己的**阅读库里（`reading_setting` 表）。
///
/// 刻意按板块存：文档要求「各板块过期时间、最大容量、缓存策略独立配置」，
/// 存一份全局的就没法独立了。
class CachePolicyStore {
  const CachePolicyStore(this._library);

  static const String _keyPrefix = 'cache.policy.';

  /// 由板块阅读库读写（[ReadingLibrary] 的 setting / setSetting）。
  final dynamic _library;

  static String keyFor(Section section) => '$_keyPrefix${section.id}';

  /// 读取某板块的策略；没配过就是「不限制」。
  SectionCachePolicy load(Section section) {
    final raw = _library.setting(keyFor(section)) as String?;
    if (raw == null || raw.trim().isEmpty) return SectionCachePolicy.unlimited;
    try {
      return SectionCachePolicy.fromJson(jsonDecode(raw));
    } catch (error) {
      LumeLog.warn('缓存策略解析失败，按不限制处理: $error');
      return SectionCachePolicy.unlimited;
    }
  }

  /// 写回某板块的策略。
  void save(Section section, SectionCachePolicy policy) {
    _library.setSetting(keyFor(section), jsonEncode(policy.toJson()));
  }
}
