import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import 'watch_calendar.dart';

/// 追剧日历：按月查看「哪天有更新 / 哪天看过」。
///
/// 数据来源（都是既有数据，不新增存储）：
/// - **看过**：本板块视频进度（`updatedAt`）；
/// - **更新**：图源章节时间（可选能力，由调用方取好传进来）。
///
/// 点某天的条目直接续看（回调交回宿主页处理）。
class WatchCalendarPage extends StatefulWidget {
  const WatchCalendarPage({
    super.key,
    required this.library,
    required this.updates,
    this.onOpen,
    this.initialMonth,
  });

  /// 本板块阅读库（调用方负责释放）。
  final ReadingLibrary library;

  /// 章节更新时间（调用方从图源取；取不到就传空表——日历只显示播放记录）。
  final List<CalendarUpdate> updates;

  /// 点条目：交给宿主页续看。
  final void Function(CalendarEntry entry)? onOpen;

  /// 初始月份；为空时取当前月。
  final DateTime? initialMonth;

  @override
  State<WatchCalendarPage> createState() => _WatchCalendarPageState();
}

class _WatchCalendarPageState extends State<WatchCalendarPage> {
  late DateTime _month = widget.initialMonth ?? DateTime.now();
  DateTime? _selected;

  /// 播放记录（进页面读一次；日历不是实时数据，不需要监听）。
  late final List<({LibraryItem item, VideoProgress progress})> _history =
      _loadHistory();

  List<({LibraryItem item, VideoProgress progress})> _loadHistory() {
    final result = <({LibraryItem item, VideoProgress progress})>[];
    for (final item in widget.library.continueWatching(limit: 500)) {
      final progress = widget.library.videoProgress(item.itemId);
      if (progress == null) continue;
      result.add((item: item, progress: progress));
    }
    return result;
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final grid = WatchCalendar.monthGrid(
      month: _month,
      updates: widget.updates,
      history: _history,
    );
    final activeDays = WatchCalendar.activeDays(grid, month: _month);

    return GlassScaffold(
      title: '${Section.video.label} · 追剧日历',
      child: Column(
        children: <Widget>[
          _buildHeader(activeDays),
          _buildWeekdayRow(),
          _buildGrid(grid),
          Divider(height: 1, color: LumeTheme.divider),
          Expanded(child: _buildDayDetail(grid)),
        ],
      ),
    );
  }

  Widget _buildHeader(int activeDays) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '上个月',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftMonth(-1),
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                Text(
                  '${_month.year} 年 ${_month.month} 月',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                Text(
                  activeDays == 0 ? '本月暂无记录' : '本月 $activeDays 天有记录',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '下个月',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _shiftMonth(1),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekdayRow() {
    const labels = <String>['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: <Widget>[
          for (final label in labels)
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<CalendarDay> grid) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          childAspectRatio: 1.0,
        ),
        itemCount: grid.length,
        itemBuilder: (context, index) {
          final day = grid[index];
          final inMonth = day.date.month == _month.month;
          final selected = _selected != null &&
              WatchCalendar.dayOf(_selected!) == day.date;
          return _DayCell(
            day: day,
            inMonth: inMonth,
            selected: selected,
            onTap: day.isEmpty && !inMonth
                ? null
                : () => setState(() => _selected = day.date),
          );
        },
      ),
    );
  }

  Widget _buildDayDetail(List<CalendarDay> grid) {
    final selected = _selected;
    if (selected == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '点一个日期查看当天的更新与播放记录',
            style: TextStyle(fontSize: 13, color: LumeTheme.muted),
          ),
        ),
      );
    }
    final day = grid.firstWhere(
      (item) => item.date == WatchCalendar.dayOf(selected),
      orElse: () => CalendarDay(date: selected),
    );
    if (day.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${day.date.month} 月 ${day.date.day} 日没有记录',
            style: TextStyle(fontSize: 13, color: LumeTheme.muted),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (day.updates.isNotEmpty) ...<Widget>[
          const _SectionLabel('当天更新'),
          for (final entry in day.updates)
            _EntryTile(entry: entry, onTap: widget.onOpen),
        ],
        if (day.watched.isNotEmpty) ...<Widget>[
          const _SectionLabel('当天看过'),
          for (final entry in day.watched)
            _EntryTile(entry: entry, onTap: widget.onOpen),
        ],
      ],
    );
  }
}

/// 日历格子：日期 + 角标。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.selected,
    required this.onTap,
  });

  final CalendarDay day;
  final bool inMonth;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasUpdate = day.updates.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected
                ? LumeTheme.hairline
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hasUpdate
                  ? LumeTheme.success.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                '${day.date.day}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: day.isEmpty ? FontWeight.w400 : FontWeight.w600,
                  color: !inMonth
                      ? LumeTheme.muted.withValues(alpha: 0.4)
                      : (day.isEmpty ? LumeTheme.muted : LumeTheme.textPrimary),
                ),
              ),
              if (day.total > 0) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  '${day.badge}',
                  style: TextStyle(
                    fontSize: 10,
                    color: hasUpdate
                        ? LumeTheme.success
                        : LumeTheme.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: LumeTheme.muted,
          ),
        ),
      );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, this.onTap});

  final CalendarEntry entry;
  final void Function(CalendarEntry entry)? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: onTap == null ? null : () => onTap!(entry),
        child: Row(
          children: <Widget>[
            Icon(
              entry.kind == CalendarEntryKind.update
                  ? Icons.new_releases_outlined
                  : Icons.play_circle_outline,
              size: 18,
              color: LumeTheme.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  if (entry.chapterTitle.isNotEmpty)
                    Text(
                      entry.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              entry.kind.label,
              style: TextStyle(fontSize: 11, color: LumeTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 日历空态（没有库时给可读提示，而不是白屏）。
class CalendarUnavailable extends StatelessWidget {
  const CalendarUnavailable({super.key});

  @override
  Widget build(BuildContext context) => const GlassScaffold(
        title: '追剧日历',
        child: NoticeCard(
          title: '追剧日历不可用',
          subtitle: '本板块的播放记录打不开，请重启应用后重试',
        ),
      );
}
