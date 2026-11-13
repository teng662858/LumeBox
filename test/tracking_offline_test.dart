import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/experience/reading_offline.dart';
import 'package:lume_box/features/experience/tracking_service.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

class GrowingNovel extends FakeReadingDataSource {
  GrowingNovel() : super(section: Section.comic);
  int count = 2, calls = 0;
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => [
    for (var i = 0; i < count; i++)
      SourceChapter(id: '$i', title: '第${i + 1}章'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    calls++;
    return TextContent('正文 $chapterId');
  }
}

class SplitVideo extends FakeReadingDataSource {
  SplitVideo() : super(section: Section.video);
  final episodes = [
    const SourceChapter(id: 'part1', title: '第3集（上）'),
    const SourceChapter(id: 'full', title: '第3集'),
  ];
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => episodes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late GrowingNovel source;
  final center = ContentCenter.instance;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume-tracking-offline');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    AppPreferences.instance.file = null;
    AppPreferences.instance.experience = {};
    await SectionScope.open(Section.comic);
    library = await ReadingLibrary.open(Section.comic);
    source = GrowingNovel();
    library.shelve(sourceId: source.id, itemId: 'book', title: '小说');
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  test('旧版追更记录迁移已有上篇，之后新增下篇只提醒一次', () async {
    final video = SplitVideo();
    final lib = await ReadingLibrary.open(Section.video);
    final ref = ContentRef(Section.video, video.id, 'show', '剧集');
    lib.shelve(sourceId: video.id, itemId: 'show', title: '剧集');
    center.setTrackingState(ref, 'active');
    center.put('baselines', {ref.key: ['1:3']});
    final tracker = TrackingService(
      managerFor: (_) => FakeSourceManager(opened: {video.id: video}),
      wait: () async {},
    );
    Future<int> check() async {
      center.put('checked.${ref.key}', DateTime(2000).toIso8601String());
      final report = await tracker.check(libraries: [lib]);
      expect(report.success, 1);
      return report.newChapters;
    }
    expect(await check(), 0);
    video.episodes.add(const SourceChapter(id: 'part2', title: '第3集（下）'));
    expect(await check(), 1);
    expect(center.rows('updates').single['latest'], '第3集（下）');
    expect(await check(), 0);
  });
  test('暂停和完结不请求；恢复首检建基线，之后新增进入收件箱', () async {
    final manager = FakeSourceManager(opened: {source.id: source});
    final tracker = TrackingService(
      managerFor: (_) => manager,
      wait: () async {},
    );
    final ref = ContentRef(Section.comic, source.id, 'book', '小说');
    center.setTrackingState(ref, 'paused');
    expect((await tracker.check(libraries: [library])).success, 0);
    expect(manager.openedIds, isEmpty);
    center.setTrackingState(ref, 'active');
    expect((await tracker.check(libraries: [library])).success, 1);
    expect(center.rows('updates'), isEmpty);
    center.put('checked.${ref.key}', DateTime(2000).toIso8601String());
    source.count = 3;
    expect((await tracker.check(libraries: [library])).newChapters, 1);
    expect(center.rows('updates').single['latest'], '第3章');
    center.setTrackingState(ref, 'completed');
    expect((await tracker.check(libraries: [library])).success, 0);
  });
  test('小说预下载与 Wi-Fi 策略联动、落盘后无源读取且不重复请求', () async {
    center.put('autoReadDownloads', true);
    center.put('nextDownloads', 2);
    const target = ReadingTarget(
      sourceId: 'fake.comic',
      itemId: 'book',
      title: '小说',
    );
    final chapters = await source.chapters('book');
    await ReadingOffline.prefetch(
      source: source,
      library: library,
      target: target,
      chapters: chapters,
      current: -1,
      novel: true,
    );
    expect(source.calls, 2);
    expect((await ReadingOffline.read(source, 'book', '1'))!.text, '正文 1');
    await ReadingOffline.prefetch(
      source: source,
      library: library,
      target: target,
      chapters: chapters,
      current: -1,
      novel: true,
    );
    expect(source.calls, 2);
    center.put('wifiOnly', true);
    source.count = 3;
    await ReadingOffline.prefetch(
      source: source,
      library: library,
      target: target,
      chapters: await source.chapters('book'),
      current: 1,
      novel: true,
    );
    expect(source.calls, 2, reason: '未知网络不下载');
  });
  test('新增增强偏好与摘录能够写入并重新加载', () async {
    AppPreferences.instance.file = File('${root.path}/app_preferences.json');
    center.put('autoChecks', true);
    center.clip(
      const ContentRef(Section.comic, 'source', 'book', '作品'),
      text: '摘录',
      chapter: 2,
      page: 4,
    );
    AppPreferences.instance.experience = {};
    await AppPreferences.instance.boot(directory: root);
    expect(center.enabled('autoChecks'), true);
    expect(center.rows('clips').single['page'], 4);
    AppPreferences.instance.file = null;
  });
}
