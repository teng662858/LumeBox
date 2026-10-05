import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/settings/section_cache.dart';

/// 缓存策略：容量上限 + 过期天数（文档要求「各板块过期时间、最大容量、缓存策略
/// 独立配置」）。
///
/// 验证：策略解析与文案、过期文件被删、容量超限按最久未访问先删（LRU）、
/// 不限制时不动文件、只碰缓存目录（用户保存的图片绝不删）、按板块独立配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_cache_policy');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 往某板块的图片缓存目录写一个文件（带指定修改时间）。
  Future<File> writeCacheFile(
    Section section,
    String name,
    int bytes, {
    Duration age = Duration.zero,
  }) async {
    final scope = await SectionScope.open(section);
    final dir = Directory(
      scope.resolve(p.join('reading_cache', 'images')),
    )..createSync(recursive: true);
    final file = File(p.join(dir.path, name));
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    if (age > Duration.zero) {
      final time = DateTime.now().subtract(age);
      file.setLastModifiedSync(time);
      // 访问时间也退回去（prune 取 accessed 与 modified 里较晚的那个）。
      await Process.run('touch', <String>['-a', '-d', time.toIso8601String(), file.path]);
    }
    return file;
  }

  group('策略解析与文案', () {
    test('不限制 / 上限 / 过期 的文案', () {
      expect(SectionCachePolicy.unlimited.describe(), '不限制');
      expect(
        const SectionCachePolicy(maxBytes: 100 * 1024 * 1024).describe(),
        '上限 100 MB',
      );
      expect(
        const SectionCachePolicy(maxAgeDays: 7).describe(),
        '7 天过期',
      );
      expect(
        const SectionCachePolicy(maxBytes: 50 * 1024 * 1024, maxAgeDays: 3)
            .describe(),
        '上限 50 MB · 3 天过期',
      );
      expect(SectionCachePolicy.unlimited.hasLimit, isFalse);
    });

    test('JSON 往返与坏数据回退', () {
      const policy = SectionCachePolicy(maxBytes: 12345, maxAgeDays: 9);
      final restored = SectionCachePolicy.fromJson(
        jsonDecode(jsonEncode(policy.toJson())),
      );
      expect(restored, policy);
      expect(SectionCachePolicy.fromJson(null), SectionCachePolicy.unlimited);
      expect(
        SectionCachePolicy.fromJson(<String, Object?>{'maxBytes': 'abc'}),
        const SectionCachePolicy(maxBytes: 0, maxAgeDays: 0),
      );
    });
  });

  group('过期修剪', () {
    test('超过过期天数的文件被删，新的保留', () async {
      const section = Section.video;
      final old = await writeCacheFile(
        section,
        'old.jpg',
        1024,
        age: const Duration(days: 10),
      );
      final fresh = await writeCacheFile(section, 'fresh.jpg', 1024);

      const service = SectionCacheService();
      final result = await service.prune(
        section,
        const SectionCachePolicy(maxAgeDays: 7),
      );

      expect(result.removedFiles, 1, reason: '只删过期的那个');
      expect(result.freedBytes, 1024);
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('不过期（0 天）时一个都不删', () async {
      const section = Section.novel;
      final file = await writeCacheFile(
        section,
        'old.jpg',
        512,
        age: const Duration(days: 999),
      );

      const service = SectionCacheService();
      final result = await service.prune(
        section,
        const SectionCachePolicy(maxBytes: 0, maxAgeDays: 0),
      );
      expect(result.isEmpty, isTrue);
      expect(file.existsSync(), isTrue);
    });
  });

  group('容量上限修剪', () {
    test('超限时按最久未访问先删（LRU），直到降到上限以下', () async {
      const section = Section.comic;
      // 三个 1KB 文件，上限 2KB → 必须删掉最旧的 1 个。
      final oldest = await writeCacheFile(
        section,
        'oldest.jpg',
        1024,
        age: const Duration(days: 3),
      );
      final middle = await writeCacheFile(
        section,
        'middle.jpg',
        1024,
        age: const Duration(days: 2),
      );
      final newest = await writeCacheFile(section, 'newest.jpg', 1024);

      const service = SectionCacheService();
      final result = await service.prune(
        section,
        const SectionCachePolicy(maxBytes: 2048),
      );

      expect(result.removedFiles, 1);
      expect(result.freedBytes, 1024);
      expect(oldest.existsSync(), isFalse, reason: '最久未访问的先删');
      expect(middle.existsSync(), isTrue);
      expect(newest.existsSync(), isTrue);
    });

    test('没超限就不动', () async {
      const section = Section.cat;
      final file = await writeCacheFile(section, 'small.jpg', 100);

      const service = SectionCacheService();
      final result = await service.prune(
        section,
        const SectionCachePolicy(maxBytes: 10 * 1024 * 1024),
      );
      expect(result.isEmpty, isTrue);
      expect(file.existsSync(), isTrue);
    });
  });

  group('边界：只碰缓存，不碰用户数据', () {
    test('用户保存的图片（exports）绝不被策略删除', () async {
      const section = Section.comic;
      final scope = await SectionScope.open(section);
      final exports = Directory(scope.resolve(p.join('reading_cache', 'exports')))
        ..createSync(recursive: true);
      final saved = File(p.join(exports.path, 'my-saved.jpg'))
        ..writeAsBytesSync(List<int>.filled(2048, 0));
      // 把保存时间设得很旧，确保它不是靠「新」而幸免。
      saved.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 100)),
      );
      await writeCacheFile(section, 'cache.jpg', 4096);

      const service = SectionCacheService();
      // 极端策略：上限 0 字节 + 1 天过期 —— 缓存该被清空，但保存的图片必须留着。
      await service.prune(
        section,
        const SectionCachePolicy(maxBytes: 1, maxAgeDays: 1),
      );

      expect(
        saved.existsSync(),
        isTrue,
        reason: '用户保存的图片不在清理范围（文档明确要求）',
      );
    });

    test('板块隔离：修剪一个板块不影响另一个', () async {
      final videoFile = await writeCacheFile(Section.video, 'v.jpg', 4096);
      final novelFile = await writeCacheFile(Section.novel, 'n.jpg', 4096);

      const service = SectionCacheService();
      await service.prune(
        Section.video,
        const SectionCachePolicy(maxBytes: 1),
      );

      expect(videoFile.existsSync(), isFalse, reason: '视频板块被清空');
      expect(
        novelFile.existsSync(),
        isTrue,
        reason: '小说板块的缓存不该被牵连（宪法第 3 条：板块隔离）',
      );
    });
  });

  group('策略持久化（按板块独立）', () {
    test('存读往返：每个板块各存各的', () async {
      final video = await ReadingLibrary.open(Section.video);
      final novel = await ReadingLibrary.open(Section.novel);

      CachePolicyStore(video).save(
        Section.video,
        const SectionCachePolicy(maxBytes: 100 * 1024 * 1024, maxAgeDays: 7),
      );
      CachePolicyStore(novel).save(
        Section.novel,
        const SectionCachePolicy(maxAgeDays: 3),
      );

      expect(
        CachePolicyStore(video).load(Section.video),
        const SectionCachePolicy(maxBytes: 100 * 1024 * 1024, maxAgeDays: 7),
      );
      expect(
        CachePolicyStore(novel).load(Section.novel),
        const SectionCachePolicy(maxAgeDays: 3),
        reason: '两个板块的策略互不干扰',
      );
      // 没配过的板块是「不限制」。
      expect(
        CachePolicyStore(video).load(Section.comic),
        SectionCachePolicy.unlimited,
      );
    });
  });
}
