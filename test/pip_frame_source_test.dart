import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/pip_frame_source.dart';

/// 画中画帧源：节流、体积上限、统计。
///
/// 这一层的意义是「不让帧转发拖累播放」——画中画窗口不需要满帧，超限的帧
/// 必须被干脆丢掉，而不是堆积在通道里。
void main() {
  Uint8List pixels(int bytes) => Uint8List(bytes);

  test('未接原生：submitFrame 返回 false，不抛错', () async {
    final source = PipFrameSource();
    expect(source.isReady, isFalse);
    final ok = await source.submitFrame(
      pixels: pixels(16),
      width: 2,
      height: 2,
      timestamp: Duration.zero,
    );
    expect(ok, isFalse);
    expect(source.submittedFrames, 0);
  });

  test('接上原生：帧被送出并计数', () async {
    final source = PipFrameSource();
    final sent = <Map<String, Object?>>[];
    source.attach((frame) async => sent.add(frame));

    final ok = await source.submitFrame(
      pixels: pixels(16),
      width: 2,
      height: 2,
      timestamp: const Duration(seconds: 1),
    );

    expect(ok, isTrue);
    expect(source.submittedFrames, 1);
    expect(sent.single['width'], 2);
    expect(sent.single['height'], 2);
    expect(sent.single['timestampMs'], 1000);
    expect(sent.single['pixels'], isA<Uint8List>());
  });

  test('帧率节流：连续提交只有第一帧通过', () async {
    final source = PipFrameSource(maxFramesPerSecond: 30);
    source.attach((frame) async {});

    // 30fps → 最小间隔约 33ms；连续两次调用必然被限流。
    final first = await source.submitFrame(
      pixels: pixels(16),
      width: 2,
      height: 2,
      timestamp: Duration.zero,
    );
    final second = await source.submitFrame(
      pixels: pixels(16),
      width: 2,
      height: 2,
      timestamp: const Duration(milliseconds: 1),
    );

    expect(first, isTrue);
    expect(second, isFalse, reason: '间隔太短的帧被丢弃');
    expect(source.droppedForRate, 1);
  });

  test('体积上限：超大帧直接丢弃并计数', () async {
    final source = PipFrameSource(maxFrameBytes: 64);
    source.attach((frame) async {});

    final ok = await source.submitFrame(
      pixels: pixels(1024),
      width: 16,
      height: 16,
      timestamp: Duration.zero,
    );

    expect(ok, isFalse);
    expect(source.droppedForSize, 1);
    expect(source.submittedFrames, 0);
  });

  test('detach 后不再送帧', () async {
    final source = PipFrameSource();
    source.attach((frame) async {});
    source.detach();
    expect(source.isReady, isFalse);
    final ok = await source.submitFrame(
      pixels: pixels(16),
      width: 2,
      height: 2,
      timestamp: Duration.zero,
    );
    expect(ok, isFalse);
  });

  test('resetStats 清零计数（开始新一次画中画时调用）', () async {
    final source = PipFrameSource(maxFrameBytes: 8);
    source.attach((frame) async {});
    await source.submitFrame(
      pixels: pixels(100),
      width: 5,
      height: 5,
      timestamp: Duration.zero,
    );
    expect(source.droppedForSize, 1);

    source.resetStats();
    expect(source.droppedForSize, 0);
    expect(source.submittedFrames, 0);
  });

  test('describe 反映当前状态（诊断用）', () {
    final source = PipFrameSource();
    expect(source.describe(), contains('未接入'));
    source.attach((frame) async {});
    expect(source.describe(), contains('已就绪'));
  });
}
