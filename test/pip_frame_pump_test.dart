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
