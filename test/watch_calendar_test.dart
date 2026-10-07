import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/watch_calendar.dart';

import 'support/fake_source_manager.dart';

/// 追更 / 追剧日历的聚合逻辑（纯函数）与数据收集（[collectCalendarUpdates]）。
///
/// 关键约束：日历是**既有数据的视图**（阅读记录 + 图源章节时间），不引入新存储。
/// 因此这里验证的是「分组是否正确」「空数据是否安全」与「取不到更新时是否静默
/// 降级」——三个板块共用同一份逻辑与同一个收集器。
void main() {
  // 收集器（[collectCalendarUpdates]）要走真实板块目录与库，因此需要测试绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 5, 14, 30);

  LibraryItem item(String id, String title) => LibraryItem(
        section: Section.video,
        itemId: id,
        sourceId: 'src',
        title: title,
        chapterCount: 0,
        readChapterIndex: -1,
        addedAt: now,
        updatedAt: now,
      );

  VideoProgress progress({
    required String itemId,
    required DateTime at,
    int chapterIndex = 0,
    String chapterTitle = '第 1 集',
  }) =>
      VideoProgress(
        section: Section.video,
        itemId: itemId,
        chapterIndex: chapterIndex,
        chapterId: 'e$chapterIndex',
        chapterTitle: chapterTitle,
        updatedAt: at,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 40),
      );

  group('日期归组', () {
    test('同一天的记录归到一个格子，不同天分开', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: <({LibraryItem item, VideoProgress progress})>[
          (item: item('a', '甲'), progress: progress(itemId: 'a', at: DateTime(2026, 10, 3, 9))),
          (item: item('b', '乙'), progress: progress(itemId: 'b', at: DateTime(2026, 10, 3, 21))),
          (item: item('c', '丙'), progress: progress(itemId: 'c', at: DateTime(2026, 10, 5, 1))),
        ],
      );

      final day3 = grid.firstWhere((day) => day.date == DateTime(2026, 10, 3));
      final day5 = grid.firstWhere((day) => day.date == DateTime(2026, 10, 5));
      expect(day3.watched.length, 2, reason: '同一天两条记录');
      expect(day3.badge, 2);
      expect(day5.watched.length, 1);
      expect(day5.badge, 1);
    });

    test('更新与播放记录分开归类，角标优先显示更新数', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: <CalendarUpdate>[
          CalendarUpdate(
            date: DateTime(2026, 10, 7, 8),
            entry: const CalendarEntry(
              itemId: 'a',
              title: '甲',
              chapterTitle: '第 5 集',
            ),
          ),
          CalendarUpdate(
            date: DateTime(2026, 10, 7, 9),
            entry: const CalendarEntry(
              itemId: 'b',
              title: '乙',
              chapterTitle: '第 2 集',
            ),
          ),
        ],
        history: <({LibraryItem item, VideoProgress progress})>[
          (item: item('a', '甲'), progress: progress(itemId: 'a', at: DateTime(2026, 10, 7, 20))),
        ],
      );

      final day = grid.firstWhere((item) => item.date == DateTime(2026, 10, 7));
      expect(day.updates.length, 2);
      expect(day.watched.length, 1);
      expect(day.total, 3);
      expect(day.badge, 2, reason: '有更新时角标显示更新数');
      expect(day.isEmpty, isFalse);
    });

    test('时间戳按本地时区归组（跨零点不串天）', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: <({LibraryItem item, VideoProgress progress})>[
          (
            item: item('a', '甲'),
            progress: progress(itemId: 'a', at: DateTime(2026, 10, 1, 23, 59)),
          ),
          (
            item: item('b', '乙'),
            progress: progress(itemId: 'b', at: DateTime(2026, 10, 2, 0, 1)),
          ),
        ],
      );
      expect(
        grid.firstWhere((day) => day.date == DateTime(2026, 10, 1)).watched.length,
        1,
      );
      expect(
        grid.firstWhere((day) => day.date == DateTime(2026, 10, 2)).watched.length,
        1,
      );
    });
  });

  group('网格形状', () {
    test('周一开头：2026 年 10 月 1 日是周四，前面补 3 个空位', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: const <({LibraryItem item, VideoProgress progress})>[],
      );
      // 10 月 1 日 = 周四（weekday 4），周一起算 → 前面 3 个补白。
      final firstOfMonth = grid.indexWhere((day) => day.date == DateTime(2026, 10, 1));
      expect(firstOfMonth, 3);
      expect(grid.length % 7, 0, reason: '整周对齐');
      expect(grid.first.isEmpty, isTrue, reason: '补白格子为空');
    });

    test('补白格子不含数据（不会把上月的记录画进本月）', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: <({LibraryItem item, VideoProgress progress})>[
          // 9 月 30 日的记录：10 月网格里若出现补白格子，它必须为空。
          (
            item: item('a', '甲'),
            progress: progress(itemId: 'a', at: DateTime(2026, 9, 30, 10)),
          ),
        ],
      );
      final leading = grid.take(3);
      expect(
        leading.every((day) => day.isEmpty),
        isTrue,
        reason: '上月记录不该出现在本月的补白格里',
      );
    });

    test('activeDays 只数本月', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: <({LibraryItem item, VideoProgress progress})>[
          (item: item('a', '甲'), progress: progress(itemId: 'a', at: DateTime(2026, 10, 2))),
          (item: item('b', '乙'), progress: progress(itemId: 'b', at: DateTime(2026, 10, 2))),
          (item: item('c', '丙'), progress: progress(itemId: 'c', at: DateTime(2026, 9, 29))),
        ],
      );
      expect(WatchCalendar.activeDays(grid, month: DateTime(2026, 10)), 1);
    });

    test('空数据：整月都是空格子，不抛错', () {
      final grid = WatchCalendar.monthGrid(
        month: DateTime(2026, 2),
        updates: const <CalendarUpdate>[],
        history: const <({LibraryItem item, VideoProgress progress})>[],
      );
      expect(grid.every((day) => day.isEmpty), isTrue);
      expect(grid.length % 7, 0);
      // 2026 年 2 月 1 日是周日 → 周一起算补 6 格。
      expect(grid.indexWhere((day) => day.date == DateTime(2026, 2, 1)), 6);
    });

    test('跨月切换：上/下月网格互不串数据', () {
      final history = <({LibraryItem item, VideoProgress progress})>[
        (item: item('a', '甲'), progress: progress(itemId: 'a', at: DateTime(2026, 10, 15))),
      ];
      final october = WatchCalendar.monthGrid(
        month: DateTime(2026, 10),
        updates: const <CalendarUpdate>[],
        history: history,
      );
      final november = WatchCalendar.monthGrid(
        month: DateTime(2026, 11),
        updates: const <CalendarUpdate>[],
        history: history,
      );
      expect(
        october.any((day) => day.date == DateTime(2026, 10, 15) && !day.isEmpty),
        isTrue,
      );
      expect(november.every((day) => day.isEmpty), isTrue);
    });
  });

  group('dayOf 归一', () {
    test('同一天不同时刻归一后相等', () {
      expect(
        WatchCalendar.dayOf(DateTime(2026, 10, 5, 0, 0)),
        WatchCalendar.dayOf(DateTime(2026, 10, 5, 23, 59, 59)),
      );
    });

    test('归一后时分秒为零', () {
      final day = WatchCalendar.dayOf(DateTime(2026, 10, 5, 14, 30, 45));
      expect(<int>[day.hour, day.minute, day.second], <int>[0, 0, 0]);
    });
  });

  group('collectCalendarUpdates：图源章节时间 → 更新排期', () {
    late Directory root;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('lume_box_calendar_loader');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? root.path
            : null,
      );
      await SectionScope.open(Section.novel);
      await ReadingLibrary.open(Section.novel);
    });

    tearDown(() async {
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// 图源替身：章节带 / 不带发布时间，或整条 chapters 抛错。
    _LoaderSource source({DateTime? published, bool failing = false}) =>
        _LoaderSource(published: published, failing: failing);

    test('有发布时间章 → 逐章一条更新（板块与图源都以本板块为准）', () async {
      final library = await ReadingLibrary.open(Section.novel);
      library.shelve(
        sourceId: 'novel-src',
        itemId: 'novel-1',
        title: '示例小说',
        chapterCount: 2,
      );
      library.saveProgress(
        NovelProgress(
          section: Section.novel,
          itemId: 'novel-1',
          chapterIndex: 0,
          chapterId: 'c1',
          chapterTitle: '第 1 章',
          updatedAt: DateTime(2026, 10, 1),
          charOffset: 10,
        ),
      );
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'novel-src',
            name: '示例源',
            version: '1',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{
          'novel-src': source(published: DateTime(2026, 10, 4, 8)),
        },
      );

      final updates = await collectCalendarUpdates(
        library: library,
        manager: manager,
      );

      expect(updates, hasLength(2), reason: '两章各自带发布时间');
      expect(updates.first.entry.itemId, 'novel-1');
      expect(updates.first.entry.title, '示例小说');
      expect(updates.first.entry.chapterTitle, '第 1 章');
      expect(updates.first.date, DateTime(2026, 10, 4, 8));
      expect(updates.last.entry.chapterTitle, '第 2 章');
    });

    test('章节没有发布时间 → 不编造更新（空表）', () async {
      final library = await ReadingLibrary.open(Section.novel);
      library.shelve(
        sourceId: 'novel-src',
        itemId: 'novel-1',
        title: '示例小说',
        chapterCount: 1,
      );
      library.saveProgress(
        NovelProgress(
          section: Section.novel,
          itemId: 'novel-1',
          chapterIndex: 0,
          chapterId: 'c1',
          chapterTitle: '第 1 章',
          updatedAt: DateTime(2026, 10, 1),
          charOffset: 0,
        ),
      );
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'novel-src',
            name: '示例源',
            version: '1',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{'novel-src': source()},
      );

      expect(
        await collectCalendarUpdates(library: library, manager: manager),
        isEmpty,
        reason: '拿不到更新时间就不显示更新——日历只画既有事实',
      );
    });

    test('图源取章节失败 → 跳过它，不把异常抛给日历', () async {
      final library = await ReadingLibrary.open(Section.novel);
      library.shelve(
        sourceId: 'novel-src',
        itemId: 'novel-1',
        title: '示例小说',
        chapterCount: 1,
      );
      library.saveProgress(
        NovelProgress(
          section: Section.novel,
          itemId: 'novel-1',
          chapterIndex: 0,
          chapterId: 'c1',
          chapterTitle: '第 1 章',
          updatedAt: DateTime(2026, 10, 1),
          charOffset: 0,
        ),
      );
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'novel-src',
            name: '示例源',
            version: '1',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{'novel-src': source(failing: true)},
      );

      expect(
        await collectCalendarUpdates(library: library, manager: manager),
        isEmpty,
      );
    });

    test('没有记录 → 不访问图源，直接空表', () async {
      final library = await ReadingLibrary.open(Section.novel);
      final manager = FakeSourceManager();
      expect(
        await collectCalendarUpdates(library: library, manager: manager),
        isEmpty,
      );
      expect(manager.openedIds, isEmpty, reason: '没有记录就不该去问图源');
    });
  });
}

/// 图源替身：只实现日历用到的 chapters（其余按契约返回空）。
class _LoaderSource implements DataSource {
  _LoaderSource({this.published, this.failing = false});

  final DateTime? published;
  final bool failing;

  @override
  String get id => 'novel-src';

  @override
  String get name => '示例源';

  @override
  Section get section => Section.novel;

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({String? categoryId, String? keyword, int page = 1}) async =>
      const SourceList();

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    if (failing) {
      throw const SourceException(SourceErrorKind.network, '章节取不到');
    }
    return <SourceChapter>[
      SourceChapter(id: 'c1', title: '第 1 章', publishedAt: published),
      SourceChapter(id: 'c2', title: '第 2 章', publishedAt: published),
    ];
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async =>
      null;
}
