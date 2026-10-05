import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/settings/cache_pruner.dart';
import 'package:lume_box/features/settings/section_cache.dart';

/// 缓存策略的后台执行器。
///
/// 为什么需要它：策略此前只在保存策略 / 进缓存页时执行，用户设了上限却从不打开
/// 缓存页，缓存就会一直涨。这里验证「后台自动生效」这条链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_pruner');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<File> cacheFile(Section section, String name, int bytes) async {
    final scope = await SectionScope.open(section);
    final dir = Directory(scope.resolve(p.join('reading_cache', 'images')))
      ..createSync(recursive: true);
    final file = File(p.join(dir.path, name))..writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  test('没有任何策略时不干活（不遍历磁盘）', () async {
    final pruner = CachePruner(
      policyLoader: (section) async => SectionCachePolicy.unlimited,
    );
    addTearDown(pruner.dispose);
    final file = await cacheFile(Section.video, 'a.jpg', 4096);

    final pruned = await pruner.pruneNow();

    expect(pruned, isFalse);
    expect(file.existsSync(), isTrue, reason: '不限制 = 不动用户缓存');
  });

  test('配了策略就按策略修剪', () async {
    final pruner = CachePruner(
      policyLoader: (section) async => section == Section.video
          ? const SectionCachePolicy(maxBytes: 1)
          : SectionCachePolicy.unlimited,
    );
    addTearDown(pruner.dispose);
    final videoFile = await cacheFile(Section.video, 'a.jpg', 4096);
    final novelFile = await cacheFile(Section.novel, 'b.jpg', 4096);

    final pruned = await pruner.pruneNow();

    expect(pruned, isTrue);
    expect(videoFile.existsSync(), isFalse, reason: '视频板块配了上限，被修剪');
    expect(
      novelFile.existsSync(),
      isTrue,
      reason: '小说板块没配策略，不受影响（按板块独立）',
    );
  });

  test('策略读取失败按「不限制」处理（宁可不修剪，也不误删）', () async {
    final pruner = CachePruner(
      policyLoader: (section) async => throw StateError('库打不开'),
    );
    addTearDown(pruner.dispose);
    // 加载器抛错时 pruneNow 会向上抛（由调用方捕获），此处验证它不误删。
    final file = await cacheFile(Section.video, 'a.jpg', 4096);
    await expectLater(pruner.pruneNow(), throwsA(isA<StateError>()));
    expect(file.existsSync(), isTrue);
  });

  test('start 之后 isRunning 为真；dispose 后停表', () async {
    final pruner = CachePruner(
      initialDelay: const Duration(hours: 1),
      policyLoader: (section) async => SectionCachePolicy.unlimited,
    );
    expect(pruner.isRunning, isFalse);
    pruner.start();
    expect(pruner.isRunning, isTrue);
    // 重复 start 不叠加定时器。
    pruner.start();
    expect(pruner.isRunning, isTrue);
    pruner.dispose();
    expect(pruner.isRunning, isFalse);
  });

  test('dispose 后不再执行修剪', () async {
    final pruner = CachePruner(
      policyLoader: (section) async => const SectionCachePolicy(maxBytes: 1),
    );
    final file = await cacheFile(Section.video, 'a.jpg', 4096);
    pruner.dispose();

    final pruned = await pruner.pruneNow();

    expect(pruned, isFalse, reason: '已销毁就不再动磁盘');
    expect(file.existsSync(), isTrue);
  });
}
