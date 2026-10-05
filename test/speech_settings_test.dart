import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/speech/speech.dart';

/// 听书设置与原生通道契约的验证。
///
/// 通道解码（[MethodChannelSpeechBackend.decodeEvent]）是原生与 Dart 的接缝：
/// 这里固定载荷格式，Swift 侧按同一份契约发事件即可生效。
void main() {
  // 通道测试要用到 mock messenger，必须先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeechSettings', () {
    test('默认值：语速 0.5（系统默认）、跟读开、单片 1000 字', () {
      const settings = SpeechSettings();
      expect(settings.rate, 0.5);
      expect(settings.pitch, 1.0);
      expect(settings.volume, 1.0);
      expect(settings.followAlong, isTrue);
      expect(settings.maxCharsPerSegment, 1000);
    });

    test('编解码往返：所有字段保持不变', () {
      const original = SpeechSettings(
        rate: 0.8,
        pitch: 1.4,
        volume: 0.6,
        followAlong: false,
        maxCharsPerSegment: 500,
      );
      final restored = SpeechSettings.decode(original.encode());
      expect(restored.rate, original.rate);
      expect(restored.pitch, original.pitch);
      expect(restored.volume, original.volume);
      expect(restored.followAlong, original.followAlong);
      expect(restored.maxCharsPerSegment, original.maxCharsPerSegment);
    });

    test('越界值收敛到合法范围（引擎拿到越界值会抛错）', () {
      final clamped = const SpeechSettings().copyWith(
        rate: 5.0,
        pitch: -1,
        volume: 3,
        maxCharsPerSegment: 99999,
      );
      expect(clamped.rate, SpeechSettings.maxRate);
      expect(clamped.pitch, SpeechSettings.minPitch);
      expect(clamped.volume, SpeechSettings.maxVolume);
      expect(clamped.maxCharsPerSegment, SpeechSettings.maxSegmentChars);

      final clampedLow = const SpeechSettings().copyWith(
        rate: -2,
        maxCharsPerSegment: 1,
      );
      expect(clampedLow.rate, SpeechSettings.minRate);
      expect(clampedLow.maxCharsPerSegment, SpeechSettings.minSegmentChars);
    });

    test('库被改坏：坏 JSON / 错类型 / 缺字段都退回默认值', () {
      expect(SpeechSettings.decode(null).rate, 0.5);
      expect(SpeechSettings.decode('').rate, 0.5);
      expect(SpeechSettings.decode('不是 JSON').rate, 0.5);
      expect(SpeechSettings.decode('[1,2,3]').rate, 0.5);
      expect(SpeechSettings.decode('{"rate":"快"}').rate, 0.5);
      expect(SpeechSettings.decode('{"rate":0.9}').followAlong, isTrue);
      expect(SpeechSettings.decode('{"rate":0.9}').rate, 0.9);
    });

    test('落库的越界值在读回时同样被收敛', () {
      // 手工写入一个越界配置（模拟旧版本或人工改动库）。
      final restored = SpeechSettings.decode('{"rate":9,"volume":-3}');
      expect(restored.rate, SpeechSettings.maxRate);
      expect(restored.volume, SpeechSettings.minVolume);
    });
  });

  group('通道事件解码', () {
    test('七种事件都能解析', () {
      for (final kind in SpeechEventKind.values) {
        final decoded = MethodChannelSpeechBackend.decodeEvent(
          <String, Object?>{'kind': kind.id},
        );
        expect(decoded, isNotNull, reason: '${kind.id} 应能解析');
        expect(decoded!.kind, kind);
      }
    });

    test('未知 kind / 非 Map 载荷返回 null（由流过滤）', () {
      expect(
        MethodChannelSpeechBackend.decodeEvent(<String, Object?>{'kind': '乱写'}),
        isNull,
      );
      expect(MethodChannelSpeechBackend.decodeEvent('字符串'), isNull);
      expect(MethodChannelSpeechBackend.decodeEvent(null), isNull);
      expect(MethodChannelSpeechBackend.decodeEvent(<String, Object?>{}), isNull);
    });

    test('progress 事件带上字符偏移（位置换算的输入）', () {
      final decoded = MethodChannelSpeechBackend.decodeEvent(
        <String, Object?>{'kind': 'progress', 'charOffset': 42},
      );
      expect(decoded!.kind, SpeechEventKind.progress);
      expect(decoded.charOffset, 42);
    });

    test('failed 事件带上可读原因', () {
      final decoded = MethodChannelSpeechBackend.decodeEvent(
        <String, Object?>{'kind': 'failed', 'message': '音频会话被中断'},
      );
      expect(decoded!.kind, SpeechEventKind.failed);
      expect(decoded.message, '音频会话被中断');
    });

    test('偏移是浮点 / 字符串时也不崩（原生类型差异）', () {
      expect(
        MethodChannelSpeechBackend.decodeEvent(
          <String, Object?>{'kind': 'progress', 'charOffset': 7.0},
        )!.charOffset,
        7,
      );
      expect(
        MethodChannelSpeechBackend.decodeEvent(
          <String, Object?>{'kind': 'progress', 'charOffset': 'x'},
        )!.charOffset,
        isNull,
      );
    });
  });

  group('平台后端选择', () {
    test('非 iOS 平台如实降级为不支持（不抛错）', () async {
      // 测试环境不是 iOS，因此这里走的是降级分支。
      final backend = createPlatformSpeechBackend();
      expect(await backend.isSupported(), isFalse);
      // 降级后端的所有调用都是安全的空操作。
      await backend.speak('文本');
      await backend.pause();
      await backend.resume();
      await backend.stop();
    });

    test('通道后端在原生未接入时 isSupported 返回 false', () async {
      final backend = MethodChannelSpeechBackend(
        methodChannel: const MethodChannel('lumebox/speech/test-missing'),
        eventChannel: const EventChannel('lumebox/speech/test-missing'),
      );
      expect(await backend.isSupported(), isFalse);
    });

    test('原生未接入时 speak 抛可读异常（不是 MissingPluginException）', () async {
      final backend = MethodChannelSpeechBackend(
        methodChannel: const MethodChannel('lumebox/speech/test-missing'),
        eventChannel: const EventChannel('lumebox/speech/test-missing'),
      );
      await expectLater(
        backend.speak('测试'),
        throwsA(
          isA<SpeechException>().having(
            (e) => e.message,
            'message',
            contains('未接入'),
          ),
        ),
      );
    });

    test('设置下发给后端后，speak 带上这些参数', () async {
      final channel = MethodChannel('lumebox/speech/test-args');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final backend = MethodChannelSpeechBackend(methodChannel: channel)
        ..applySettings(
          const SpeechSettings(rate: 0.7, pitch: 1.3, volume: 0.4),
        );
      await backend.speak('一段文本');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'speak');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['text'], '一段文本');
      expect(args['rate'], 0.7);
      expect(args['pitch'], 1.3);
      expect(args['volume'], 0.4);
    });
  });
}
