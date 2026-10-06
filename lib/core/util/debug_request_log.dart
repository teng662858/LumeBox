import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/lume_log.dart';

/// 一条网络请求记录（调试面板用）。
@immutable
class DebugRequestRecord {
  const DebugRequestRecord({
    required this.time,
    required this.method,
    required this.url,
    required this.source,
    required this.host,
    required this.status,
    required this.elapsed,
    required this.requestHeaders,
    this.responseBytes = 0,
    this.error = '',
    this.note = '',
  });

  final DateTime time;
  final String method;
  final String url;

  /// 请求来源（哪个图源 / 哪个模块在发）。
  final String source;
  final String host;

  /// HTTP 状态码；0 表示请求没能完成（连接失败 / 超时）。
  final int status;
  final Duration elapsed;

  /// 请求头（已脱敏：Cookie 之类的凭据只留存在标记）。
  final Map<String, String> requestHeaders;

  /// 响应体字节数。
  final int responseBytes;

  /// 失败原因（状态码为 0 时有值）。
  final String error;

  /// 过程说明（如「第 2 次重试」）。
  final String note;

  bool get isFailure => status == 0 || status >= 400;

  /// 一行摘要：`GET 200 128ms example.com`。
  String describe() {
    final statusText = status == 0 ? '失败' : '$status';
    return '$method $statusText ${elapsed.inMilliseconds}ms $host';
  }
}

/// 请求抓包缓冲：**只在开发者模式开启时记录**（文档「调试日志规范」）。
///
/// ## 为什么默认关闭且只留内存
///
/// 抓包记录含请求头与 URL，属于用户隐私面。因此：
/// - **默认不记录**（[enabled] 为 false 时 [record] 直接返回，零开销）；
/// - 只在设置页的开发者模式里手动打开；
/// - 只留最近 [limit] 条在内存里，进程退出即清空——**不落盘、不导出**，
///   避免「调试开关忘了关，抓包数据留在设备上」。
///
/// ## 脱敏
///
/// 请求头里的凭据类字段（`Cookie` / `Authorization` / `Set-Cookie`）只记录
/// 「存在」而不记录值：面板是给人看的，不该成为泄露凭据的窗口。
class DebugRequestLog {
  DebugRequestLog._();

  /// 内存里保留的记录条数上限。
  static const int limit = 200;

  /// 是否记录。默认关闭，由设置页的开发者模式开关打开。
  static bool _enabled = false;

  static bool get enabled => _enabled;

  static final List<DebugRequestRecord> _records = <DebugRequestRecord>[];

  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// 记录变化信号（面板据此刷新）。
  static Stream<void> get changes => _changes.stream;

  /// 当前记录快照（新 → 旧）。
  static List<DebugRequestRecord> get snapshot =>
      List<DebugRequestRecord>.unmodifiable(_records.reversed);

  /// 开关。打开时记一条日志（开关动作本身要可审计）。
  static void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    LumeLog.info('[debug] 请求抓包${value ? '已开启' : '已关闭'}');
    if (!value) clear();
    _notify();
  }

  /// 记一条请求。未开启时直接返回（调用方不必判断开关）。
  static void record(DebugRequestRecord record) {
    if (!_enabled) return;
    _records.add(record);
    while (_records.length > limit) {
      _records.removeAt(0);
    }
    _notify();
  }

  static void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    _notify();
  }

  static void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 请求头脱敏：凭据类字段只留存在标记，其余原样。
  static Map<String, String> redactHeaders(Map<String, String> headers) {
    const sensitive = <String>{
      'cookie',
      'set-cookie',
      'authorization',
      'proxy-authorization',
    };
    final result = <String, String>{};
    headers.forEach((key, value) {
      if (sensitive.contains(key.toLowerCase())) {
        result[key] = '（已隐藏，${value.length} 字符）';
      } else {
        result[key] = value;
      }
    });
    return result;
  }

  /// 仅测试用：复位。
  @visibleForTesting
  static void resetForTesting() {
    _records.clear();
    _enabled = false;
  }
}
