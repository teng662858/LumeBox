import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 视频播放进度记忆（文档要求「视频记忆到集数 + 播放时间点」）。
///
/// 验证：播到一半退出后再点同一作品，从上次位置继续；换集从头播；播完不自动
/// 跳结尾；播放记录与续看统一在右上角 ⏱️ 的抽屉里（首页的「继续观看」区块
/// 已按用户要求删除，本文件同时钉住「它不会再回来」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-progress-model-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await SectionScope.open(Section.video);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  group('进度存储口径', () {
    test('集数 + 时间点往返：同一作品覆盖写', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.shelve(sourceId: 'src', itemId: 'v1', title: '作品');

      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'v1',
          chapterIndex: 2,
          chapterId: 'e3',
          chapterTitle: '第 3 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 40),
        ),
      );
      var saved = library.videoProgress('v1')!;
      expect(saved.chapterIndex, 2);
      expect(saved.chapterId, 'e3');
      expect(saved.position, const Duration(minutes: 5));
      expect(saved.duration, const Duration(minutes: 40));
      expect(saved.describe(), '第 3 集 · 5:00 / 40:00');

      // 同一作品再存一次：覆盖，不新增记录。
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'v1',
          chapterIndex: 2,
          chapterId: 'e3',
          chapterTitle: '第 3 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 18),
          duration: const Duration(minutes: 40),
        ),
      );
      saved = library.videoProgress('v1')!;
      expect(saved.position, const Duration(minutes: 18));
      expect(library.continueWatching().length, 1, reason: '同一作品只有一条记录');
    });

    test('播放只写历史：不产生收藏，显式收藏后不被播放冲掉', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.recordHistoryItem(sourceId: 's', itemId: 'played', title: '只看过');
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'played',
          chapterIndex: 0,
          chapterId: 'e1',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 45),
        ),
      );

      expect(library.onShelf('played'), isFalse, reason: '播放不等于收藏');
      expect(library.shelf(), isEmpty, reason: '收藏页不该有只播过的作品');
      expect(
        library.continueReading().map((entry) => entry.item.itemId),
        contains('played'),
        reason: '历史里必须有它',
      );

      // 用户明确收藏后再播放：收藏位保持不变。
      library.shelve(sourceId: 's', itemId: 'played', title: '只看过');
      expect(library.onShelf('played'), isTrue);
      library.recordHistoryItem(
        sourceId: 's',
        itemId: 'played',
        title: '只看过（改名）',
      );
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'played',
          chapterIndex: 0,
          chapterId: 'e1',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 8),
          duration: const Duration(minutes: 45),
        ),
      );
      expect(library.onShelf('played'), isTrue, reason: '播放不能把显式收藏冲掉');
      expect(library.item('played')!.title, '只看过（改名）');
    });

    test('已看完判定与比例', () {
      VideoProgress at(double ratio) => VideoProgress(
        section: Section.video,
        itemId: 'v',
        chapterIndex: 0,
        chapterId: 'c',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: Duration(seconds: (100 * ratio).round()),
        duration: const Duration(seconds: 100),
      );

      expect(at(0.5).isFinished, isFalse);
      expect(at(0.5).ratio, closeTo(0.5, 0.01));
      expect(at(0.94).isFinished, isFalse);
      expect(at(0.95).isFinished, isTrue, reason: '≥95% 视为看完');
      expect(at(1.0).isFinished, isTrue);
      // 时长未知：不算看完，比例 0（不凭空说人家看完了）。
      final unknown = VideoProgress(
        section: Section.video,
        itemId: 'v',
        chapterIndex: 0,
        chapterId: 'c',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 3),
      );
      expect(unknown.isFinished, isFalse);
      expect(unknown.ratio, 0);
      expect(unknown.describe(), '第 1 集 · 3:00');
    });

    test('切换剧集：时间点归零', () {
      final progress = VideoProgress(
        section: Section.video,
        itemId: 'v',
        chapterIndex: 0,
        chapterId: 'e1',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 45),
      );
      final next = progress.withChapter(
        chapterIndex: 1,
        chapterId: 'e2',
        chapterTitle: '第 2 集',
      );
      expect(next.chapterIndex, 1);
      expect(next.position, Duration.zero);
      expect(next.duration, Duration.zero, reason: '新一集时长未知，等播放器给');
    });

    test('板块隔离：视频进度不出现在其他板块，也不与阅读进度混用', () async {
      final video = await ReadingLibrary.open(Section.video);
      final novel = await ReadingLibrary.open(Section.cat);

      video.shelve(sourceId: 's', itemId: 'shared-id', title: '视频作品');
      video.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'shared-id',
          chapterIndex: 0,
          chapterId: 'e1',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 10),
        ),
      );

      expect(video.videoProgress('shared-id'), isNotNull);
      expect(
        novel.progress('shared-id'),
        isNull,
        reason: '同一个 id 在小说板块不该看到视频的进度',
      );
      expect(novel.continueWatching(), isEmpty);
      // 小说板块查视频进度：形状不符，如实返回 null。
      expect(novel.videoProgress('shared-id'), isNull);
    });

    test('继续观看按最近播放倒序，且只含有进度的作品', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.shelve(sourceId: 's', itemId: 'old', title: '先看的');
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'old',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
          position: const Duration(minutes: 1),
        ),
      );
      library.shelve(sourceId: 's', itemId: 'new', title: '后看的');
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'new',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 2),
        ),
      );
      // 只在书架、没有播放记录的作品不该出现。
      library.shelve(sourceId: 's', itemId: 'never', title: '没看过');

      final list = library.continueWatching();
      expect(list.map((item) => item.itemId), <String>['new', 'old']);
    });
  });
}
