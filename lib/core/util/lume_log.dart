import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sensitive_data.dart';

/// 日志级别。
enum LogLevel {
  info('info', '信息'),
  warn('warn', '警告'),
  error('error', '错误');

  const LogLevel(this.id, this.label);

  /// 稳定标识：展示与导出用。
  final String id;

  /// 中文短标签。
  final String label;
}

/// 一条运行日志。
@immutable
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
    this.detail,
  });

  final DateTime time;

  final LogLevel level;

  final String message;

  /// 附加细节（错误堆栈等）；无则 null。
  final String? detail;
}

/// 统一日志出口。所有输出统一使用项目名称 Lume Box。
///
/// 除了转发到 `dart:developer`，还会在内存里保留最近 [bufferLimit] 条，供
/// 「运行日志」页面查看与「错误报告」导出。只保留当前运行会话的日志：
/// 不做磁盘滚动（任务书只要求运行日志与报告导出，见 Phase3 文档）。
class LumeLog {
  static File? _journal;
  static Timer? _journalTimer;
  static Future<void> _writing = Future.value();
  static List<LogEntry> previousSession = [];
  static final List<LogEntry> _persistent = [];
  static String _diskText(String text) =>
      SensitiveData.redactUrlPaths(SensitiveData.redact(text))
          .replaceAll(
            RegExp(r'\b[A-Za-z]:[\\/][^\r\n"<>]+'),
            '[local path omitted]',
          )
          .replaceAll(
            RegExp(r'/(Users|home|private|var|data|storage)/[^\s"<>]+'),
            '[local path omitted]',
          );

  static Future<void> startPersistence({Directory? directory}) async {
    final base = directory ?? await getApplicationSupportDirectory();
    final file = File('${base.path}/last-session-errors.json');
    await flushPersistence();
    previousSession = [];
    if (await file.exists()) {
      try {
        if (await file.length() <= 128 * 1024) {
          final raw = jsonDecode(await file.readAsString()) as List;
          previousSession = [
            for (final row in raw.take(80))
              if (row is Map)
                LogEntry(
                  time: DateTime.tryParse('${row['time']}') ?? DateTime.now(),
                  level:
                      LogLevel.values
                          .where((level) => level.id == row['level'])
                          .firstOrNull ??
                      LogLevel.error,
                  message: _diskText('${row['message']}'),
                  detail: row['detail'] == null
                      ? null
                      : _diskText('${row['detail']}'),
                ),
          ];
        }
      } catch (_) {}
    }
    _journal = file;
    _persistent.clear();
    // Preserve the previous session until this session actually has an issue.
  }

  static Future<void> stopPersistence() async {
    await flushPersistence();
    _journal = null;
    _persistent.clear();
  }

  static Future<void> flushPersistence() async {
    _journalTimer?.cancel();
    _journalTimer = null;
    final file = _journal;
    if (file == null || _persistent.isEmpty) {
      await _writing;
      return;
    }
    final entries = [
      for (final e in _persistent)
        {
          'time': e.time.toIso8601String(),
          'level': e.level.id,
          'message': _diskText(e.message)
              .substring(0, _diskText(e.message).length.clamp(0, 2000)),
          'detail': e.detail == null
              ? null
              : _diskText(e.detail!)
                    .substring(0, _diskText(e.detail!).length.clamp(0, 4000)),
        },
    ];
    while (utf8.encode(jsonEncode(entries)).length > 128 * 1024 &&
        entries.length > 1) {
      entries.removeAt(0);
    }
    final text = jsonEncode(entries);
    _writing = _writing.catchError((Object _) {}).then((_) async {
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(file.path);
      } catch (_) {}
    });
    await _writing;
  }

  static const String tag = 'Lume Box';

  /// 内存里保留的日志条数上限。
  static const int bufferLimit = 500;

  static final List<LogEntry> _buffer = <LogEntry>[];

  /// 变更信号：事件只表示「日志变了」，页面读 [snapshot] 取内容。
  ///
  /// 用流而不是 ValueNotifier：流的投递在微任务里发生，构建过程中产生的日志
  /// 不会在构建中触发监听方 setState。
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// 日志变化的信号流。
  static Stream<void> get changes => _changes.stream;

  /// 当前日志快照（旧 → 新）。
  static List<LogEntry> get snapshot => List<LogEntry>.unmodifiable(_buffer);

  static void info(String message) {
    message = SensitiveData.redact(message);
    developer.log(message, name: tag);
    _record(LogLevel.info, message);
  }

  /// Flush the last native playback stage before entering code that can
  /// terminate the process without returning a Dart exception.
  static Future<void> playbackCheckpoint(String message) async {
    _record(LogLevel.info, SensitiveData.redact(message), persist: true);
    await flushPersistence();
  }

  static void warn(String message) {
    message = SensitiveData.redact(message);
    developer.log(message, name: tag, level: 900);
    _record(LogLevel.warn, message);
  }

  static void error(Object error, [StackTrace? stackTrace]) {
    final message = SensitiveData.redact('$error');
    final detail = stackTrace == null
        ? null
        : SensitiveData.redact('$stackTrace');
    developer.log(
      message,
      name: tag,
      error: message,
      stackTrace: detail == null ? null : StackTrace.fromString(detail),
      level: 1000,
    );
    _record(LogLevel.error, message, detail: detail);
  }

  /// 清空本次、上次日志，并在写入队列中删除磁盘副本。
  static void clear() {
    if (_buffer.isEmpty && previousSession.isEmpty && _persistent.isEmpty) {
      return;
    }
    _buffer.clear();
    previousSession = [];
    _persistent.clear();
    _journalTimer?.cancel();
    final file = _journal;
    if (file != null) {
      _writing = _writing.catchError((Object _) {}).then((_) async {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      });
    }
    _changes.add(null);
  }

  static void _record(
    LogLevel level,
    String message, {
    String? detail,
    bool persist = false,
  }) {
    if (_journal != null && (persist || level != LogLevel.info)) {
      _persistent.add(
        LogEntry(
          time: DateTime.now(),
          level: level,
          message: message,
          detail: detail,
        ),
      );
      if (_persistent.length > 80) _persistent.removeAt(0);
      _journalTimer?.cancel();
      _journalTimer = Timer(
        const Duration(milliseconds: 200),
        () => unawaited(flushPersistence()),
      );
    }
    _buffer.add(
      LogEntry(
        time: DateTime.now(),
        level: level,
        message: message,
        detail: detail,
      ),
    );
    if (_buffer.length > bufferLimit) {
      _buffer.removeRange(0, _buffer.length - bufferLimit);
    }
    _changes.add(null);
  }
}
