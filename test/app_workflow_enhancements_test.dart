import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/chapter_updates.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/core/util/frame_profile.dart';
import 'package:lume_box/features/reading/aggregate_work_groups.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';
import 'package:lume_box/features/settings/settings_ui.dart';
import 'package:lume_box/features/video/video_resume_match.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('workflow-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  test('追更能识别同数补集、内容替换与发布时间变化，纯重排不报更新', () async {
    final library = await ReadingLibrary.open(Section.video);
    library.shelve(sourceId: 'a', itemId: 'show', title: '演示');
    final item = library.shelf().single;
    const old = [
      SourceChapter(id: 'a', title: '第1集'),
      SourceChapter(id: 'b', title: '第2集'),
    ];
    expect(ChapterUpdates.check(library, item, old), isFalse);
    expect(ChapterUpdates.check(library, item, old.reversed.toList()), isFalse);
    expect(
      ChapterUpdates.check(library, item, [
        old.first,
        const SourceChapter(id: 'c', title: '第3集'),
      ]),
      isTrue,
    );
    expect(ChapterUpdates.check(library, item, []), isFalse);
    expect(
      ChapterUpdates.check(library, item, [
        old.first,
        SourceChapter(id: 'c', title: '第3集', publishedAt: DateTime(2026)),
      ]),
      isTrue,
    );
  });
  test('跨源续播识别季集，保留多个线路供确认，未知标签不按下标猜', () {
    const request = VideoResumeRequest(
      title: '演示',
      chapterTitle: 'S02E03',
      chapterIndex: 2,
      position: Duration(seconds: 75),
      duration: Duration(minutes: 40),
    );
    final candidates = request.candidates(const [
      SourceChapter(id: 'wrong', title: 'S01E03'),
      SourceChapter(id: 'a', title: 'S02E03', line: 'A'),
      SourceChapter(id: 'b', title: '第2季第3集', line: 'B'),
    ]);
    expect(candidates.map((c) => c.id), ['a', 'b']);
    expect(
      request
          .progress('new', 'item', candidates.first, 2, Section.video)
          .position,
      const Duration(seconds: 75),
    );
    const unknown = VideoResumeRequest(
      title: '演示',
      chapterTitle: '特别篇',
      chapterIndex: 2,
      position: Duration.zero,
      duration: Duration.zero,
    );
    expect(
      unknown.candidates(const [SourceChapter(id: '3', title: '第3集')]),
      isEmpty,
    );
  });
  test('跨源续播只将小数集进度转移到同一小数集', () {
    const request = VideoResumeRequest(
      title: '演示', chapterTitle: 'S01E03.5', chapterIndex: 3,
      position: Duration(minutes: 8), duration: Duration(minutes: 20),
    );
    const chapters = [
      SourceChapter(id: 'full', title: '第一季 第3集'),
      SourceChapter(id: 'special', title: '第一季 第3.5话'),
      SourceChapter(id: 'otherSeason', title: '第二季 第3.5集'),
    ];
    expect(request.candidates(chapters).map((c) => c.id), ['special']);
    expect(chapters.where(request.confident).map((c) => c.id), ['special']);
  });
  test('跨源续播季数信息不全需要确认，特别篇同名不能覆盖季数冲突', () {
    VideoResumeRequest saved(String work, String episode) => VideoResumeRequest(
      title: work, chapterTitle: episode, chapterIndex: 0,
      position: const Duration(minutes: 8), duration: const Duration(minutes: 20),
    );
    const third = SourceChapter(id: '3', title: '第3集');
    const special = SourceChapter(id: 'sp', title: '特别篇');
    final unknown = saved('演示', '第3集');
    expect(unknown.candidates([third], workTitle: '演示 第二季'), [third]);
    expect(unknown.confident(third, workTitle: '演示 第二季'), isFalse);
    final second = saved('演示 第二季', '特别篇');
    expect(second.candidates([special], workTitle: '演示 第一季'), isEmpty);
    expect(second.confident(special, workTitle: '演示 第一季'), isFalse);
    expect(second.candidates([special], workTitle: '演示'), [special]);
    expect(second.confident(special, workTitle: '演示'), isFalse);
    expect(second.confident(special, workTitle: '演示 Season 2'), isTrue);
  });
  test('跨源续播上篇不会把进度转移给下篇、预告或完整集', () {
    const request = VideoResumeRequest(
      title: '演示',
      chapterTitle: '第3集（上）',
      chapterIndex: 2,
      position: Duration(minutes: 11),
      duration: Duration(minutes: 20),
    );
    const chapters = [
      SourceChapter(id: 'bottom', title: '第3集（下）'),
      SourceChapter(id: 'trailer', title: '第3集预告'),
      SourceChapter(id: 'whole', title: 'S01E03'),
      SourceChapter(id: 'top', title: '第03集 上'),
    ];
    expect(request.candidates(chapters).map((c) => c.id), ['top']);
    expect(chapters.where(request.confident).map((c) => c.id), ['top']);
  });
  test('同名搜索保留年份和季数边界，按更新集数排序，不丢失来源', () {
    SearchHit hit(String source, String title, String sub) => SearchHit(
      sourceId: source,
      sourceName: source,
      item: SourceItem(id: source, title: title, subtitle: sub),
    );
    final groups = AggregateWorkGroups.group([
      hit('a', '演示 第1季', '2026 更新至3集'),
      hit('b', '演示 第1季', '2026 更新至8集'),
      hit('c', '演示 第2季', '2026 全12集'),
      hit('d', '演示 第1季', '2025 全10集'),
    ], order: 'episodes');
    expect(groups, hasLength(3));
    expect(groups.first.single.sourceId, 'c');
    expect(groups.expand((g) => g), hasLength(4));
    expect(groups.last.map((h) => h.sourceId), ['b', 'a']);
  });
  test('作品独立外观持久化且不改全局，取消覆盖恢复全局', () async {
    final settings = TmdbSettings();
    await settings.boot();
    final original = settings.detailAppearance.value;
    settings.setAppearance(
      'work',
      const TmdbDetailAppearance(backgroundBrightness: 2, logoScale: .5),
    );
    await settings.save(appearanceOnly: true);
    final restored = TmdbSettings();
    await restored.boot();
    expect(restored.appearanceFor('work').backgroundBrightness, 2);
    expect(restored.appearanceFor(null).toJson(), original.toJson());
    restored.clearAppearance('work');
    expect(restored.appearanceFor('work').toJson(), original.toJson());
  });
  testWidgets('设置首页不显示搜索且分类入口可用', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsHome(
            categories: [
              SettingsCategory(
                '网络与服务',
                '服务',
                Icons.settings,
                const [],
                onTap: () => opened = true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('settings-search')), findsNothing);
    await tester.tap(find.text('网络与服务'));
    expect(opened, isTrue);
  });
  test('流畅度报告按设备帧预算统计慢帧和分位数，并保留构建模式', () {
    final profile = FrameProfile();
    profile.start('视频切集', refreshRate: 120);
    profile.add(3, 4);
    profile.add(10, 2);
    profile.add(5, 12);
    final report = profile.stop();
    expect(report['frames'], 3);
    expect(report['slowFrames'], 2);
    expect(report['rasterP95Ms'], 12);
    expect(report['mode'], 'debug');
    expect(profile.recording, isFalse);
  });
}
