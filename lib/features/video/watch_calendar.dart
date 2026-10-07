import 'package:flutter/foundation.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';

/// 追更 / 追剧日历的一天：某日期上的条目（更新 / 观看记录）。
///
/// 「更新」来自图源的章节时间信息（[SourceChapter.publishedAt]，可选能力）；
/// 「观看记录」来自本板块的阅读进度（视频 / 小说 / 漫画三种形状共用一张表）。
/// 两者都不需要新的存储——日历是**视图**，不是新数据源。三个板块共用这份逻辑。
@immutable
class CalendarDay {
  const CalendarDay({
    required this.date,
    this.updates = const <CalendarEntry>[],
    this.watched = const <CalendarEntry>[],
  });

  /// 当天零点（本地时区）。
  final DateTime date;

  /// 当天更新的条目（来自图源章节时间）。
  final List<CalendarEntry> updates;

  /// 当天看过 / 读过的条目。
  final List<CalendarEntry> watched;

  bool get isEmpty => updates.isEmpty && watched.isEmpty;

  int get total => updates.length + watched.length;

  /// 日历格子上的角标数字（更新优先，其次播放记录）。
  int get badge => updates.isNotEmpty ? updates.length : watched.length;
}

/// 日历上的一个条目。
@immutable
class CalendarEntry {
  const CalendarEntry({
    required this.itemId,
    required this.title,
    this.chapterTitle = '',
    this.kind = CalendarEntryKind.update,
  });

  final String itemId;
  final String title;

  /// 相关章节标题（更新条目）。
  final String chapterTitle;

  final CalendarEntryKind kind;
}

/// 条目来源。
enum CalendarEntryKind {
  /// 图源报的更新。
  update('update', '更新'),

  /// 本地播放记录。
  watched('watched', '看过');

  const CalendarEntryKind(this.id, this.label);

  final String id;
  final String label;
}

/// 追剧日历的聚合逻辑（纯函数，便于单测）。
///
/// 输入两样东西：
/// 1. **播放记录**：本板块视频进度（`updatedAt` 即「看到这一集的时刻」）；
/// 2. **章节更新时间**：由调用方从图源拿到（可选能力），按 `itemId` 传进来。
///
/// 输出按日期分组的日历。**不引入新的持久化**：日历是现有数据的视图，
/// 这样「日历与进度不一致」这类问题从根上不存在。
class WatchCalendar {
  const WatchCalendar._();

  /// 把时间归到当天零点（本地时区）。
  static DateTime dayOf(DateTime time) {
    final local = time.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// 生成某个月（含首尾补白）的日历。
  ///
  /// [month] 只需年月有效；返回的列表长度是 7 的倍数，首日之前的补白与末日之后
  /// 的补白也在其中（`isEmpty` 为 true 的格子）。
  static List<CalendarDay> monthGrid({
    required DateTime month,
    required List<CalendarUpdate> updates,
    required List<({LibraryItem item, ReadingProgress progress})> history,
  }) {
    final first = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 周一为一周之首（与「追剧」习惯一致）。
    final leading = (first.weekday - DateTime.monday) % 7;
    final total = leading + daysInMonth;
    final trailing = (7 - total % 7) % 7;

    final byDay = <DateTime, ({List<CalendarEntry> updates, List<CalendarEntry> watched})>{};
    ({List<CalendarEntry> updates, List<CalendarEntry> watched}) bucket(DateTime day) =>
        byDay.putIfAbsent(
          day,
          () => (
            updates: <CalendarEntry>[],
            watched: <CalendarEntry>[],
          ),
        );

    // 播放记录：进度里的 updatedAt 就是「看到这里的时刻」。
    for (final entry in history) {
      final day = dayOf(entry.progress.updatedAt);
      bucket(day).watched.add(
            CalendarEntry(
              itemId: entry.item.itemId,
              title: entry.item.title,
              chapterTitle: entry.progress.chapterTitle,
              kind: CalendarEntryKind.watched,
            ),
          );
    }

    // 更新：调用方从图源拿到的章节时间。
    for (final update in updates) {
      final day = dayOf(update.date);
      bucket(day).updates.add(update.entry);
    }

    final grid = <CalendarDay>[];
    for (var offset = -leading; offset < daysInMonth + trailing; offset++) {
      final date = DateTime(month.year, month.month, 1 + offset);
      // 补白格子（上/下月的日期）一律留空：本月的记录只画在本月的格子里，
      // 否则 9 月 30 日的记录会同时出现在 10 月网格的补白格里（看起来像 10 月的）。
      final inMonth = date.month == month.month && date.year == month.year;
      final data = inMonth ? byDay[dayOf(date)] : null;
      grid.add(
        CalendarDay(
          date: DateTime(date.year, date.month, date.day),
          updates: data?.updates ?? const <CalendarEntry>[],
          watched: data?.watched ?? const <CalendarEntry>[],
        ),
      );
    }
    return List<CalendarDay>.unmodifiable(grid);
  }

  /// 该月有内容的日期数（用于「本月 N 天有更新」）。
  static int activeDays(List<CalendarDay> grid, {required DateTime month}) {
    var count = 0;
    for (final day in grid) {
      if (day.date.year != month.year || day.date.month != month.month) continue;
      if (!day.isEmpty) count++;
    }
    return count;
  }
}

/// 日历里的更新时间条目（日期 + 内容）。
class CalendarUpdate {
  const CalendarUpdate({
    required this.date,
    required this.entry,
  });

  final DateTime date;
  final CalendarEntry entry;
}

/// 收集「更新」：对最近在看的作品逐个问图源的章节时间（可选能力）。
///
/// 为什么串行：网络层已有并发限制，而日历不是实时视图——慢一点没关系，
/// 别把图源打爆。失败只跳过那一个作品（日历照常显示，缺的是它的更新）。
///
/// 三个板块共用：`manager` 传哪个板块的，就只问那个板块的图源与记录。
Future<List<CalendarUpdate>> collectCalendarUpdates({
  required ReadingLibrary library,
  required SourceManager manager,
  int limit = 30,
  bool Function()? isCancelled,
}) async {
  final updates = <CalendarUpdate>[];
  for (final entry in library.continueReading(limit: limit)) {
    if (isCancelled?.call() ?? false) return updates;
    try {
      final source = await manager.open(entry.item.sourceId);
      if (source == null) continue;
      final chapters = await source.chapters(entry.item.itemId);
      for (final chapter in chapters) {
        final published = chapter.publishedAt;
        if (published == null) continue;
        updates.add(
          CalendarUpdate(
            date: published,
            entry: CalendarEntry(
              itemId: entry.item.itemId,
              title: entry.item.title,
              chapterTitle: chapter.title,
            ),
          ),
        );
      }
    } catch (error) {
      LumeLog.info('[calendar] 更新取不到（${entry.item.title}）：$error');
    }
  }
  return updates;
}
