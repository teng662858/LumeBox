import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/buffering.dart';

/// 缓冲参数原生通道的契约验证（在 Windows 上跑，用方法通道打桩模拟原生侧）。
///
/// 这件事的来龙去脉见 `deferred-todo.md` 的 B 项：**AVPlayer 的缓冲启动参数
/// 只在原生对象上**，`video_player` 的 Dart API 拿不到，因此必须有一条原生通道。
/// 原生 Swift（`ios/Runner/BufferingController.swift`）落地后，只要满足这份契约
/// 就能直接生效；三件事：通道名与调用方法固定、参数形状固定、原生未接入时如实
/// 降级为「不支持」而不是抛异常。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel(MethodChannelBufferingBackend.channelName);

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger().setMockMethodCallHandler(methods, null);
  });

  test('通道名固定：原生 Swift 侧按这个名字注册', () {
    expect(MethodChannelBufferingBackend.channelName, 'lumebox/buffering');
  });

  test('原生未接入：isSupported 如实降级为 false，不抛异常', () async {
    final backend = MethodChannelBufferingBackend();
    expect(await backend.isSupported(), isFalse);

    // apply 也必须安静（调用方已经按 isSupported 走过降级路径）。
    await backend.apply(BufferingConfig.defaults);
  });

  test('探测抛错：归一为不支持', () async {
    messenger().setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'boom');
    });
    expect(await MethodChannelBufferingBackend().isSupported(), isFalse);
  });

  test('apply：按契约往返（方法名 + 参数形状）', () async {
    final calls = <MethodCall>[];
    messenger().setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'isSupported' ? true : null;
    });

    final backend = MethodChannelBufferingBackend();
    expect(await backend.isSupported(), isTrue);
    await backend.apply(BufferingConfig.defaults);

    expect(calls.map((call) => call.method), <String>['isSupported', 'apply']);
    final args = calls.last.arguments as Map<Object?, Object?>;
    expect(args['forwardBufferSeconds'], 0.0,
        reason: '0 = 交给 AVFoundation 自动决定前向缓冲');
    expect(args['minimizeStalling'], isFalse,
        reason: 'false = 不等缓冲填满就起播（真机「等一两分钟」的直接开关）');
  });

  test('apply 失败只记日志：不把异常抛回播放链路', () async {
    messenger().setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'apply') throw PlatformException(code: 'nope');
      return true;
    });
    await MethodChannelBufferingBackend().apply(BufferingConfig.defaults);
  });

  test('渠道已知标记：成功写过一次后置位（内核据此省掉重复往返）', () async {
    messenger().setMockMethodCallHandler(methods, (call) async => null);
    final backend = MethodChannelBufferingBackend();
    expect(backend.channelKnown, isFalse);
    await backend.apply(BufferingConfig.defaults);
    expect(backend.channelKnown, isTrue);
  });

  group('参数对象', () {
    test('默认值：以「尽快出画面」为准', () {
      const config = BufferingConfig.defaults;
      expect(config.forwardBuffer, Duration.zero);
      expect(config.minimizeStalling, isFalse);
      expect(config.readAhead, const Duration(seconds: 15));
      expect(config.maxBufferBytes, 64 * 1024 * 1024);
      expect(config.maxBackBufferBytes, 16 * 1024 * 1024);
    });

    test('MPV 属性映射：属性名与单位固定（libmpv 的公开属性）', () {
      expect(BufferingConfig.defaults.mpvProperties, <String, String>{
        'cache': 'yes',
        'cache-pause-initial': 'no',
        'demuxer-readahead-secs': '15',
        'demuxer-max-bytes': '${64 * 1024 * 1024}',
        'demuxer-max-back-bytes': '${16 * 1024 * 1024}',
      });
    });

    test('自定义值原样进映射（换算只做单位，不做别的加工）', () {
      const config = BufferingConfig(
        readAhead: Duration(seconds: 3),
        maxBufferBytes: 1234,
        maxBackBufferBytes: 567,
      );
      expect(config.mpvProperties['demuxer-readahead-secs'], '3');
      expect(config.mpvProperties['demuxer-max-bytes'], '1234');
      expect(config.mpvProperties['demuxer-max-back-bytes'], '567');
    });

    test('相等性与文案：配置可比较（避免重复写属性）', () {
      expect(const BufferingConfig(), BufferingConfig.defaults);
      expect(
        const BufferingConfig(readAhead: Duration(seconds: 1)),
        isNot(BufferingConfig.defaults),
      );
      expect(BufferingConfig.defaults.toString(), contains('前向缓冲'));
    });
  });

  group('后端选择', () {
    test('非 iOS：如实降级为「没有原生通道」', () async {
      final backend = createPlatformBufferingBackend();
      if (Platform.isIOS) {
        expect(backend, isA<MethodChannelBufferingBackend>());
      } else {
        expect(backend, isA<UnsupportedBufferingBackend>());
        expect(await backend.isSupported(), isFalse);
        await backend.apply(BufferingConfig.defaults);
      }
    });
  });
}
