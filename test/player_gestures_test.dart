import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/video/player_gestures.dart';

/// 播放器手势的纯逻辑：意图判定、数值换算、倍速叠加。
///
/// 这些规则混在 widget 里就只能靠模拟手势去测（慢且脆），因此抽成纯函数单独验证。
void main() {
  group('意图判定', () {
    test('左侧上下滑 = 亮度，右侧 = 音量', () {
      expect(
        PlayerGesturePolicy.intentFor(dx: 0, dy: 40, startFraction: 0.2),
        PlayerGestureIntent.brightness,
      );
      expect(
        PlayerGesturePolicy.intentFor(dx: 0, dy: 40, startFraction: 0.8),
        PlayerGestureIntent.volume,
      );
      // 正中偏左也算亮度（0.5 是分界，取左）。
      expect(
        PlayerGesturePolicy.intentFor(dx: 0, dy: 40, startFraction: 0.49),
        PlayerGestureIntent.brightness,
      );
    });

    test('横向位移占优 = 调进度', () {
      expect(
        PlayerGesturePolicy.intentFor(dx: 60, dy: 10, startFraction: 0.2),
        PlayerGestureIntent.seek,
      );
      // 垂直占优时即使有横向分量也不算进度。
      expect(
        PlayerGesturePolicy.intentFor(dx: 10, dy: 60, startFraction: 0.2),
        PlayerGestureIntent.brightness,
      );
    });

    test('位移太小 = 不判定（手抖不该触发功能）', () {
      expect(
        PlayerGesturePolicy.intentFor(dx: 3, dy: 3, startFraction: 0.5),
        PlayerGestureIntent.none,
      );
      expect(
        PlayerGesturePolicy.intentFor(dx: 10, dy: 5, startFraction: 0.5),
        PlayerGestureIntent.none,
        reason: '横向 10px 未达阈值',
      );
    });

    test('阈值边界', () {
      expect(
        PlayerGesturePolicy.intentFor(
          dx: 0,
          dy: PlayerGesturePolicy.minVerticalDrag,
          startFraction: 0.1,
        ),
        PlayerGestureIntent.brightness,
        reason: '正好等于阈值即判定',
      );
      expect(
        PlayerGesturePolicy.intentFor(
          dx: PlayerGesturePolicy.minHorizontalDrag,
          dy: 0,
          startFraction: 0.1,
        ),
        PlayerGestureIntent.seek,
      );
    });
  });

  group('垂直滑动换算', () {
    test('向上滑增大、向下滑减小（与系统音量面板一致）', () {
      // 屏幕高 800，从 0.5 起，向上滑 200px（dy = -200）→ +25%
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.5,
          dy: -200,
          height: 800,
        ),
        closeTo(0.75, 0.001),
      );
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.5,
          dy: 200,
          height: 800,
        ),
        closeTo(0.25, 0.001),
      );
    });

    test('整屏高度对应 100%（滑半个屏幕改一半）', () {
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.0,
          dy: -800,
          height: 800,
        ),
        1.0,
      );
    });

    test('钳制在 0..1：滑过头不会越界', () {
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.9,
          dy: -500,
          height: 800,
        ),
        1.0,
      );
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.1,
          dy: 500,
          height: 800,
        ),
        0.0,
      );
    });

    test('高度非法时原样返回（不产生 NaN）', () {
      expect(
        PlayerGesturePolicy.applyVerticalDelta(
          startValue: 0.5,
          dy: 100,
          height: 0,
        ),
        0.5,
      );
    });
  });

  group('水平滑动换算（调进度）', () {
    const duration = Duration(minutes: 45);

    test('整屏宽度对应 90 秒（长视频里按比例滑会跳太久）', () {
      final target = PlayerGesturePolicy.applyHorizontalDelta(
        startPosition: const Duration(minutes: 10),
        duration: duration,
        dx: 400,
        width: 400,
      );
      expect(target, const Duration(minutes: 10) + const Duration(seconds: 90));
    });

    test('半屏 = 45 秒', () {
      final target = PlayerGesturePolicy.applyHorizontalDelta(
        startPosition: const Duration(minutes: 10),
        duration: duration,
        dx: 200,
        width: 400,
      );
      expect(target, const Duration(minutes: 10) + const Duration(seconds: 45));
    });

    test('左滑回退，且不会退到负数', () {
      expect(
        PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: const Duration(seconds: 30),
          duration: duration,
          dx: -400,
          width: 400,
        ),
        Duration.zero,
        reason: '回退超过起点即钳到 0',
      );
    });

    test('右滑不超过总时长', () {
      expect(
        PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: const Duration(minutes: 44),
          duration: duration,
          dx: 400,
          width: 400,
        ),
        duration,
      );
    });

    test('自定义窗口时长生效', () {
      final target = PlayerGesturePolicy.applyHorizontalDelta(
        startPosition: Duration.zero,
        duration: duration,
        dx: 400,
        width: 400,
        window: const Duration(seconds: 30),
      );
      expect(target, const Duration(seconds: 30));
    });

    test('时长未知 / 宽度非法时原样返回', () {
      expect(
        PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: const Duration(seconds: 5),
          duration: Duration.zero,
          dx: 100,
          width: 400,
        ),
        const Duration(seconds: 5),
      );
      expect(
        PlayerGesturePolicy.applyHorizontalDelta(
          startPosition: const Duration(seconds: 5),
          duration: duration,
          dx: 100,
          width: 0,
        ),
        const Duration(seconds: 5),
      );
    });
  });

  group('长按倍速', () {
    test('在用户倍速基础上翻倍，上限 3x', () {
      expect(PlayerGesturePolicy.boostSpeed(1.0), 2.0);
      expect(PlayerGesturePolicy.boostSpeed(1.5), 3.0);
      expect(PlayerGesturePolicy.boostSpeed(2.0), 3.0, reason: '2x 翻倍会到 4x，钳到 3x');
    });

    test('已经很快时不再叠加（3x 上再叠会失真到没法听）', () {
      expect(PlayerGesturePolicy.boostSpeed(2.5), 2.5);
      expect(PlayerGesturePolicy.boostSpeed(3.0), 3.0);
    });
  });

  group('提示文案', () {
    test('亮度 / 音量给百分比', () {
      expect(
        PlayerGesturePolicy.describe(
          PlayerGestureIntent.brightness,
          value: 0.42,
        ),
        '亮度 42%',
      );
      expect(
        PlayerGesturePolicy.describe(PlayerGestureIntent.volume, value: 0.8),
        '音量 80%',
      );
    });

    test('进度给时间；超过一小时带小时位', () {
      expect(
        PlayerGesturePolicy.describe(
          PlayerGestureIntent.seek,
          position: const Duration(minutes: 3, seconds: 7),
        ),
        '3:07',
      );
      expect(
        PlayerGesturePolicy.describe(
          PlayerGestureIntent.seek,
          position: const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
    });

    test('快进与无意图', () {
      expect(
        PlayerGesturePolicy.describe(PlayerGestureIntent.boost, speed: 2.0),
        contains('快进'),
      );
      expect(PlayerGesturePolicy.describe(PlayerGestureIntent.none), '');
    });
  });

  group('手势状态', () {
    test('idle 状态无提示', () {
      expect(PlayerGestureState.idle.active, isFalse);
      expect(PlayerGestureState.idle.hint, '');
    });

    test('copyWith 保留未指定的字段', () {
      const state = PlayerGestureState(volume: 0.6, brightness: 0.3, active: true);
      final next = state.copyWith(intent: PlayerGestureIntent.volume);
      expect(next.volume, 0.6);
      expect(next.brightness, 0.3);
      expect(next.active, isTrue);
      expect(next.intent, PlayerGestureIntent.volume);
    });

    test('clearSeekTarget 能清掉目标（结束手势时用）', () {
      const state = PlayerGestureState(seekTarget: Duration(seconds: 30));
      expect(
        state.copyWith(clearSeekTarget: true).seekTarget,
        isNull,
      );
      // 不传 clear 时保留。
      expect(state.copyWith(intent: PlayerGestureIntent.seek).seekTarget, isNotNull);
    });
  });

  group('意图枚举', () {
    test('每项都有稳定 id 与中文标签', () {
      for (final intent in PlayerGestureIntent.values) {
        expect(intent.id, isNotEmpty);
        expect(intent.label, isNotEmpty);
      }
    });
  });
}
