import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/native_video_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lumebox/native_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeVideoBridge bridge;
  final calls = <MethodCall>[];
  Future<Object?> incoming(
    String method,
    String id, [
    Map<String, Object?> extra = const {},
  ]) async {
    final result = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, {'session': id, ...extra}),
      ),
      (ByteData? data) => result.complete(
        data == null ? null : const StandardMethodCodec().decodeEnvelope(data),
      ),
    );
    return result.future;
  }

  setUp(() {
    calls.clear();
    bridge = NativeVideoBridge();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'session identities isolate delayed native events and source requests',
    () async {
      final first = <Object?>[], second = <Object?>[];
      final a = bridge.connect(
        request: (_, _) async => {'owner': 'a'},
        event: first.add,
      );
      final b = bridge.connect(
        request: (_, _) async => {'owner': 'b'},
        event: second.add,
      );
      addTearDown(a.close);
      addTearDown(b.close);
      await incoming('event', a.id, {'type': 'progress'});
      expect(first, hasLength(1));
      expect(second, isEmpty);
      expect(await incoming('request', b.id, {'action': 'next'}), {
        'owner': 'b',
      });
      await a.close();
      await incoming('event', a.id, {'type': 'progress'});
      expect(first, hasLength(1));
      await incoming('event', b.id, {'type': 'progress'});
      expect(second, hasLength(1));
    },
  );
  test('closing a pending presentation sends one teardown and ignores late messages', () async {
    final presentation = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'open' ? presentation.future : null;
    });
    final events = <Object?>[];
    final connection = bridge.connect(
      request: (_, _) async => {},
      event: events.add,
    );
    final pending = connection.open({'url': 'https://example/video.mp4'}, {});
    await Future<void>.delayed(Duration.zero);
    await connection.close();
    await connection.close();
    presentation.complete(null);
    await pending;
    await incoming('event', connection.id, {'type': 'progress'});
    expect(events, isEmpty);
    expect(calls.where((c) => c.method == 'close'), hasLength(1));
  });
  test(
    'source exceptions become readable responses instead of breaking native UI',
    () async {
      final connection = bridge.connect(
        request: (_, _) async => throw StateError('source failed'),
        event: (_) {},
      );
      addTearDown(connection.close);
      final result =
          await incoming('request', connection.id, {'action': 'next'}) as Map;
      expect(result['error'], contains('source failed'));
    },
  );
  test('native close completes the route exactly once', () async {
    final connection = bridge.connect(
      request: (_, _) async => {},
      event: (_) {},
    );
    await connection.open({'url': 'https://example/video.mp4'}, {});
    await incoming('event', connection.id, {'type': 'closed'});
    await connection.finished.timeout(const Duration(seconds: 1));
    await connection.close();
    expect(calls.where((c) => c.method == 'close'), isEmpty);
  });
  test('failed native creation is torn down and can be retried with a fresh session', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'open') {
        throw PlatformException(code: 'create', message: 'native failure');
      }
      return null;
    });
    final connection = bridge.connect(
      request: (_, _) async => {},
      event: (_) {},
    );
    await expectLater(
      connection.open({'url': 'https://example/video.mp4'}, {}),
      throwsA(isA<PlatformException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'close'), hasLength(1));
    await connection.finished;
  });
}
