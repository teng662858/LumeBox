import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/pip.dart';
import 'package:lume_box/core/player/pip_channel.dart';

/// 画中画原生通道契约的验证（在 Windows 上跑，用方法通道打桩模拟原生侧）。
///
/// 三件事：通道名与调用方法固定、事件载荷解码固定、原生未接入时如实降级为
/// 「不支持」而不是抛异常。原生 Swift 落地后只要满足这份契约即可直接生效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel(MethodChannelPipBackend.methodChannelName);
  const events = MethodChannel(MethodChannelPipBackend.eventChannelName);

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger()
      ..setMockMethodCallHandler(methods, null)
      ..setMockMethodCallHandler(events, null);
  });

  test('原生未接入：isSupported 如实降级为 false，不抛异常', () async {
    final backend = MethodChannelPipBackend();
    expect(await backend.isSupported(), isFalse);
  });

  test('探测与开关：按通道契约往返', () async {
    final calls = <String>[];
    messenger().setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return call.method == 'isSupported' ? true : null;
    });

    final backend = MethodChannelPipBackend();
    expect(await backend.isSupported(), isTrue);
    await backend.start();
    await backend.stop();

    expect(calls, <String>['isSupported', 'start', 'stop']);
  });

  test('探测抛错：归一为不支持', () async {
    messenger().setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'boom');
    });

    final backend = MethodChannelPipBackend();
    expect(await backend.isSupported(), isFalse);
  });

  test('事件载荷解码：四种事件一一对应，未知载荷过滤', () {
    expect(
      MethodChannelPipBackend.decodeEvent(<String, Object?>{'kind': 'entered'})
          ?.kind,
      PipEventKind.entered,
    );
    expect(
      MethodChannelPipBackend.decodeEvent(<String, Object?>{'kind': 'exited'})
          ?.kind,
      PipEventKind.exited,
    );
    expect(
      MethodChannelPipBackend.decodeEvent(<String, Object?>{'kind': 'restored'})
          ?.kind,
      PipEventKind.restored,
    );
    final failed = MethodChannelPipBackend.decodeEvent(
      <String, Object?>{'kind': 'failed', 'message': '原生中断'},
    );
    expect(failed?.kind, PipEventKind.failed);
    expect(failed?.message, '原生中断');

    expect(
      MethodChannelPipBackend.decodeEvent(<String, Object?>{'kind': 'unknown'}),
      isNull,
    );
    expect(MethodChannelPipBackend.decodeEvent('nope'), isNull);
    expect(MethodChannelPipBackend.decodeEvent(null), isNull);
  });

  test('端到端：原生事件经通道驱动会话状态', () async {
    messenger()
      ..setMockMethodCallHandler(
        methods,
        (call) async => call.method == 'isSupported' ? true : null,
      )
      ..setMockMethodCallHandler(events, (call) async => null);

    final backend = MethodChannelPipBackend();
    final session = PipSession(backend: backend);
    await Future<void>.delayed(Duration.zero);
    expect(session.state, PipState.idle);

    expect((await session.enter()).isAccepted, isTrue);
    await _raiseEvent(<String, Object?>{'kind': 'entered'});
    await Future<void>.delayed(Duration.zero);
    expect(session.state, PipState.active);

    await _raiseEvent(<String, Object?>{'kind': 'failed', 'message': '中断'});
    await Future<void>.delayed(Duration.zero);
    expect(session.state, PipState.idle);

    await session.dispose();
  });
}

/// 模拟原生侧向事件通道投递一条事件。
Future<void> _raiseEvent(Map<String, Object?> payload) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    MethodChannelPipBackend.eventChannelName,
    const StandardMethodCodec().encodeSuccessEnvelope(payload),
    (_) {},
  );
}
