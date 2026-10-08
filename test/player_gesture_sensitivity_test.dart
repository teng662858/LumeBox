import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/features/video/player_gestures.dart';

/// 手势灵敏度（用户口径：亮度 / 音量的垂直滑动幅度可自定义）。
///
/// 口径：一屏高度对应「100% × 灵敏度」。1.0 是原来的手感；调大更灵敏，
/// 调小更稳。左右横滑调进度**不受**这个设置影响。
void main() {
  test('灵敏度倍率直接缩放垂直滑动的幅度', () {
    // 向上滑 1/4 屏：默认 1.0 → +25%。
    expect(
      PlayerGesturePolicy.applyVerticalDelta(
        startValue: 0.5,
        dy: -100,
        height: 400,
      ),
      closeTo(0.75, 1e-9),
    );
    // 2.0 倍 → +50%（同样一段滑动改变更多）。
    expect(
      PlayerGesturePolicy.applyVerticalDelta(
        startValue: 0.5,
        dy: -100,
        height: 400,
        sensitivity: 2.0,
      ),
      closeTo(1.0, 1e-9),
    );
    // 0.5 倍 → +12.5%（更稳）。
    expect(
      PlayerGesturePolicy.applyVerticalDelta(
        startValue: 0.5,
        dy: -100,
        height: 400,
        sensitivity: 0.5,
      ),
      closeTo(0.625, 1e-9),
    );
  });

  test('结果仍被夹在 0..1（灵敏度放大也不例外）', () {
    expect(
      PlayerGesturePolicy.applyVerticalDelta(
        startValue: 0.9,
        dy: -400,
        height: 400,
        sensitivity: 2.0,
      ),
      1.0,
    );
    expect(
      PlayerGesturePolicy.applyVerticalDelta(
        startValue: 0.1,
        dy: 400,
        height: 400,
        sensitivity: 2.0,
      ),
      0.0,
    );
  });

  test('设置里的灵敏度只在 0.5~2.0 之间，写进去的怪值会被夹住', () {
    const settings = PlayerSettings();
    expect(settings.gestureSensitivity, 1.0, reason: '默认是一屏 100% 的原口径');
    expect(
      settings.copyWith(gestureSensitivity: 99).gestureSensitivity,
      PlayerSettings.maxGestureSensitivity,
    );
    expect(
      settings.copyWith(gestureSensitivity: 0.01).gestureSensitivity,
      PlayerSettings.minGestureSensitivity,
    );
  });
}
