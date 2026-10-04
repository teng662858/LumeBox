import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/util/lume_log.dart';

/// 运行日志报告概览。
class LogReportSummary {
  const LogReportSummary({
    required this.total,
    required this.errors,
    required this.warnings,
    this.first,
    this.last,
  });

  final int total;
  final int errors;
  final int warnings;

  /// 最早 / 最近一条日志的时间；没有日志时为 null。
  final DateTime? first;
  final DateTime? last;

  bool get isEmpty => total == 0;

  /// 有没有值得上报的内容（错误或警告）。
  bool get hasProblems => errors > 0 || warnings > 0;
}

/// 导出结果：落盘文件、大小、条数与报告全文（供页面复制）。
class LogExportResult {
  const LogExportResult({
    required this.file,
    required this.bytes,
    required this.entries,
    required this.content,
  });

  final File file;
  final int bytes;
  final int entries;
  final String content;
}

/// 运行日志报告：汇编文本 + 落盘导出。
///
/// 报告只包含当前运行会话的日志（见 [LumeLog] 的会话口径），落盘到应用目录
/// 下的 `logs/`——与四个板块的目录分开：日志是应用级诊断数据，不属于任何板块。
class LogExporter {
  const LogExporter({this.now});

  /// 注入时钟（测试用）；为空时取系统时间。
  final DateTime Function()? now;

  /// 报告目录名（应用支持目录下）。
  static const String dirName = 'logs';

  static LogReportSummary summarize(List<LogEntry> entries) {
    var errors = 0;
    var warnings = 0;
    for (final entry in entries) {
      switch (entry.level) {
        case LogLevel.error:
          errors += 1;
        case LogLevel.warn:
          warnings += 1;
        case LogLevel.info:
          break;
      }
    }
    return LogReportSummary(
      total: entries.length,
      errors: errors,
      warnings: warnings,
      first: entries.isEmpty ? null : entries.first.time,
      last: entries.isEmpty ? null : entries.last.time,
    );
  }

  /// 汇编报告文本。
  static String build(List<LogEntry> entries, {required DateTime generatedAt}) {
    final summary = summarize(entries);
    final buffer = StringBuffer()
      ..writeln('Lume Box 运行日志报告')
      ..writeln('生成时间：${formatTime(generatedAt)}')
      ..writeln(
        '日志条数：共 ${summary.total} 条'
        '（错误 ${summary.errors} / 警告 ${summary.warnings} / '
        '信息 ${summary.total - summary.errors - summary.warnings}）',
      )
      ..writeln(
        summary.isEmpty
            ? '时间范围：无'
            : '时间范围：${formatTime(summary.first!)} ~ ${formatTime(summary.last!)}',
      )
      ..writeln('-' * 48);
    for (final entry in entries) {
      buffer.writeln(
        '[${formatTime(entry.time)}] ${entry.level.label} ${entry.message}',
      );
      final detail = entry.detail;
      if (detail != null && detail.isNotEmpty) {
        for (final line in detail.split('\n')) {
          if (line.trim().isEmpty) continue;
          buffer.writeln('    $line');
        }
      }
    }
    return buffer.toString();
  }

  /// 导出报告文件。同名（同一秒内二次导出）自动加序号。
  Future<LogExportResult> export(List<LogEntry> entries) async {
    final generatedAt = (now ?? DateTime.now)();
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, dirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);


    final content = build(entries, generatedAt: generatedAt);
    final stamp = _stamp(generatedAt);
    var file = File(p.join(dir.path, 'log_report_$stamp.txt'));
    var index = 1;
    while (file.existsSync()) {
      file = File(p.join(dir.path, 'log_report_$stamp-$index.txt'));
      index += 1;
    }
    // 用小体积报告的同步写：与板块存储的同步读写同一口径，
    // 也避免把导出挂到事件循环上（页面在测试时钟里也能立即拿到结果）。
    file.writeAsStringSync(content, flush: true);
    return LogExportResult(
      file: file,
      bytes: file.lengthSync(),
      entries: entries.length,
      content: content,
    );
  }

  /// `20261004_213310`：文件名里保持人类可读的本地时间。
  static String _stamp(DateTime time) =>
      '${time.year}${_two(time.month)}${_two(time.day)}_'
      '${_two(time.hour)}${_two(time.minute)}${_two(time.second)}';

  /// `2026-10-04 21:33:10`：报告正文里的时间。
  static String formatTime(DateTime time) =>
      '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
