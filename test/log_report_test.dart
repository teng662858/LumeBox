import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/features/settings/log_report.dart';

/// 错误报告的验证：概览统计、报告文本汇编、落盘导出（含同名加序号与失败路径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  final fixedNow = DateTime(2026, 10, 4, 21, 33, 10);
  const exporter = LogExporter(now: _fixedNow);

  LogEntry entry(LogLevel level, String message, {String? detail, DateTime? at}) =>
      LogEntry(
        time: at ?? DateTime(2026, 10, 4, 21, 30),
        level: level,
        message: message,
        detail: detail,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_report');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('概览：计数、时间范围与「有没有问题」', () {
    final summary = LogExporter.summarize(<LogEntry>[
      entry(LogLevel.info, '普通'),
      entry(LogLevel.warn, '警告'),
      entry(LogLevel.error, '错误'),
    ]);

    expect(summary.total, 3);
    expect(summary.errors, 1);
    expect(summary.warnings, 1);
    expect(summary.hasProblems, isTrue);
    expect(summary.first, isNotNull);
    expect(summary.last, isNotNull);

    expect(LogExporter.summarize(const <LogEntry>[]).isEmpty, isTrue);
    expect(LogExporter.summarize(const <LogEntry>[]).hasProblems, isFalse);
  });

  test('报告文本：抬头、统计、逐条与堆栈细节', () {
    final text = LogExporter.build(
      <LogEntry>[
        entry(LogLevel.error, '炸了', detail: 'stack line 1\nstack line 2'),
        entry(LogLevel.info, '一切正常'),
      ],
      generatedAt: fixedNow,
    );

    expect(text, contains('Lume Box 运行日志报告'));
    expect(text, contains('生成时间：2026-10-04 21:33:10'));
    expect(text, contains('日志条数：共 2 条（错误 1 / 警告 0 / 信息 1）'));
    expect(text, contains('时间范围：2026-10-04 21:30:00 ~ 2026-10-04 21:30:00'));
    expect(text, contains('[2026-10-04 21:30:00] 错误 炸了'));
    expect(text, contains('    stack line 1'));
    expect(text, contains('[2026-10-04 21:30:00] 信息 一切正常'));
  });

  test('空日志的报告：明确写「无」而不是报错', () {
    final text = LogExporter.build(const <LogEntry>[], generatedAt: fixedNow);
    expect(text, contains('日志条数：共 0 条'));
    expect(text, contains('时间范围：无'));
  });

  test('导出：落盘到应用目录 logs/，内容与文件名可预期；同名自动加序号', () async {
    final entries = <LogEntry>[entry(LogLevel.error, '炸了')];

    final first = await exporter.export(entries);
    expect(first.file.existsSync(), isTrue);
    expect(
      first.file.path,
      contains('${Platform.pathSeparator}logs${Platform.pathSeparator}'),
      reason: '报告落在应用目录的 logs/ 下，不属于任何板块',
    );
    expect(first.file.path, endsWith('log_report_20261004_213310.txt'));
    expect(first.content, contains('炸了'));
    expect(first.entries, 1);
    expect(
      await first.file.readAsString(),
      first.content,
      reason: '落盘内容与返回的报告全文一致',
    );
    expect(first.bytes, utf8.encode(first.content).length);

    // 同一秒内二次导出：不覆盖，加序号。
    final second = await exporter.export(entries);
    expect(second.file.path, endsWith('log_report_20261004_213310-1.txt'));
    expect(first.file.existsSync(), isTrue);
  });

  test('导出失败：报出可读异常（页面转成提示）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => null,
    );

    await expectLater(
      exporter.export(<LogEntry>[entry(LogLevel.info, 'x')]),
      throwsA(isA<Exception>()),
    );
  });
}

DateTime _fixedNow() => DateTime(2026, 10, 4, 21, 33, 10);
