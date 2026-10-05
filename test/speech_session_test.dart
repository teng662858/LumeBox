import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/speech/speech.dart';

/// 语音会话的验证：状态机、队列推进、位置换算、边界拒绝、失败不冒泡。
///
/// 用替身后端驱动 [SpeechSession]——原生合成器挡在 [SpeechBackend] 端口后面，
/// 因此在没有 AVSpeechSynthesizer 的机器（含 CI）上也能把这条链路验完。
void main() {
  late _FakeSpeechBackend backend;

  setUp(() {
    backend = _FakeSpeechBackend();
  });

  /// 造 [count] 个片段，每片**恰好** [length] 个字符（起点 = i * length）。
  ///
  /// 长度必须精确：位置换算的断言全依赖它（差一个字符就会让「段末 = 起点+长度」
  /// 这类断言看起来像实现错了）。
  List<SpeechSegment> segments(int count, {int length = 20}) => <SpeechSegment>[
        for (var i = 0; i < count; i++)
          SpeechSegment(
            // 前缀 '[i]' 便于断言「下发了哪一段」，剩余用「字」补足长度。
            text: () {
              final head = '[$i]';
              return head.length >= length
                  ? head
                  : head + '字' * (length - head.length);
            }(),
            start: i * length,
          ),
      ];

  /// 推一个引擎事件并等它送达。
  ///
  /// 事件流是异步的：`add` 之后必须让出事件循环，否则断言看到的是旧状态——
  /// 这不是实现问题，是测试必须遵守的时序。
  Future<void> emit(
    SpeechEventKind kind, {
    int? charOffset,
    String? message,
  }) async {
    backend.emit(kind, charOffset: charOffset, message: message);
    await pumpEventQueue();
  }

  /// 会话能力探测是异步的（走后端），等它落到 idle。
  Future<SpeechSession> openSession({
    void Function(int)? onPosition,
    void Function(int)? onSegmentFinished,
    void Function(SpeechEvent)? onEvent,
    Duration silenceTimeout = const Duration(seconds: 20),
  }) async {
    final session = SpeechSession(
      backend: backend,
      onPosition: onPosition,
      onSegmentFinished: onSegmentFinished,
      onEvent: onEvent,
      silenceTimeout: silenceTimeout,
    );
    await pumpEventQueue();
    return session;
  }

  group('能力探测与开始', () {
    test('后端支持：探测后落到 idle', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      expect(session.isSupported, isTrue);
      expect(session.state.value, SpeechState.idle);
    });

    test('后端不支持：如实落到 unavailable，且开始被拒', () async {
      backend.supported = false;
      final session = await openSession();
      addTearDown(session.dispose);

      expect(session.state.value, SpeechState.unavailable);
      final rejection = await session.start(segments(2));
      expect(rejection, isNotNull, reason: '不支持时必须给出可读原因');
      expect(session.state.value, SpeechState.unavailable);
      expect(backend.spoken, isEmpty, reason: '被拒时不该触达引擎');
    });

    test('探测抛错：按不支持处理，不把异常抛给页面', () async {
      backend.throwOnProbe = true;
      final session = await openSession();
      addTearDown(session.dispose);
      expect(session.state.value, SpeechState.unavailable);
    });

    test('空片段列表被拒（本章没有可朗读内容）', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      expect(await session.start(const <SpeechSegment>[]), '本章没有可朗读的内容');
      // 全空白片段同样被过滤。
      expect(
        await session.start(<SpeechSegment>[
          SpeechSegment(text: '', start: 0),
        ]),
        '本章没有可朗读的内容',
      );
    });

    test('开始朗读：只下发第一段，状态为朗读中', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      final rejection = await session.start(segments(3));

      expect(rejection, isNull);
      expect(session.state.value, SpeechState.speaking);
      expect(backend.spoken, hasLength(1), reason: '一次只下发一段');
      expect(backend.spoken.single, '[0]${'字' * 17}');
    });

    test('fromIndex 越界时收敛到合法范围', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(3), fromIndex: 99);
      expect(session.segmentIndex, 2, reason: '越界收到最后一段');
      expect(backend.spoken.single, startsWith('[2]'));
    });

    test('start 时引擎抛错：状态收敛，且给出失败事件', () async {
      final events = <SpeechEvent>[];
      final session = await openSession(onEvent: events.add);
      addTearDown(session.dispose);
      backend.throwOnSpeak = true;

      final rejection = await session.start(segments(1));
      expect(rejection, '朗读失败');
      expect(session.state.value, SpeechState.idle, reason: '失败后回到可重试状态');
      expect(
        events.map((e) => e.kind),
        contains(SpeechEventKind.failed),
      );
    });
  });

  group('队列推进与位置换算', () {
    test('一段读完自动续读下一段（引擎侧队列由会话管理）', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(3));

      await emit(SpeechEventKind.finished);
      expect(backend.spoken, hasLength(2));
      expect(backend.spoken.last, contains('[1]'));

      await emit(SpeechEventKind.finished);
      expect(backend.spoken, hasLength(3));
    });

    test('最后一段读完收敛到 idle（不空转）', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(2));
      await emit(SpeechEventKind.finished);
      await emit(SpeechEventKind.finished);

      expect(session.state.value, SpeechState.idle);
      expect(backend.spoken, hasLength(2), reason: '不该再下发');
    });

    test('全部读完才触发 onCompleted（连续听书的唯一依据）', () async {
      var completed = 0;
      final session = SpeechSession(
        backend: backend,
        onCompleted: () => completed++,
      );
      await pumpEventQueue();
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.finished);
      expect(completed, 0, reason: '只读完第一段不算读完本章');

      await emit(SpeechEventKind.finished);
      expect(completed, 1, reason: '最后一段读完才通知');
    });

    test('用户停止不触发 onCompleted（不该自动连下一章）', () async {
      var completed = 0;
      final session = SpeechSession(
        backend: backend,
        onCompleted: () => completed++,
      );
      await pumpEventQueue();
      addTearDown(session.dispose);
      await session.start(segments(3));

      await session.stop();
      await emit(SpeechEventKind.finished);
      expect(completed, 0, reason: '停止后即使引擎补发 finished 也不算读完');
    });

    test('位置换算：段内偏移 + 片段起点 = 整章偏移', () async {
      final positions = <int>[];
      final session = await openSession(onPosition: positions.add);
      addTearDown(session.dispose);
      // 三段，每段 20 字，起点 0 / 20 / 40。
      await session.start(segments(3));

      await emit(SpeechEventKind.progress, charOffset: 5);
      expect(positions.last, 5, reason: '第一段：0 + 5');

      await emit(SpeechEventKind.finished);
      await emit(SpeechEventKind.progress, charOffset: 7);
      expect(positions.last, 27, reason: '第二段：20 + 7');
      expect(session.position, 27);
    });

    test('段内偏移越界被钳制（引擎报错位置也不越界）', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.progress, charOffset: 9999);
      expect(session.position, 20, reason: '钳到本段末尾');

      await emit(SpeechEventKind.progress, charOffset: -5);
      expect(session.position, 0, reason: '负数钳到段首');
    });

    test('读完一段时位置推到段末，并通知跟读回调', () async {
      final finished = <int>[];
      final session = await openSession(onSegmentFinished: finished.add);
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.finished);
      expect(finished, <int>[20], reason: '第一段终点 = 起点 0 + 长度 20');
    });

    test('seekToSegment 跳段并下发目标段', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(4));

      final rejection = await session.seekToSegment(2);
      expect(rejection, isNull);
      expect(session.segmentIndex, 2);
      expect(session.position, 40, reason: '位置对齐到该段起点');
      expect(backend.spoken.last, startsWith('[2]'));
    });

    test('seekToSegment 越界收敛，且未开始时被拒', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      expect(await session.seekToSegment(1), '当前没有朗读内容');

      await session.start(segments(2));
      await session.seekToSegment(99);
      expect(session.segmentIndex, 1);
    });
  });

  group('暂停 / 继续 / 停止', () {
    test('暂停后状态为 paused，引擎不补事件也会收敛', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(2));

      expect(await session.pause(), isNull);
      expect(session.state.value, SpeechState.paused);
      expect(backend.paused, 1);
    });

    test('未朗读时暂停被拒；未暂停时继续被拒', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      expect(await session.pause(), '当前未在朗读');
      await session.start(segments(1));
      expect(await session.resume(), '当前未暂停');
    });

    test('继续：引擎 resume 后回到朗读中', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(2));
      await session.pause();

      expect(await session.resume(), isNull);
      expect(session.state.value, SpeechState.speaking);
      expect(backend.resumed, 1);
    });

    test('暂停期间跳段：继续时重新下发该段（引擎里已没有内容）', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(3));
      await session.pause();
      final spokenBefore = backend.spoken.length;

      await session.seekToSegment(2);
      expect(session.state.value, SpeechState.paused, reason: '跳段不改变暂停状态');
      expect(
        backend.spoken.length,
        spokenBefore,
        reason: '暂停中跳段不该立刻出声',
      );

      await session.resume();
      expect(backend.spoken.last, startsWith('[2]'), reason: '继续时从新位置读');
      expect(backend.resumed, 0, reason: '引擎里没内容，不该走 resume');
    });

    test('停止：清空队列并回到 idle', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(3));

      await session.stop();
      expect(session.state.value, SpeechState.idle);
      expect(session.segmentCount, 0);
      expect(backend.stopped, 1);

      // 停止后引擎再补发 finished 不该触发推进。
      await emit(SpeechEventKind.finished);
      expect(backend.spoken, hasLength(1), reason: '停止后不再续读');
    });

    test('引擎回报 paused / resumed / stopped 事件也能驱动状态', () async {
      final session = await openSession();
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.paused);
      expect(session.state.value, SpeechState.paused);
      await emit(SpeechEventKind.resumed);
      expect(session.state.value, SpeechState.speaking);
      await emit(SpeechEventKind.stopped);
      expect(session.state.value, SpeechState.idle);
    });
  });

  group('失败与超时', () {
    test('引擎失败事件：状态收敛并回调失败原因', () async {
      final events = <SpeechEvent>[];
      final session = await openSession(onEvent: events.add);
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.failed, message: '音频会话被系统中断');
      expect(session.state.value, SpeechState.idle);
      expect(events.last.kind, SpeechEventKind.failed);
      expect(events.last.message, '音频会话被系统中断');
    });

    test('引擎静默超时：按读完推进，不卡死', () async {
      final finished = <int>[];
      final session = await openSession(
        onSegmentFinished: finished.add,
        silenceTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(session.dispose);
      await session.start(segments(2));

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(finished, isNotEmpty, reason: '静默后按读完处理');
      expect(backend.spoken, hasLength(2), reason: '继续推进下一段');
    });

    test('引擎有动静就喂看门狗（不会误判长段为卡死）', () async {
      final session = await openSession(
        silenceTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(session.dispose);
      await session.start(segments(1));

      // 每 30ms 一次进度，持续 150ms：远超静默阈值，但一直有动静。
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        backend.emit(SpeechEventKind.progress, charOffset: i);
      }
      expect(
        session.state.value,
        SpeechState.speaking,
        reason: '持续有进度时不该被看门狗判为卡死',
      );
    });

    test('暂停期间看门狗不生效（暂停可以无限久）', () async {
      final session = await openSession(
        silenceTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(session.dispose);
      await session.start(segments(2));
      await session.pause();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.state.value, SpeechState.paused, reason: '暂停不该被超时打断');
    });
  });

  group('释放', () {
    test('dispose 时正在朗读：先停止再释放', () async {
      final session = await openSession();
      await session.start(segments(2));

      await session.dispose();
      expect(backend.stopped, 1, reason: '释放前必须停掉原生会话');
    });

    test('dispose 后一切调用安全（不抛错、不触达引擎）', () async {
      final session = await openSession();
      await session.start(segments(2));
      await session.dispose();

      expect(await session.start(segments(1)), '页面已销毁');
      expect(await session.pause(), '页面已销毁');
      expect(await session.seekToSegment(0), '页面已销毁');
      await session.stop();
      await session.dispose();
      expect(backend.spoken, hasLength(1), reason: '释放后不再触达引擎');
    });

    test('回调抛错不外溢（页面回调写错不影响朗读）', () async {
      final session = await openSession(
        onPosition: (_) => throw StateError('页面回调炸了'),
        onSegmentFinished: (_) => throw StateError('页面回调炸了'),
      );
      addTearDown(session.dispose);
      await session.start(segments(2));

      await emit(SpeechEventKind.progress, charOffset: 3);
      await emit(SpeechEventKind.finished);
      expect(backend.spoken, hasLength(2), reason: '回调异常不该中断队列推进');
    });
  });
}

/// 替身后端：记录调用、按需推事件。
class _FakeSpeechBackend implements SpeechBackend {
  bool supported = true;
  bool throwOnProbe = false;
  bool throwOnSpeak = false;

  final List<String> spoken = <String>[];
  int paused = 0;
  int resumed = 0;
  int stopped = 0;

  final StreamController<SpeechEvent> _events =
      StreamController<SpeechEvent>.broadcast();

  void emit(SpeechEventKind kind, {int? charOffset, String? message}) {
    _events.add(SpeechEvent(kind, charOffset: charOffset, message: message));
  }

  @override
  Future<bool> isSupported() async {
    if (throwOnProbe) throw StateError('探测失败');
    return supported;
  }

  @override
  Future<void> speak(String text) async {
    if (throwOnSpeak) throw StateError('合成器不可用');
    spoken.add(text);
  }

  @override
  Future<void> stop() async => stopped++;

  @override
  Future<void> pause() async => paused++;

  @override
  Future<void> resume() async => resumed++;

  @override
  Stream<SpeechEvent> get events => _events.stream;
}
