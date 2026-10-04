import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/settings/section_cache.dart';

/// 分板块缓存统计与清理的验证（对着真实文件断言）。
///
/// 核心两条：统计口径正确（可清理的缓存与用户保存的图片分开），
/// 以及**板块隔离**——清理一个板块不动其他板块的任何文件（宪法第 3 条）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  /// 在板块目录下写一个指定大小的文件。
  void writeFile(String relative, int bytes) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
  }

  int sizeOf(String relative) =>
      File('${root.path}/$relative').existsSync()
          ? File('${root.path}/$relative').lengthSync()
          : 0;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_cache');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 漫画：图片缓存 + 用户保存的图片；小说：图片缓存；猫源：板块缓存目录。
    writeFile('sections/comic/reading_cache/images/a.img', 100);
    writeFile('sections/comic/reading_cache/exports/saved.png', 50);
    writeFile('sections/novel/reading_cache/images/b.img', 200);
    writeFile('sections/cat/cache/c.tmp', 30);
  });

  tearDown(() async {
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  const service = SectionCacheService();

  test('统计：分板块独立计数，缓存与已保存图片分开', () async {
    final stats = await service.inspectAll();

    expect(stats.map((item) => item.section), Section.values);
    final bySection = <Section, SectionCacheStats>{
      for (final item in stats) item.section: item,
    };

    expect(bySection[Section.comic]!.cacheBytes, 100);
    expect(bySection[Section.comic]!.cacheFiles, 1);
    expect(bySection[Section.comic]!.savedBytes, 50);
    expect(bySection[Section.comic]!.savedFiles, 1);

    expect(bySection[Section.novel]!.cacheBytes, 200);
    expect(bySection[Section.novel]!.savedBytes, 0);

    expect(bySection[Section.cat]!.cacheBytes, 30);

    // 没有缓存数据的板块就是 0，不是失败。
    expect(bySection[Section.video]!.cacheBytes, 0);
    expect(bySection[Section.video]!.hasCache, isFalse);
  });

  test('清理：只清所选板块，其他板块与用户保存的图片都不动', () async {
    final freed = await service.clear(Section.comic);

    expect(freed, 100);
    expect(sizeOf('sections/comic/reading_cache/images/a.img'), 0);
    expect(
      sizeOf('sections/comic/reading_cache/exports/saved.png'),
      50,
      reason: '用户保存的图片不参与清理',
    );
    expect(
      sizeOf('sections/novel/reading_cache/images/b.img'),
      200,
      reason: '小说板块的缓存不受漫画清理影响',
    );
    expect(
      sizeOf('sections/cat/cache/c.tmp'),
      30,
      reason: '猫源板块的缓存不受漫画清理影响',
    );

    final afterComic = await service.inspect(Section.comic);
    expect(afterComic.cacheBytes, 0);
    expect(afterComic.savedBytes, 50);

    // 其他板块的统计值也没有被算错。
    final novel = await service.inspect(Section.novel);
    expect(novel.cacheBytes, 200);
  });

  test('清理空板块：返回 0，不报错', () async {
    expect(await service.clear(Section.video), 0);
  });

  test('清理后仍可继续统计：状态自洽', () async {
    await service.clear(Section.novel);
    await service.clear(Section.cat);

    final bySection = <Section, SectionCacheStats>{
      for (final item in await service.inspectAll()) item.section: item,
    };
    expect(bySection[Section.novel]!.cacheBytes, 0);
    expect(bySection[Section.cat]!.cacheBytes, 0);
    expect(bySection[Section.video]!.cacheBytes, 0);
    expect(
      bySection[Section.comic]!.cacheBytes,
      100,
      reason: '没清漫画，它的缓存仍在',
    );
    expect(sizeOf('sections/comic/reading_cache/images/a.img'), 100);
  });
}
