import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/video/watch_calendar.dart';

/// 追剧日历的聚合逻辑（纯函数）。
///
/// 关键约束：日历是**既有数据的视图**（播放记录 + 图源章节时间），不引入新存储。
/// 因此这里验证的是「分组是否正确」与「空数据是否安全」。
void main() {
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
}
