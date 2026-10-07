import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/skip_marks.dart';

/// 片头片尾标记与跳过判定（用户口径：播放中「记一下」，下次自动跳过）。
void main() {
  group('标记的存取（宽容解析）', () {
    test('往返：往返到毫秒，空标记序列化为空对象', () {
      const marks = SkipMarks(
        intro: Duration(seconds: 95),
        outro: Duration(minutes: 42),
      );
      final restored = SkipMarks.fromJson(marks.toJson());
      expect(restored, marks);
      expect(SkipMarks.none.toJson(), isEmpty);
    });

    test('坏值只影响那一项（另一项照常）', () {
      final marks = SkipMarks.fromJson(<String, Object?>{
        'introMs': 'oops',
        'outroMs': 120000,
      });
      expect(marks.intro, isNull);
      expect(marks.outro, const Duration(minutes: 2));

      // 0 / 负数一律当成「没标」。
      expect(SkipMarks.fromJson(<String, Object?>{'introMs': 0}).hasIntro, isFalse);
      expect(SkipMarks.fromJson(<String, Object?>{'outroMs': -5}).hasOutro, isFalse);
    });

    test('copyWith 与清除', () {
      const marks = SkipMarks(intro: Duration(seconds: 30));
      expect(marks.copyWith(outro: const Duration(minutes: 40)).intro,
          const Duration(seconds: 30));
      expect(marks.copyWith(clearIntro: true).isEmpty, isTrue);
    });
  });

  group('跳过判定', () {
    const marks = SkipMarks(
      intro: Duration(seconds: 90),
      outro: Duration(minutes: 40),
    );

    test('片头：起播位置早于标记 → 跳到标记（只判一次）', () {
      expect(
        SkipDecision.resolve(
          marks: marks,
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: false,
          hasNext: true,
        ),
        const SkipOutcome.seekTo(Duration(seconds: 90)),
      );

      // 已经判过（用户手动拖回片头看）→ 不再弹回去。
      expect(
        SkipDecision.resolve(
          marks: marks,
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: true,
          hasNext: true,
        ).action,
        SkipAction.none,
      );
    });

    test('片头：开关关掉就不跳', () {
      expect(
        SkipDecision.resolve(
          marks: marks,
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 45),
          introEnabled: false,
          outroEnabled: true,
          introHandled: false,
          hasNext: true,
        ).action,
        SkipAction.none,
      );
    });

    test('片尾：到点且还有下一集 → 直接连播下一集', () {
      expect(
        SkipDecision.resolve(
          marks: marks,
          position: const Duration(minutes: 40),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: true,
          hasNext: true,
        ),
        const SkipOutcome.advance(),
      );
    });

    test('片尾：最后一集 → 跳到结尾（停住）', () {
      expect(
        SkipDecision.resolve(
          marks: marks,
          position: const Duration(minutes: 41),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: true,
          hasNext: false,
        ),
        const SkipOutcome.seekTo(Duration(minutes: 45)),
      );
    });

    test('越界标记不生效（不拿坏数据折腾播放器）', () {
      const bad = SkipMarks(intro: Duration(minutes: 50)); // 比时长还长
      expect(
        SkipDecision.resolve(
          marks: bad,
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: false,
          hasNext: true,
        ).action,
        SkipAction.none,
      );
    });

    test('没标记 → 一律不跳', () {
      expect(
        SkipDecision.resolve(
          marks: SkipMarks.none,
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 45),
          introEnabled: true,
          outroEnabled: true,
          introHandled: false,
          hasNext: true,
        ).action,
        SkipAction.none,
      );
    });
  });
}
