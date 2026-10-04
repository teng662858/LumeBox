import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/util/lume_log.dart';

/// 运行日志底座的验证：级别与内容、环形缓冲上限、清空与变更信号。
void main() {
  setUp(LumeLog.clear);
  tearDown(LumeLog.clear);

  test('记录级别、内容与错误堆栈', () {
    LumeLog.info('普通消息');
    LumeLog.warn('警告消息');
    LumeLog.error(StateError('炸了'), StackTrace.current);

    final entries = LumeLog.snapshot;
    expect(entries.map((entry) => entry.level), <LogLevel>[
      LogLevel.info,
      LogLevel.warn,
      LogLevel.error,
    ]);
    expect(entries.first.message, '普通消息');
    expect(entries[1].message, '警告消息');
    expect(entries.last.message, contains('炸了'));
    expect(entries.last.detail, isNotNull, reason: '错误带堆栈细节');
    expect(entries.first.detail, isNull);
    // 快照不可变：外部改不动内部缓冲。
    expect(() => LumeLog.snapshot.clear(), throwsUnsupportedError);
  });

  test('环形缓冲：超过上限丢最旧的，保留最近的', () {
    for (var index = 0; index < LumeLog.bufferLimit + 20; index++) {
      LumeLog.info('m$index');
    }

    final entries = LumeLog.snapshot;
    expect(entries, hasLength(LumeLog.bufferLimit));
    expect(entries.first.message, 'm20');
    expect(entries.last.message, 'm${LumeLog.bufferLimit + 19}');
  });

  test('清空：内容清空并只发一次变更信号', () async {
    LumeLog.info('x');
    final signals = <int>[];
    final subscription = LumeLog.changes.listen((_) => signals.add(1));
    addTearDown(subscription.cancel);

    LumeLog.clear();
    await Future<void>.delayed(Duration.zero);
    expect(LumeLog.snapshot, isEmpty);
    expect(signals, hasLength(1));

    // 已经为空：不再发信号。
    LumeLog.clear();
    await Future<void>.delayed(Duration.zero);
    expect(signals, hasLength(1));
  });

  test('新增日志会发出变更信号', () async {
    final signals = <int>[];
    final subscription = LumeLog.changes.listen((_) => signals.add(1));
    addTearDown(subscription.cancel);

    LumeLog.info('a');
    LumeLog.error(StateError('b'));
    await Future<void>.delayed(Duration.zero);

    expect(signals, hasLength(2));
  });
}
