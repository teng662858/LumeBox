import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/pip.dart';

/// 画中画会话的验证：状态机、进入 / 退出事件回调、资源边界检查与失败收敛。
///
/// 全部用替身后端在 Windows 上跑：会话不认识原生实现，原生实现落地后
/// 这些规则一字不用改。
void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('不支持：状态为不可用，进入被拒且不碰后端', () async {
    final backend = _FakePipBackend(supported: false);
    addTearDown(backend.close);
    final session = PipSession(backend: backend);
    addTearDown(session.dispose);
    await settle();

    expect(session.state, PipState.unavailable);

    final outcome = await session.enter();
    expect(outcome.isAccepted, isFalse);
    expect(outcome.rejection, '当前平台或内核不支持画中画');
    expect(backend.started, 0);
  });

  test('进入 / 退出全链路：以原生事件为准，回调收到 entered / exited', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final events = <PipEvent>[];
    final session = PipSession(backend: backend, onEvent: events.add);
    addTearDown(session.dispose);
    await settle();
    expect(session.state, PipState.idle);

    final entered = await session.enter();
    expect(entered.isAccepted, isTrue);
    expect(session.state, PipState.entering);
    expect(backend.started, 1);

    // start 返回不算进入：原生 entered 事件才是权威。
    backend.emit(PipEventKind.entered);
    await settle();
    expect(session.state, PipState.active);
    expect(events.single.kind, PipEventKind.entered);

    final exited = await session.exit();
    expect(exited.isAccepted, isTrue);
    expect(backend.stopped, 1);
    expect(session.state, PipState.idle);

    // 原生随后补发 exited 也接受（幂等，不改变状态）。
    backend.emit(PipEventKind.exited);
    await settle();
    expect(session.state, PipState.idle);
    expect(
      events.map((event) => event.kind),
      <PipEventKind>[PipEventKind.entered, PipEventKind.exited],
    );
  });

  test('用户从画中画窗口返回：restored 事件回到未开启', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final events = <PipEvent>[];
    final session = PipSession(backend: backend, onEvent: events.add);
    addTearDown(session.dispose);
    await settle();

    await session.enter();
    backend.emit(PipEventKind.entered);
    await settle();
    expect(session.state, PipState.active);

    backend.emit(PipEventKind.restored);
    await settle();
    expect(session.state, PipState.idle);
    expect(events.last.kind, PipEventKind.restored);
  });

  test('就绪边界：媒体未就绪拒绝进入，就绪后可进入', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    var ready = false;
    final session = PipSession(backend: backend, canEnter: () => ready);
    addTearDown(session.dispose);
    await settle();

    final rejected = await session.enter();
    expect(rejected.rejection, '媒体尚未就绪');
    expect(backend.started, 0);
    expect(session.state, PipState.idle);

    ready = true;
    expect((await session.enter()).isAccepted, isTrue);
    expect(backend.started, 1);
  });

  test('忙碌边界：切换中与已开启时重复进入被拒', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final session = PipSession(backend: backend);
    addTearDown(session.dispose);
    await settle();

    expect((await session.enter()).isAccepted, isTrue);
    final duringEnter = await session.enter();
    expect(duringEnter.rejection, '画中画正在切换中');

    backend.emit(PipEventKind.entered);
    await settle();
    final duringActive = await session.enter();
    expect(duringActive.rejection, '画中画已开启');
    expect(backend.started, 1);
  });

  test('超时收敛：原生不回事件时回到未开启并给出原因', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final events = <PipEvent>[];
    final session = PipSession(
      backend: backend,
      onEvent: events.add,
      enterTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(session.dispose);
    await settle();

    await session.enter();
    expect(session.state, PipState.entering);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(session.state, PipState.idle);
    expect(session.snapshot.value.message, contains('超时'));
    // 本地判定的超时经返回值告知调用方，不重复触发事件回调。
    expect(events, isEmpty);
  });

  test('原生失败事件：归一为失败回调与提示，不抛出', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final events = <PipEvent>[];
    final session = PipSession(backend: backend, onEvent: events.add);
    addTearDown(session.dispose);
    await settle();

    await session.enter();
    backend.emit(PipEventKind.failed, message: '原生中断');
    await settle();

    expect(session.state, PipState.idle);
    expect(session.snapshot.value.message, '原生中断');
    expect(events.single.kind, PipEventKind.failed);
    expect(events.single.message, '原生中断');
  });

  test('原生 start 抛错：归一为拒绝，不向调用方抛异常', () async {
    final backend = _FakePipBackend()..startFailure = StateError('boom');
    addTearDown(backend.close);
    final session = PipSession(backend: backend);
    addTearDown(session.dispose);
    await settle();

    final outcome = await session.enter();
    expect(outcome.isAccepted, isFalse);
    expect(outcome.rejection, '进入画中画失败');
    expect(session.state, PipState.idle);
  });

  test('未开启时退出被拒', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final session = PipSession(backend: backend);
    addTearDown(session.dispose);
    await settle();

    final outcome = await session.exit();
    expect(outcome.rejection, '画中画未开启');
    expect(backend.stopped, 0);
  });

  test('dispose：画中画中先退出再释放，之后事件不再生效', () async {
    final backend = _FakePipBackend();
    addTearDown(backend.close);
    final events = <PipEvent>[];
    final session = PipSession(backend: backend, onEvent: events.add);
    await settle();

    await session.enter();
    backend.emit(PipEventKind.entered);
    await settle();
    expect(session.state, PipState.active);
    final notified = events.length;

    await session.dispose();
    expect(backend.stopped, 1, reason: '释放前必须先退出画中画');

    backend.emit(PipEventKind.exited);
    await settle();
    expect(events.length, notified, reason: '销毁后事件回调不再触发');
    // 可重复调用。
    await session.dispose();
    expect(backend.stopped, 1);
  });
}

/// 替身后端：记录调用、手动发事件，验证会话不依赖具体原生实现。
class _FakePipBackend implements PipBackend {
  _FakePipBackend({this.supported = true});

  bool supported;
  Object? startFailure;

  int started = 0;
  int stopped = 0;

  final StreamController<PipEvent> _events =
      StreamController<PipEvent>.broadcast();

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> start() async {
    started++;
    final failure = startFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> stop() async {
    stopped++;
  }

  @override
  Stream<PipEvent> get events => _events.stream;

  void emit(PipEventKind kind, {String? message}) =>
      _events.add(PipEvent(kind, message: message));

  Future<void> close() => _events.close();
}
