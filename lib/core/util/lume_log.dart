import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

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
    developer.log(message, name: tag);
    _record(LogLevel.info, message);
  }

  static void warn(String message) {
    developer.log(message, name: tag, level: 900);
    _record(LogLevel.warn, message);
  }

  static void error(Object error, [StackTrace? stackTrace]) {
    developer.log(
      '$error',
      name: tag,
      error: error,
      stackTrace: stackTrace,
      level: 1000,
    );
    _record(LogLevel.error, '$error', detail: stackTrace?.toString());
  }

  /// 清空内存日志（磁盘上没有任何日志文件，清理是即时的）。
  static void clear() {
    if (_buffer.isEmpty) return;
    _buffer.clear();
    _changes.add(null);
  }

  static void _record(LogLevel level, String message, {String? detail}) {
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
