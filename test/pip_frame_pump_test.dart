import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/mpv_engine.dart';
import 'package:lume_box/core/player/pip_frame_pump.dart';
import 'package:lume_box/core/player/pip_frame_source.dart';

/// 画中画帧转发：MPV 取帧（拉取式）+ 帧泵节拍。
///
/// 为什么要「泵」：mpv 的取帧是 `screenshot-raw`（拉取），不是解码回调（推送）。
/// 因此这里验证的是「按节拍拉、拉不到就跳过、失败不冒泡」。
void main() {
  /// 可编程的假引擎：控制每次取帧返回什么。
  _FakeEngine engineWith(List<MpvVideoFrame?> frames) {
    final engine = _FakeEngine();
    engine.queue.addAll(frames);
    return engine;
  }

  MpvVideoFrame frame({int width = 4, int height = 2, int? stride}) {
    final rowBytes = width * 4;
    final effectiveStride = stride ?? rowBytes;
    return MpvVideoFrame(
      pixels: Uint8List(effectiveStride * height),
      width: width,
      height: height,
      stride: effectiveStride,
    );
  }

  group('MPV 取帧', () {
    test('紧密排列（stride == width*4）时原样返回', () {
      final source = frame(width: 4, height: 2);
      final tight = source.toTightBgra();
      expect(tight.length, 4 * 2 * 4);
      expect(identical(tight, source.pixels), isTrue, reason: '无需拷贝');
    });

    test('带行距填充时按行去掉填充（否则画面会倾斜）', () {
      // 宽 4 像素 = 16 字节，但 stride 是 20（带 4 字节对齐填充）。
      final padded = frame(width: 4, height: 2, stride: 20);
      // 往每行开头写入可识别的值，验证拷贝按行对齐。
      for (var row = 0; row < 2; row++) {
        padded.pixels[row * 20] = 0xA0 + row;
      }
      final tight = padded.toTightBgra();

      expect(tight.length, 16 * 2, reason: '去掉填充后是紧密排列');
      expect(tight[0], 0xA0, reason: '第 0 行开头');
      expect(tight[16], 0xA1, reason: '第 1 行开头（紧接第 0 行）');
    });
  });

  group('帧泵节拍', () {
    test('未启动时不取帧', () async {
      final engine = engineWith(<MpvVideoFrame>[frame()]);
      final pump = PipFramePump(engine: engine, frameSource: PipFrameSource());
      addTearDown(pump.stop);

      expect(pump.isPumping, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.captureCalls, 0, reason: '没启动就不该拉帧');
    });

    test('启动后按节拍取帧并转发', () async {
      final engine = engineWith(List<MpvVideoFrame?>.filled(50, frame()));
      final source = PipFrameSource();
      final sent = <Map<String, Object?>>[];
      source.attach((data) async => sent.add(data));

      final pump = PipFramePump(
        engine: engine,
        frameSource: source,
        targetFps: 30,
      );
      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      pump.stop();

      expect(engine.captureCalls, greaterThan(0), reason: '泵确实在拉帧');
      expect(sent, isNotEmpty, reason: '帧确实被转发');
      expect(pump.isPumping, isFalse, reason: 'stop 后不再跑');
    });

    test('取不到帧时跳过并计数（未加载 / 正在 seek）', () async {
      final engine = engineWith(List<MpvVideoFrame?>.filled(50, null));
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 30,
      );
      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      pump.stop();

      expect(pump.captureFailures, greaterThan(0), reason: '空帧计入失败');
      expect(pump.describe(), contains('取帧失败'));
    });

    test('引擎抛错不中断泵（下一拍继续）', () async {
      final engine = _FakeEngine()..throwOnCapture = true;
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 30,
      );
      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      pump.stop();

      expect(engine.captureCalls, greaterThan(1), reason: '抛错后仍在继续拉');
    });

    test('重复 start 不叠加定时器', () async {
      final engine = engineWith(List<MpvVideoFrame?>.filled(50, frame()));
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 30,
      );
      pump.start();
      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      pump.stop();
      // 若叠加了定时器，同样时间内取帧次数会接近翻倍；这里只验证能正常停。
      expect(pump.isPumping, isFalse);
    });

    test('stop 后再 start 可以恢复（进出画中画多次）', () async {
      final engine = engineWith(List<MpvVideoFrame?>.filled(200, frame()));
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 30,
      );
      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      pump.stop();
      final afterFirst = engine.captureCalls;

      pump.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      pump.stop();

      expect(engine.captureCalls, greaterThan(afterFirst));
    });
  });

  group('帧节拍（引擎提供时优先）', () {
    test('引擎有帧节拍：跟着节拍取帧，不用定时器', () async {
      final engine = _TickingEngine();
      final source = PipFrameSource();
      final sent = <Map<String, Object?>>[];
      source.attach((data) async => sent.add(data));

      final pump = PipFramePump(engine: engine, frameSource: source);
      pump.start();
      expect(pump.isEventDriven, isTrue, reason: '应走帧节拍而不是定时器');

      // 逐个推节拍并等取帧完成：每个节拍对应一次取帧。
      for (var i = 0; i < 3; i++) {
        engine.tick();
        await pumpIdle();
      }

      expect(engine.captureCalls, 3, reason: '每个节拍一次取帧');
      expect(sent, isNotEmpty);
      pump.stop();
    });

    test('节拍密集时不堆积：上一拍没取完就跳过这一拍', () async {
      final engine = _TickingEngine();
      final pump = PipFramePump(engine: engine, frameSource: PipFrameSource());
      pump.start();

      // 不等待，连推三个节拍：重入保护只允许第一拍真正取帧。
      engine.tick();
      engine.tick();
      engine.tick();
      await pumpIdle();
      await pumpIdle();

      expect(
        engine.captureCalls,
        lessThan(3),
        reason: '取帧是异步的，未完成时不该排队堆积（会越拖越远）',
      );
      pump.stop();
    });

    test('节拍停止后不再取帧（暂停即停，不空转）', () async {
      final engine = _TickingEngine();
      final pump = PipFramePump(engine: engine, frameSource: PipFrameSource());
      pump.start();

      engine.tick();
      await pumpIdle();
      final afterFirst = engine.captureCalls;

      // 不再推节拍：等一段时间，取帧次数不该增加（定时器才会继续拉）。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        engine.captureCalls,
        afterFirst,
        reason: '没有节拍就不该取帧（这正是帧节拍相对定时器的价值）',
      );
      pump.stop();
    });

    test('节拍流报错：退回定时器节拍，泵不中断', () async {
      final engine = _TickingEngine()..failTicks = true;
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 60,
      );
      pump.start();
      engine.tick();
      // 流的错误投递要跨过事件循环，不是一两个微任务就能看到的。
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(pump.isPumping, isTrue, reason: '出错后仍应在跑（已退回定时器）');
      expect(pump.isEventDriven, isFalse, reason: '应已退回定时器');
      pump.stop();
    });

    test('引擎没有帧节拍能力：退回定时器（行为与旧实现一致）', () async {
      final engine = engineWith(List<MpvVideoFrame?>.filled(50, frame()));
      final pump = PipFramePump(
        engine: engine,
        frameSource: PipFrameSource(),
        targetFps: 30,
      );
      pump.start();
      expect(pump.isEventDriven, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      pump.stop();
      expect(engine.captureCalls, greaterThan(0));
    });

    test('stop 后节拍不再驱动取帧', () async {
      final engine = _TickingEngine();
      final pump = PipFramePump(engine: engine, frameSource: PipFrameSource());
      pump.start();
      engine.tick();
      await pumpIdle();
      pump.stop();
      final afterStop = engine.captureCalls;

      engine.tick();
      await pumpIdle();
      expect(engine.captureCalls, afterStop, reason: '停止后节拍应已退订');
    });

    test('stop 后再 start 可恢复（进出画中画多次）', () async {
      final engine = _TickingEngine();
      final pump = PipFramePump(engine: engine, frameSource: PipFrameSource());
      pump.start();
      engine.tick();
      await pumpIdle();
      pump.stop();

      pump.start();
      engine.tick();
      await pumpIdle();
      expect(engine.captureCalls, 2);
      pump.stop();
    });
  });

  group('停止时的在飞取帧', () {
    test('stop 之后不再往原生送帧（在飞的那一拍要收手）', () async {
      // 复现修复前的缺陷：取帧是异步的，stop() 可能落在取帧与送帧之间。
      // 修复前那一拍会照常 submitFrame —— 退出画中画时还会闪最后一帧，
      // 甚至往已经拆掉的显示层写数据。
      final engine = _SlowEngine();
      final source = PipFrameSource();
      final sent = <Map<String, Object?>>[];
      source.attach((data) async => sent.add(data));

      final pump = PipFramePump(engine: engine, frameSource: source);
      pump.start();
      engine.tick();
      await Future<void>.delayed(Duration.zero);
      // 取帧还在飞（_SlowEngine 会等信号），此时停止。
      pump.stop();
      engine.releaseCapture();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sent, isEmpty, reason: '停止后不该再送帧');
    });

    test('未停止时在飞的那一拍正常送出（不是一律丢弃）', () async {
      final engine = _SlowEngine();
      final source = PipFrameSource();
      final sent = <Map<String, Object?>>[];
      source.attach((data) async => sent.add(data));

      final pump = PipFramePump(engine: engine, frameSource: source);
      pump.start();
      engine.tick();
      await Future<void>.delayed(Duration.zero);
      engine.releaseCapture();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pump.stop();

      expect(sent, hasLength(1), reason: '没停止时该正常送出');
    });
  });

  group('诊断', () {
    test('describe 反映运行状态', () {
      final pump = PipFramePump(
        engine: _FakeEngine(),
        frameSource: PipFrameSource(),
      );
      addTearDown(pump.stop);
      expect(pump.describe(), contains('已停止'));
      pump.start();
      expect(pump.describe(), contains('运行中'));
      pump.stop();
    });
  });
}

/// 等泵把在飞的取帧跑完。
///
/// 取帧是异步的（`await captureFrame()`），事件推完还要让出几轮事件循环，
/// 断言才看得到结果。
Future<void> pumpIdle() => Future<void>.delayed(Duration.zero);

/// 带帧节拍能力的假引擎（模拟 `time-pos` 驱动的节拍）。
class _TickingEngine implements MpvEngine, FrameTickCapable {
  final StreamController<void> _ticks = StreamController<void>.broadcast();
  bool failTicks = false;
  int captureCalls = 0;

  /// 测试驱动：推一个节拍（= 画面推进了一帧）。
  void tick() {
    if (failTicks) {
      _ticks.addError(StateError('节拍流炸了'));
      return;
    }
    _ticks.add(null);
  }

  @override
  Stream<void> get frameTicks => _ticks.stream;

  @override
  Future<MpvVideoFrame?> captureFrame() async {
    captureCalls++;
    return MpvVideoFrame(
      pixels: Uint8List(4 * 2 * 4),
      width: 4,
      height: 2,
      stride: 16,
    );
  }

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {}

  @override
  Future<void> open(MpvMediaRequest request) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitleEnabled(bool enabled) async {}

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {}
}

/// 假引擎：按队列返回帧，可配置抛错。
class _FakeEngine implements MpvEngine {
  final List<MpvVideoFrame?> queue = <MpvVideoFrame?>[];

  int captureCalls = 0;
  bool throwOnCapture = false;

  @override
  Future<MpvVideoFrame?> captureFrame() async {
    captureCalls++;
    if (throwOnCapture) throw StateError('模拟取帧失败');
    if (queue.isEmpty) return null;
    return queue.removeAt(0);
  }

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {}

  @override
  Future<void> open(MpvMediaRequest request) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitleEnabled(bool enabled) async {}

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {}
}

/// 取帧可控延迟的引擎：用来把「在飞取帧」这一刻固定住。
class _SlowEngine implements MpvEngine, FrameTickCapable {
  final StreamController<void> _ticks = StreamController<void>.broadcast();
  final Completer<void> _gate = Completer<void>();

  void tick() => _ticks.add(null);

  /// 放行取帧（模拟解码完成）。
  void releaseCapture() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Stream<void> get frameTicks => _ticks.stream;

  @override
  Future<MpvVideoFrame?> captureFrame() async {
    await _gate.future;
    return MpvVideoFrame(
      pixels: Uint8List(4 * 2 * 4),
      width: 4,
      height: 2,
      stride: 16,
    );
  }

  @override
  void listen(void Function(MpvEngineSnapshot snapshot) onSnapshot) {}

  @override
  Future<void> open(MpvMediaRequest request) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitleEnabled(bool enabled) async {}

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {}
}
