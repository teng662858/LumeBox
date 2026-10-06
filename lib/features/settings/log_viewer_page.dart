import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import 'log_report.dart';
import 'log_report_page.dart';

/// 运行日志：查看本次会话的日志（信息 / 警告 / 错误），可清空。
///
/// 日志只保留当前运行会话（内存环形缓冲，上限 [LumeLog.bufferLimit] 条）；
/// 重启应用后清空——报告导出同样只覆盖当前会话。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key, required this.exporter});

  final LogExporter exporter;

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  /// 当前筛选级别；null 表示全部。
  LogLevel? _filter;

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('清空本次运行记录的全部日志？清空后无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    LumeLog.clear();
  }

  void _export() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogReportPage(exporter: widget.exporter),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '运行日志',
      actions: <Widget>[
        IconButton(
          tooltip: '错误报告',
          icon: const Icon(Icons.file_upload_outlined),
          onPressed: _export,
        ),
        IconButton(
          tooltip: '清空日志',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: _clear,
        ),
      ],
      child: StreamBuilder<void>(
        stream: LumeLog.changes,
        builder: (context, _) => _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final entries = LumeLog.snapshot;
    if (entries.isEmpty) {
      return const NoticeCard(
        title: '暂无日志',
        subtitle: '本次运行还没有产生日志',
      );
    }
    final visible = _filter == null
        ? entries
        : entries.where((entry) => entry.level == _filter).toList(growable: false);
    // 新的在上面：查看现场时不用滚到底。
    final ordered = visible.reversed.toList(growable: false);

    return Column(
      children: <Widget>[
        // 筛选条不是滚动视图，自己让出玻璃顶栏的高度。
        SizedBox(height: GlassScaffold.barHeight(context)),
        _buildFilterBar(entries),
        Expanded(
          child: ordered.isEmpty
              ? Center(
                  child: Text(
                    '该级别暂无日志',
                    style: TextStyle(fontSize: 13, color: LumeTheme.muted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: ordered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _LogTile(entry: ordered[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildFilterBar(List<LogEntry> entries) {
    int count(LogLevel level) =>
        entries.where((entry) => entry.level == level).length;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          _chip(null, '全部', entries.length),
          for (final level in LogLevel.values)
            _chip(level, level.label, count(level)),
        ],
      ),
    );
  }

  Widget _chip(LogLevel? level, String label, int total) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label $total'),
        selected: _filter == level,
        onSelected: (_) => setState(() => _filter = level),
      ),
    );
  }
}

/// 级别配色：错误用项目里既有的告警色，警告用琥珀色，信息用弱化色。
Color get _errorColor => LumeTheme.danger;
Color get _warnColor => LumeTheme.warning;

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  Color get _color => switch (entry.level) {
        LogLevel.error => _errorColor,
        LogLevel.warn => _warnColor,
        LogLevel.info => LumeTheme.muted,
      };

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                LogExporter.formatTime(entry.time).substring(11),
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(width: 8),
              Text(
                entry.level.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.message,
            style: TextStyle(fontSize: 13, color: LumeTheme.textPrimary),
          ),
          if (entry.detail != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              entry.detail!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: LumeTheme.muted),
            ),
          ],
        ],
      ),
    );
  }
}
