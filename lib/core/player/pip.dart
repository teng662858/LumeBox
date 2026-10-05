import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/lume_log.dart';

/// 画中画状态。
enum PipState {
  /// 平台或内核不支持画中画（页面显示占位）。
  unavailable('unavailable', '画中画不可用'),

  /// 支持且当前未开启。
  idle('idle', '画中画未开启'),

  /// 已请求进入，等待原生回调。
  entering('entering', '正在进入画中画'),

  /// 画中画播放中。
  active('active', '画中画播放中'),

  /// 已请求退出，等待原生回调。
  exiting('exiting', '正在退出画中画');

  const PipState(this.id, this.label);

  /// 稳定标识：日志与测试断言用。
  final String id;

  /// 中文短标签：页面直接展示。
  final String label;
}

/// 原生画中画事件类型。
enum PipEventKind {
  /// 已进入画中画。
  entered('entered'),

  /// 已退出画中画。
  exited('exited'),

  /// 用户从画中画窗口回到应用（部分平台会先回恢复再退出）。
  restored('restored'),

  /// 原生侧失败（含无法进入 / 中途中断）。
  failed('failed');

  const PipEventKind(this.id);

  /// 稳定标识：与原生通道的 `kind` 字段一一对应。
  final String id;

  /// 通道值解析；无法识别时返回 null（由调用方过滤）。
  static PipEventKind? fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// 原生画中画事件。
@immutable
class PipEvent {
  const PipEvent(this.kind, {this.message});

  final PipEventKind kind;

  /// 失败原因等可读说明（无则 null）。
  final String? message;
}

/// 画中画状态快照：页面据此选视图，不自行推断状态。
@immutable
class PipSnapshot {
  const PipSnapshot({required this.state, this.message});

  final PipState state;

  /// 最近一次失败 / 结果的可读说明（无则 null）。
  final String? message;

  bool get isActive => state == PipState.active;
}

/// 进入 / 退出的受理结果：拒绝时带可读原因（页面据此提示，不抛异常）。
@immutable
class PipOutcome {
  const PipOutcome.accepted() : rejection = null;

  const PipOutcome.rejected(this.rejection);

  /// 拒绝原因；受理时为 null。
  final String? rejection;

  bool get isAccepted => rejection == null;
}

/// 原生画中画后端：平台侧只做「探测 / 开 / 关 / 报事件」四件事。
///
/// 画中画调用失败（带可读原因）。
///
/// 原生侧会说明为什么开不了（系统版本、设备能力、内容源未就绪），这些原因要
/// 一路带到界面——一句「画中画失败」帮不了用户。
class PipException implements Exception {
  const PipException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 状态机、资源边界检查与事件回调都在 Dart 侧（[PipSession]）完成；后端不允许
/// 把异常抛给页面——失败经事件流或方法异常归一，由会话转成可读提示。
abstract interface class PipBackend {
  /// 平台 / 内核是否支持画中画。原生未接入时如实返回 false，不抛错。
  Future<bool> isSupported();

  /// 开启画中画。
  Future<void> start();

  /// 关闭画中画。
  Future<void> stop();

  /// 原生事件流：进入 / 退出 / 恢复 / 失败。
  Stream<PipEvent> get events;
}

/// 不支持画中画的后端：Android / Windows 与原生未接入时的降级实现。
class UnsupportedPipBackend implements PipBackend {
  const UnsupportedPipBackend();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PipEvent> get events => const Stream<PipEvent>.empty();
}

/// 画中画会话：状态机 + 资源边界检查 + 进入 / 退出事件回调。
///
/// 边界规则（每条都有对应用例）：
/// - 后端不支持、会话已销毁、媒体未就绪、正在切换中 → 拒绝进入，给出可读原因；
/// - 原生不回事件（start 之后没有 entered）→ 超时回滚为未开启，不停在中间态；
/// - 原生失败只归一成失败事件与提示，绝不向页面抛异常（宪法第 8 条）；
/// - [dispose] 时若正在画中画，先退出再释放，不把原生会话留给已销毁的页面。
class PipSession {
  PipSession({
    required this.backend,
    this.canEnter,
    this.onEvent,
    this.enterTimeout = const Duration(seconds: 5),
    this.exitTimeout = const Duration(seconds: 5),
  }) {
    _subscription = backend.events.listen(
      _onBackendEvent,
      onError: (Object error, StackTrace stackTrace) {
        LumeLog.error(error, stackTrace);
      },
    );
    unawaited(_probe());
  }

  /// 原生后端。
  final PipBackend backend;

  /// 进入前的就绪检查（媒体是否已加载）。为空视为总是就绪。
  final bool Function()? canEnter;

  /// 进入 / 退出事件回调。
  final void Function(PipEvent event)? onEvent;

  /// 进入等待原生回调的超时。
  final Duration enterTimeout;

  /// 退出等待原生回调的超时。
  final Duration exitTimeout;

  final ValueNotifier<PipSnapshot> _snapshot = ValueNotifier<PipSnapshot>(
    const PipSnapshot(state: PipState.unavailable),
  );

  StreamSubscription<PipEvent>? _subscription;
  Timer? _watch;
  bool _supported = false;
  bool _destroyed = false;

  /// 状态快照：页面订阅它更新按钮与占位。
  ValueListenable<PipSnapshot> get snapshot => _snapshot;

  PipState get state => _snapshot.value.state;

  /// 平台 / 内核是否支持画中画。
  bool get isSupported => _supported;

  /// 探测原生能力。失败如实按不支持处理。
  Future<void> _probe() async {
    bool supported;
    try {
      supported = await backend.isSupported();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      supported = false;
    }
    if (_destroyed) return;
    _supported = supported;
    _emit(PipSnapshot(state: supported ? PipState.idle : PipState.unavailable));
  }

  /// 进入画中画。返回受理结果；被拒原因同步写入快照供页面提示。
  Future<PipOutcome> enter() async {
    final rejection = _enterRejection();
    if (rejection != null) {
      _emit(PipSnapshot(state: state, message: rejection));
      return PipOutcome.rejected(rejection);
    }
    _emit(const PipSnapshot(state: PipState.entering));
    try {
      await backend.start().timeout(enterTimeout);
    } on TimeoutException {
      _fail('进入画中画超时');
      return const PipOutcome.rejected('进入画中画超时');
    } on PipException catch (error) {
      // 原生给了具体原因（系统版本 / 设备能力 / 内容源未就绪）：原样透出。
      LumeLog.warn('[pip] 进入失败: ${error.message}');
      _fail(error.message);
      return PipOutcome.rejected(error.message);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _fail('进入画中画失败');
      return const PipOutcome.rejected('进入画中画失败');
    }
    // start 返回不代表已进入：以原生 entered 事件为准；等不到就超时收敛，
    // 避免会话停在 entering。
    if (state == PipState.entering) {
      _armWatch(enterTimeout, () => _fail('进入画中画超时（原生未回调）'));
    }
    return const PipOutcome.accepted();
  }

  /// 退出画中画。未开启 / 正在切换时拒绝。
  Future<PipOutcome> exit() async {
    if (_destroyed) return const PipOutcome.rejected('页面已销毁');
    final current = state;
    if (current != PipState.active && current != PipState.entering) {
      return const PipOutcome.rejected('画中画未开启');
    }
    _emit(const PipSnapshot(state: PipState.exiting));
    try {
      await backend.stop().timeout(exitTimeout);
    } on TimeoutException {
      _fail('退出画中画超时');
      return const PipOutcome.rejected('退出画中画超时');
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _fail('退出画中画失败');
      return const PipOutcome.rejected('退出画中画失败');
    }
    // stop 完成即视为已退出：部分平台不补发 exited 事件，这里主动收敛。
    if (state == PipState.exiting) {
      _emit(const PipSnapshot(state: PipState.idle));
    }
    return const PipOutcome.accepted();
  }

  /// 释放会话：正在画中画时先退出，再退订事件、释放快照。
  ///
  /// 资源边界：退出一定发生在释放之前——原生会话持有的播放器引用必须在
  /// 播放器 dispose 之前清掉。
  Future<void> dispose() async {
    if (_destroyed) return;
    final wasOpen =
        state == PipState.active || state == PipState.entering;
    if (wasOpen) {
      try {
        await backend.stop().timeout(exitTimeout);
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
    _destroyed = true;
    _cancelWatch();
    final subscription = _subscription;
    _subscription = null;
    // 退订不阻塞释放路径：cancel() 何时完成由流的调度决定，而事件处理器已经
    // 被 _destroyed 挡住——页面紧接着还要释放播放器，不能卡在这一步。
    unawaited(subscription?.cancel());
    _snapshot.dispose();
  }

  /// 进入前的边界检查；返回 null 表示可进入。
  String? _enterRejection() {
    if (_destroyed) return '页面已销毁';
    if (!_supported) return '当前平台或内核不支持画中画';
    final current = state;
    if (current == PipState.active) return '画中画已开启';
    if (current == PipState.entering || current == PipState.exiting) {
      return '画中画正在切换中';
    }
    if (current != PipState.idle) return '画中画不可用';
    if (!(canEnter?.call() ?? true)) return '媒体尚未就绪';
    return null;
  }

  void _onBackendEvent(PipEvent event) {
    if (_destroyed) return;
    switch (event.kind) {
      case PipEventKind.entered:
        _cancelWatch();
        _emit(const PipSnapshot(state: PipState.active));
        _notify(event);
      case PipEventKind.exited:
        _cancelWatch();
        _emit(const PipSnapshot(state: PipState.idle));
        _notify(event);
      case PipEventKind.restored:
        _emit(const PipSnapshot(state: PipState.idle));
        _notify(event);
      case PipEventKind.failed:
        _fail(event.message ?? '画中画失败', cause: event);
    }
  }

  /// 失败收敛：回到可重试状态，原因写进快照。
  ///
  /// 只有原生失败（[cause] 非空）才转成事件回调——本地判定的超时或调用异常
  /// 由 enter / exit 的返回值告知调用方，两条通道不重复提示同一个失败。
  void _fail(String message, {PipEvent? cause}) {
    _cancelWatch();
    _emit(
      PipSnapshot(
        state: _supported ? PipState.idle : PipState.unavailable,
        message: message,
      ),
    );
    if (cause != null) _notify(cause);
  }

  void _emit(PipSnapshot next) {
    if (_destroyed) return;
    _snapshot.value = next;
  }

  void _notify(PipEvent event) {
    if (_destroyed) return;
    final callback = onEvent;
    if (callback == null) return;
    try {
      callback(event);
    } catch (error, stackTrace) {
      // 回调异常不外溢：画中画事件不能因为页面回调写错而中断。
      LumeLog.error(error, stackTrace);
    }
  }

  void _armWatch(Duration timeout, void Function() onTimeout) {
    _cancelWatch();
    _watch = Timer(timeout, onTimeout);
  }

  void _cancelWatch() {
    _watch?.cancel();
    _watch = null;
  }
}
