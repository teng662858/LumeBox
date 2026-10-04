import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/node_mobile_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox_result.dart';

/// Node-Mobile 引擎（Dart 侧）的验证：通道契约、实例隔离参数、超时销毁与
/// 异常回收、释放语义。原生实现（Android 侧 Kotlin + libnode）尚未集成，
/// 因此这里用方法通道打桩把契约固定下来——原生落地时照着这份契约实现即可。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel(NodeMobileEngine.methodChannelName);

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger().setMockMethodCallHandler(methods, null));

  test('原生未集成：isSupported 如实 false，调用返回 unsupported 而不是崩溃', () async {
    final engine = NodeMobileEngine(sourceId: 'cat-1');

    expect(await engine.isSupported(), isFalse);
    expect(await engine.loadScript('x'), isFalse);

    final result = await engine.callResult('list');
    expect(result.isOk, isFalse);
    expect(result.error!.kind, SandboxErrorKind.unsupported);

    // 原生缺失时销毁也不抛。
    await engine.dispose();
    await engine.dispose();
  });

  test('通道契约：start 带 sourceId、loadScript / metadata / call / dispose 往返', () async {
    final calls = <String>[];
    String? startedSourceId;
    messenger().setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isSupported':
          return true;
        case 'start':
          startedSourceId = (call.arguments as Map<Object?, Object?>)['sourceId'] as String?;
          return true;
        case 'loadScript':
          return true;
        case 'metadata':
          return <String, Object?>{
            'id': 'cat.demo',
            'name': '示例猫源',
            'version': '1.0.0',
          };
        case 'call':
          final args = call.arguments as Map<Object?, Object?>;
          if (args['method'] == 'fail') {
            return <String, Object?>{'ok': false, 'message': '脚本自己报的错'};
          }
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              'method': args['method'],
              'argument': args['argument'],
            },
          };
        case 'dispose':
          return null;
      }
      return null;
    });

    final engine = NodeMobileEngine(sourceId: 'cat-1');
    expect(await engine.loadScript('var LumeSource = {};'), isTrue);
    expect(engine.generation, 1, reason: '首次调用起实例');
    expect(startedSourceId, 'cat-1', reason: '实例隔离：start 必须带图源标识');

    final metadata = await engine.metadata();
    expect(metadata?['id'], 'cat.demo');

    final ok = await engine.callResult('list', <String, Object?>{'page': 2});
    expect(ok.isOk, isTrue);
    expect((ok.value! as Map<Object?, Object?>)['argument'], <String, Object?>{'page': 2});

    final failure = await engine.callResult('fail');
    expect(failure.isOk, isFalse);
    expect(failure.error!.kind, SandboxErrorKind.script);
    expect(failure.error!.message, '脚本自己报的错');

    await engine.dispose();
    expect(calls, <String>[
      'start',
      'loadScript',
      'metadata',
      'call',
      'call',
      'dispose',
    ]);

    final afterDispose = await engine.callResult('list');
    expect(afterDispose.error!.kind, SandboxErrorKind.disposed);
  });

  test('调用超时：立刻回收实例，下次调用重建（generation 递增）', () async {
    var callCount = 0;
    final disposes = <String>[];
    messenger().setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'start':
          return true;
        case 'loadScript':
          return true;
        case 'call':
          callCount += 1;
          if (callCount == 1) {
            // 第一次调用原生永远不回：触发超时。
            return Completer<Object?>().future;
          }
          return <String, Object?>{'ok': true, 'value': 'second'};
        case 'dispose':
          disposes.add('disposed');
          return null;
      }
      return null;
    });

    final engine = NodeMobileEngine(
      sourceId: 'cat-hang',
      callTimeout: const Duration(milliseconds: 40),
    );

    final timeout = await engine.callResult('list');
    expect(timeout.isOk, isFalse);
    expect(timeout.error!.kind, SandboxErrorKind.timeout);
    expect(engine.isPoisoned, isTrue);
    expect(disposes, hasLength(1), reason: '超时后必须回收原生实例');

    final again = await engine.callResult('list');
    expect(again.isOk, isTrue);
    expect(again.value, 'second');
    expect(engine.generation, 2, reason: '重新起了实例');
    expect(engine.isPoisoned, isFalse, reason: '重建后污染标记复位');

    await engine.dispose();
  });

  test('原生异常：回收实例并给出可读失败，不需要调用方兜底', () async {
    var disposed = 0;
    messenger().setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'start':
          return true;
        case 'loadScript':
          throw PlatformException(code: 'boom', message: 'native blew up');
        case 'dispose':
          disposed += 1;
          return null;
      }
      return null;
    });

    final engine = NodeMobileEngine(sourceId: 'cat-err');
    expect(await engine.loadScript('x'), isFalse);
    expect(engine.isPoisoned, isTrue);
    expect(disposed, 1, reason: '异常同样回收实例');
  });

  test('回包不合契约：按协议错误处理，不猜内容', () async {
    messenger().setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'start':
          return true;
        case 'call':
          return 'not-an-envelope';
      }
      return null;
    });

    final engine = NodeMobileEngine(sourceId: 'cat-bad');
    final result = await engine.callResult('list');
    expect(result.isOk, isFalse);
    expect(result.error!.kind, SandboxErrorKind.protocol);
    await engine.dispose();
  });

  test('起实例失败：调用返回 unsupported，不反复重试', () async {
    var starts = 0;
    messenger().setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'start':
          starts += 1;
          return false;
        case 'dispose':
          return null;
      }
      return null;
    });

    final engine = NodeMobileEngine(sourceId: 'cat-nostart');
    expect((await engine.callResult('list')).error!.kind, SandboxErrorKind.unsupported);
    expect((await engine.callResult('list')).isOk, isFalse);
    // 每次调用都会尝试起实例（失败不缓存），但不会在失败里循环。
    expect(starts, 2);
    await engine.dispose();
  });
}
