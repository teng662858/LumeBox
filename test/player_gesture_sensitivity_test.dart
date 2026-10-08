import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/mpv_engine.dart';
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

/// 字幕三项（用户口径）：字体 / 阴影强度 / 垂直偏移。
///
/// 口径：字体**只给系统字体**（思源黑体没随包内置，选了会被系统回落）；
/// 阴影强度与垂直偏移都夹在 0..1 / -1..1，写脏值不会把字幕顶出画面。
void subtitleStyleTests() {
  test('三项默认值：系统字体 / 无阴影 / 不偏移', () {
    const prefs = KernelPrefs();
    expect(prefs.subtitleFont, '');
    expect(prefs.subtitleShadow, 0.0);
    expect(prefs.subtitleOffsetY, 0.0);
    expect(PlayerSettings().subtitleFont, '');
  });

  test('copyWith 三项写读一致，且越界值被夹回范围', () {
    const settings = PlayerSettings();
    final styled = settings.copyWith(
      subtitleFont: 'PingFang SC',
      subtitleShadow: 0.6,
      subtitleOffsetY: -0.4,
    );
    expect(styled.subtitleFont, 'PingFang SC');
    expect(styled.subtitleShadow, closeTo(0.6, 1e-9));
    expect(styled.subtitleOffsetY, closeTo(-0.4, 1e-9));

    expect(settings.copyWith(subtitleShadow: 9).subtitleShadow, 1.0);
    expect(settings.copyWith(subtitleShadow: -9).subtitleShadow, 0.0);
    expect(settings.copyWith(subtitleOffsetY: 9).subtitleOffsetY, 1.0);
    expect(settings.copyWith(subtitleOffsetY: -9).subtitleOffsetY, -1.0);
  });

  test('样式落到 MPV 的 SubtitleStyle：三项原样带过去', () {
    const style = SubtitleStyle(
      fontFamily: 'Heiti SC',
      shadowStrength: 0.5,
      offsetY: -0.25,
    );
    expect(style.fontFamily, 'Heiti SC');
    expect(style.shadowStrength, 0.5);
    expect(style.offsetY, -0.25);
  });
}

  group('字幕样式三项', subtitleStyleTests);
}
