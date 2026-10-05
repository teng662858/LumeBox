import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/session/section.dart';

/// 按板块隔离的内存缓存：只做内存级、无过期淘汰、可按板块清空。
///
/// 隔离是硬约束：一个板块一格，清一个板块不碰另一个板块的任何条目；
/// 同一图源 id 在不同板块互不可见（图源 id 只在所属板块内唯一）。
void main() {
  final cache = SectionMemoryCache.instance;

  setUp(cache.clearAll);
  tearDown(cache.clearAll);

  test('四板块各成一格：同一图源 id 在不同板块互不可见', () {
    cache.write(Section.novel, 'demo', 'categories', <String>['小说分类']);
    cache.write(Section.comic, 'demo', 'categories', <String>['漫画分类']);

    expect(cache.read(Section.novel, 'demo', 'categories'), <String>['小说分类']);
    expect(cache.read(Section.comic, 'demo', 'categories'), <String>['漫画分类']);
    expect(cache.read(Section.video, 'demo', 'categories'), isNull);
    expect(cache.read(Section.cat, 'demo', 'categories'), isNull);
  });

  test('清空一个板块不动其他板块', () {
    for (final section in Section.values) {
      cache.write(section, 'demo', 'chapters|1', <String>[section.id]);
    }

    expect(cache.clear(Section.comic), 1);
    expect(cache.read(Section.comic, 'demo', 'chapters|1'), isNull);
    for (final section in <Section>[
      Section.novel,
      Section.video,
      Section.cat,
    ]) {
      expect(cache.read(section, 'demo', 'chapters|1'), <String>[section.id]);
    }
    expect(cache.usageOf(Section.comic).isEmpty, isTrue);
    expect(cache.usageOf(Section.novel).entries, 1);
  });

  test('removeSource 只清该图源：其他图源、其他板块都不误伤', () {
    cache.write(Section.video, 'a', 'categories', <String>['a']);
    cache.write(Section.video, 'a', 'detail|1', <String>['a-detail']);
    cache.write(Section.video, 'b', 'categories', <String>['b']);
    // 同名图源 id 在别的板块：前缀清理不能跨板块误伤。
    cache.write(Section.novel, 'a', 'categories', <String>['novel-a']);

    expect(cache.removeSource(Section.video, 'a'), 2);
    expect(cache.read(Section.video, 'a', 'categories'), isNull);
    expect(cache.read(Section.video, 'a', 'detail|1'), isNull);
    expect(cache.read(Section.video, 'b', 'categories'), <String>['b']);
    expect(
      cache.read(Section.novel, 'a', 'categories'),
      <String>['novel-a'],
      reason: 'novel 的 a 不是 video 的 a',
    );
  });

  test('占用统计：条目数与估算字节（字符串按 UTF-16 码元 ×2）', () {
    expect(cache.usageOf(Section.cat).isEmpty, isTrue);
    expect(cache.usageOf(Section.cat).describe(), '空');

    // 列表 8 字节开销 + 字符串 'abcd'（4 码元 ×2）= 16。
    cache.write(Section.cat, 'a', 'categories', <String>['abcd']);
    expect(cache.usageOf(Section.cat).entries, 1);
    expect(cache.usageOf(Section.cat).bytes, 16);
    expect(cache.usageOf(Section.cat).describe(), '1 项 · 16 B');
  });

  test('clearAll 清空四个板块（测试隔离与进程级重置用）', () {
    for (final section in Section.values) {
      cache.write(section, 'demo', 'categories', <String>[section.id]);
    }
    cache.clearAll();
    for (final section in Section.values) {
      expect(cache.usageOf(section).isEmpty, isTrue);
    }
  });

  test('未知板块格子里没有条目：读空返回 null，清空返回 0', () {
    cache.write(Section.novel, 'demo', 'categories', <String>['x']);
    expect(cache.read(Section.cat, 'demo', 'categories'), isNull);
    expect(cache.clear(Section.cat), 0);
    expect(cache.read(Section.novel, 'demo', 'categories'), <String>['x']);
  });
}
