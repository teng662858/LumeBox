import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/ios_image_network.dart';
import 'package:lume_box/core/net/ios_verified_webview.dart';
import 'package:lume_box/core/net/network_activity.dart';
import 'package:lume_box/core/net/network_cancellation.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/shared/widgets/network_waiting_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(IosImageNetwork.channel, null);
    messenger.setMockMethodCallHandler(IosVerifiedWebView.channel, null);
    NetworkActivity.waiting.value = const {};
  });
  Future<void> state(String id, bool waiting) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      'lumebox/image_network',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('state', {'requestId': id, 'waiting': waiting}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  test('原生等待状态按请求维护，完成后的迟到通知不能复活提示', () async {
    final held = Completer<Object?>();
    late String id;
    messenger.setMockMethodCallHandler(IosImageNetwork.channel, (call) async {
      id = call.arguments['requestId'] as String;
      return held.future;
    });
    final future = IosImageNetwork.send(
      const NetworkRequest(url: 'https://a.example'),
    );
    await Future<void>.delayed(Duration.zero);
    await state(id, true);
    expect(NetworkActivity.waiting.value, {id});
    held.complete({
      'status': 200,
      'body': [1],
      'headers': <String, String>{},
    });
    await future;
    expect(NetworkActivity.waiting.value, isEmpty);
    await state(id, true);
    expect(NetworkActivity.waiting.value, isEmpty);
  });
  test('取消系统网络请求使用相同 id，同时清除等待状态', () async {
    final held = Completer<Object?>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(IosImageNetwork.channel, (call) async {
      calls.add(call);
      if (call.method == 'cancel') {
        held.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return held.future;
    });
    final token = NetworkCancellation();
    final future = IosImageNetwork.send(
      NetworkRequest(url: 'https://a.example', cancellation: token),
    );
    final error = expectLater(future, throwsA(isA<PlatformException>()));
    await Future<void>.delayed(Duration.zero);
    final id = calls.first.arguments['requestId'] as String;
    await state(id, true);
    token.cancel();
    await error;
    expect(calls.last.method, 'cancel');
    expect(calls.last.arguments['requestId'], id);
    expect(NetworkActivity.waiting.value, isEmpty);
  });
  test('取消备用 WebKit 读取释放同一原生网页会话', () async {
    final held = Completer<Object?>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(IosVerifiedWebView.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'cancelVerifiedRead') {
        held.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return held.future;
    });
    final token = NetworkCancellation();
    final future = IosVerifiedWebView.read(
      NetworkRequest(url: 'https://a.example', cancellation: token),
    );
    final error = expectLater(future, throwsA(isA<NetworkCancelled>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await error;
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'cancelVerifiedRead');
    expect(
      calls.last.arguments['requestId'],
      calls.first.arguments['requestId'],
    );
  });
  testWidgets('等待提示不遮断操作，多个请求分别结束后才隐藏', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworkWaitingView(
            child: Center(
              child: TextButton(
                onPressed: () => tapped++,
                child: const Text('原页面'),
              ),
            ),
          ),
        ),
      ),
    );
    NetworkActivity.setWaiting('a', true);
    NetworkActivity.setWaiting('b', true);
    await tester.pump();
    expect(find.text('有请求正在等待网络连接，恢复后继续…'), findsOneWidget);
    await tester.tap(find.text('原页面'));
    expect(tapped, 1);
    NetworkActivity.setWaiting('a', false);
    await tester.pump();
    expect(find.text('有请求正在等待网络连接，恢复后继续…'), findsOneWidget);
    NetworkActivity.setWaiting('b', false);
    await tester.pump();
    expect(find.text('有请求正在等待网络连接，恢复后继续…'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
