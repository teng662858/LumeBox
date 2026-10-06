import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'log_report.dart';

/// 错误报告：把本次运行的日志整理成报告，导出文件或复制全文。
///
/// 复杂导出逻辑（报告汇编 + 落盘）是 iOS 平台业务的一部分；页面本身在
/// 非 iOS 平台不可达（设置入口在骨架里）。
class LogReportPage extends StatefulWidget {
  const LogReportPage({super.key, required this.exporter});

  final LogExporter exporter;

  @override
  State<LogReportPage> createState() => _LogReportPageState();
}

class _LogReportPageState extends State<LogReportPage> {
  LogExportResult? _result;
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final result = await widget.exporter.export(LumeLog.snapshot);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = result;
      });
      _toast('已导出报告：${result.entries} 条日志');
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导出失败：$error');
    }
  }

  Future<void> _copy() async {
    final entries = LumeLog.snapshot;
    final content = LogExporter.build(entries, generatedAt: DateTime.now());
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    _toast('已复制报告全文（${entries.length} 条日志）');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '错误报告',
      child: StreamBuilder<void>(
        stream: LumeLog.changes,
        builder: (context, _) => _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final entries = LumeLog.snapshot;
    final summary = LogExporter.summarize(entries);
    final result = _result;

    return ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: <Widget>[
        GlassCard(
          radius: 14,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                summary.isEmpty
                    ? '本次运行还没有日志'
                    : summary.hasProblems
                        ? '发现 ${summary.errors} 个错误、${summary.warnings} 个警告'
                        : '本次运行没有错误与警告',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '日志条数：共 ${summary.total} 条'
                '（信息 ${summary.total - summary.errors - summary.warnings}）',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              if (!summary.isEmpty)
                Text(
                  '时间范围：${LogExporter.formatTime(summary.first!)} ~ '
                  '${LogExporter.formatTime(summary.last!)}',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              const SizedBox(height: 8),
              Text(
                '报告只包含本次运行的日志（重启后清空），导出为应用目录下的 '
                'logs/ 文本文件。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: Text(_busy ? '导出中…' : '导出报告文件'),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制报告全文'),
            ),
          ],
        ),
        if (result != null) ...<Widget>[
          const SizedBox(height: 16),
          GlassCard(
            radius: 14,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '最近一次导出',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  result.file.path,
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  '${result.entries} 条日志 · ${_formatBytes(result.bytes)}',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
