import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/lume_log.dart';
import 'speech_segments.dart';

/// 语音合成状态。
enum SpeechState {
  /// 平台不支持语音合成（面板显示占位）。
  unavailable('unavailable', '语音朗读不可用'),

  /// 支持且当前未朗读。
  idle('idle', '未朗读'),

  /// 正在朗读。
  speaking('speaking', '朗读中'),

  /// 已请求暂停（等引擎回报暂停完成）。
  pausing('pausing', '正在暂停'),

  /// 已暂停（可继续）。
  paused('paused', '已暂停');

  const SpeechState(this.id, this.label);

  /// 稳定标识：日志与测试断言用。
  final String id;

  /// 中文短标签：页面直接展示。
  final String label;
}

/// 引擎事件类型。
enum SpeechEventKind {
  /// 一段开始朗读。
  started('started'),

  /// 一段朗读结束（正常读完）。
  finished('finished'),

  /// 朗读位置推进（字符偏移，相对当前片段）。
  progress('progress'),

  /// 已暂停。
  paused('paused'),

  /// 已继续。
  resumed('resumed'),

  /// 已停止（主动停止或引擎侧中断）。
  stopped('stopped'),

  /// 引擎侧失败。
  failed('failed');

  const SpeechEventKind(this.id);

  final String id;

  static SpeechEventKind? fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// 引擎事件。
@immutable
class SpeechEvent {
  const SpeechEvent(this.kind, {this.charOffset, this.message});

  final SpeechEventKind kind;

  /// 朗读位置（字符偏移，相对当前片段）；无位置信息的事件为 null。
  final int? charOffset;

  /// 失败原因等可读说明。
  final String? message;
}

/// 语音合成后端：平台侧只做「探测 / 说 / 停 / 暂停 / 继续 / 报事件」六件事。
///
/// 与画中画的 [PipBackend] 同构：Dart 侧持有状态机与边界检查，后端只管调用
/// 原生能力并把结果归一成事件流；后端不允许把异常抛给页面。
abstract interface class SpeechBackend {
  /// 平台是否支持语音合成。原生未接入时如实返回 false，不抛错。
  Future<bool> isSupported();

  /// 朗读一段文本。
  Future<void> speak(String text);

  /// 停止朗读（清空队列）。
  Future<void> stop();

  /// 暂停朗读。
  Future<void> pause();

  /// 继续朗读。
  Future<void> resume();

  /// 引擎事件流。
  Stream<SpeechEvent> get events;
}

/// 可选能力：锁屏 / 控制中心信息。
///
/// 做成可选端口而不是塞进 [SpeechBackend]：桌面与 Android 的降级后端没有锁屏
/// 概念，逼所有实现写空方法不如让调用方按能力查询（与 [DanmakuCapable] 同思路）。
abstract interface class NowPlayingCapable {
  /// 设置锁屏显示的信息（书名 + 章节名）。
  Future<void> setNowPlaying({String? title, String? subtitle});

  /// 清除锁屏信息（停止朗读 / 退出阅读器）。
  Future<void> clearNowPlaying();
}

/// 不支持语音合成的后端：非 iOS 平台与原生未接入时的降级实现。
class UnsupportedSpeechBackend implements SpeechBackend {
  const UnsupportedSpeechBackend();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Stream<SpeechEvent> get events => const Stream<SpeechEvent>.empty();
}

/// 语音合成会话：状态机 + 片段队列 + 跟读位置换算。
///
/// 边界规则（与画中画会话同口径，每条都有对应用例）：
/// - 后端不支持、会话已销毁、片段列表为空 → 拒绝开始，给出可读原因；
/// - 引擎长时间无动静 → 由**静默看门狗**兜底推进，不卡死在中间；
/// - 引擎失败只归一成事件与提示，绝不向页面抛异常；
/// - [dispose] 时若正在朗读，先停止再释放，不把原生会话留给已销毁的页面。
///
/// 位置口径：引擎回报的是**相对当前片段**的字符偏移；本会话把它换算成
/// 「整章字符偏移」后交给 [onPosition]（= 片段起点 + 片段内偏移）。
/// 跟读翻页、进度保存都用这个整章偏移，页面不必自己做加法。
class SpeechSession {
  SpeechSession({
    required this.backend,
    this.onPosition,
    this.onEvent,
    this.onSegmentFinished,
    this.onCompleted,
    this.silenceTimeout = const Duration(seconds: 20),
  }) {
    _subscription = backend.events.listen(
      _onBackendEvent,
      onError: (Object error, StackTrace stackTrace) {
        LumeLog.error(error, stackTrace);
      },
    );
    unawaited(_probe());
  }

  final SpeechBackend backend;

  /// 位置回调：整章字符偏移（片段起点 + 片段内偏移）。
  final void Function(int charOffset)? onPosition;

  /// 事件回调（页面据此提示）。
  final void Function(SpeechEvent event)? onEvent;

  /// 一段读完的回调：参数是刚读完那段的整章字符偏移终点。
  ///
  /// 会话内部会自动接着读下一段；这个回调是给页面做「跟读翻页」用的。
  final void Function(int charOffset)? onSegmentFinished;

  /// **整批片段全部读完**的回调（连续听书据此进下一章）。
  ///
  /// 单独开一个回调而不是让页面监听「状态变 idle」：idle 也可能是用户停止、
  /// 引擎中断或失败收敛的结果，那些情况下都不该自动进下一章。只有这里
  /// 才代表「这一章真的读完了」。
  final void Function()? onCompleted;

  /// **静默**超时：这么久没有收到任何引擎动静就认为卡住，按读完推进。
  ///
  /// 用「静默」而不是「单段总时长」：一段千字文本按正常语速要读几分钟，
  /// 固定总时长会在读到一半时误判；而只要引擎在正常推进（started / progress），
  /// 看门狗就不断被喂，永远不会误伤。
  final Duration silenceTimeout;

  final ValueNotifier<SpeechState> _state = ValueNotifier<SpeechState>(
    SpeechState.unavailable,
  );

  StreamSubscription<SpeechEvent>? _subscription;
  Timer? _watch;
  bool _supported = false;
  bool _destroyed = false;

  /// 待读片段队列与当前下标。
  List<SpeechSegment> _segments = const <SpeechSegment>[];
  int _index = 0;

  /// 当前片段的字符起点（整章坐标）。
  int _segmentStart = 0;

  /// 最近一次回报的整章字符偏移。
  int _position = 0;

  /// 暂停期间跳转过片段：继续时要重新下发朗读，而不是让引擎 resume
  /// （引擎已经被 stop 掉了，resume 没有内容可继续）。
  bool _needsRespeak = false;

  /// 状态快照：页面订阅它更新按钮与提示。
  ValueListenable<SpeechState> get state => _state;

  /// 平台是否支持语音合成。
  bool get isSupported => _supported;

  /// 是否正在朗读（含暂停前的过渡态）。
  bool get isActive =>
      _state.value == SpeechState.speaking ||
      _state.value == SpeechState.pausing;

  /// 是否已暂停。
  bool get isPaused => _state.value == SpeechState.paused;

  /// 待读片段总数。
  int get segmentCount => _segments.length;

  /// 当前片段下标（0 起）。
  int get segmentIndex => _index;

  /// 最近一次的整章字符偏移。
  int get position => _position;

  /// 探测平台能力。失败如实按不支持处理。
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
    _emit(supported ? SpeechState.idle : SpeechState.unavailable);
  }

  /// 设置锁屏 / 控制中心显示的信息（书名 + 章节名）。
  ///
  /// 页面在开始朗读时调一次即可；停止 / 释放时由会话自己清掉（见 [stop] /
  /// [dispose]），页面不需要记得清理。后端没有这个能力（桌面 / Android 降级）
  /// 时静默跳过——锁屏信息是增强项。
  Future<void> setNowPlaying({String? title, String? subtitle}) async {
    if (_destroyed) return;
    final capability = _nowPlayingCapability;
    if (capability == null) return;
    try {
      await capability.setNowPlaying(title: title, subtitle: subtitle);
    } catch (error, stackTrace) {
      LumeLog.warn('[speech] 锁屏信息设置失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 后端的锁屏能力；后端没有时返回 null。
  ///
  /// 显式转型而不是靠 `is` 提升：`NowPlayingCapable` 与 [SpeechBackend] 是不相干
  /// 的接口，Dart 不会把变量提升到非子类型，`is` 判完仍需要转型
  /// （与 `DanmakuCapable` 的用法一致）。
  NowPlayingCapable? get _nowPlayingCapability {
    final candidate = backend;
    if (candidate is NowPlayingCapable) return candidate as NowPlayingCapable;
    return null;
  }

  /// 开始朗读一串片段（通常是一章的切分结果）。
  ///
  /// [fromIndex] 指定从第几片开始（断点续听）；越界会被收敛到合法范围。
  /// 返回拒绝原因；null 表示已受理。
  Future<String?> start(
    List<SpeechSegment> segments, {
    int fromIndex = 0,
  }) async {
    if (_destroyed) return '页面已销毁';
    if (!_supported) return '当前平台不支持语音朗读';
    final speakable = segments.where((segment) => segment.isSpeakable).toList();
    if (speakable.isEmpty) return '本章没有可朗读的内容';
    _cancelWatch();
    _segments = List<SpeechSegment>.unmodifiable(speakable);
    _index = fromIndex.clamp(0, speakable.length - 1);
    _needsRespeak = false;
    _moveToSegment(_index);
    _emit(SpeechState.speaking);
    return _speakCurrent();
  }

  /// 暂停。
  Future<String?> pause() async {
    if (_destroyed) return '页面已销毁';
    if (_state.value != SpeechState.speaking) return '当前未在朗读';
    _cancelWatch();
    _emit(SpeechState.pausing);
    try {
      await backend.pause();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _emit(SpeechState.speaking);
      _armWatch();
      return '暂停失败';
    }
    // 部分平台不补发 paused 事件：主动收敛，不停在中间态。
    if (_state.value == SpeechState.pausing) _emit(SpeechState.paused);
    return null;
  }

  /// 继续。
  Future<String?> resume() async {
    if (_destroyed) return '页面已销毁';
    if (_state.value != SpeechState.paused) return '当前未暂停';
    _emit(SpeechState.speaking);
    // 暂停期间跳转过片段：引擎里已经没有内容，必须重新下发这一段。
    if (_needsRespeak) {
      _needsRespeak = false;
      return _speakCurrent();
    }
    try {
      await backend.resume();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _emit(SpeechState.paused);
      return '继续朗读失败';
    }
    _armWatch();
    return null;
  }

  /// 停止（清空队列）。
  Future<void> stop() async {
    if (_destroyed) return;
    _cancelWatch();
    _segments = const <SpeechSegment>[];
    _index = 0;
    _needsRespeak = false;
    try {
      await backend.stop();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    // 停止后锁屏控件不该还显示着这本书。
    unawaited(_clearNowPlayingQuietly());
    _emit(_supported ? SpeechState.idle : SpeechState.unavailable);
  }

  /// 跳到第 [index] 片继续读（听书进度条 / 手动跳转）。
  ///
  /// 暂停状态下跳转只改位置、保持暂停：继续时从新位置重新下发（见 [_needsRespeak]）。
  Future<String?> seekToSegment(int index) async {
    if (_destroyed) return '页面已销毁';
    if (_segments.isEmpty) return '当前没有朗读内容';
    final wasPaused = _state.value == SpeechState.paused;
    _cancelWatch();
    try {
      await backend.stop();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    _moveToSegment(index.clamp(0, _segments.length - 1));
    if (wasPaused) {
      _needsRespeak = true;
      _emit(SpeechState.paused);
      return null;
    }
    _emit(SpeechState.speaking);
    return _speakCurrent();
  }

  /// 释放会话：正在朗读时先停止，再退订事件、释放快照。
  Future<void> dispose() async {
    if (_destroyed) return;
    if (isActive || isPaused) {
      try {
        await backend.stop();
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
    // 页面退出时把锁屏控件一并收掉（不等原生回调，避免卡住释放路径）。
    unawaited(_clearNowPlayingQuietly());
    _destroyed = true;
    _cancelWatch();
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _state.dispose();
  }

  /// 清锁屏信息；任何失败只记日志（它是增强项，不该影响主链路）。
  Future<void> _clearNowPlayingQuietly() async {
    final capability = _nowPlayingCapability;
    if (capability == null) return;
    try {
      await capability.clearNowPlaying();
    } catch (error, stackTrace) {
      LumeLog.warn('[speech] 锁屏信息清除失败: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  // ------------------------------------------------------------------ 内部

  /// 切到第 [index] 片并把位置口径对齐到该片起点。
  void _moveToSegment(int index) {
    _index = index;
    final segment = _segments[index];
    _segmentStart = segment.start;
    _position = segment.start;
  }

  /// 朗读当前片段；返回失败原因（null 表示已下发）。
  Future<String?> _speakCurrent() async {
    final segment = _segments[_index];
    try {
      await backend.speak(segment.text);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _fail(
        '朗读失败',
        cause: SpeechEvent(SpeechEventKind.failed, message: '$error'),
      );
      return '朗读失败';
    }
    _armWatch();
    return null;
  }

  void _onBackendEvent(SpeechEvent event) {
    if (_destroyed) return;
    switch (event.kind) {
      case SpeechEventKind.started:
        // 引擎有动静就喂看门狗：只在「完全没动静」时才兜底。
        _armWatch();
        _emit(SpeechState.speaking);
        _notify(event);
      case SpeechEventKind.progress:
        _armWatch();
        final offset = event.charOffset;
        if (offset != null) {
          _position = _segmentStart + offset.clamp(0, _currentLength);
          _positionCallback();
        }
        _notify(event);
      case SpeechEventKind.finished:
        _cancelWatch();
        // 读完一段：位置推到段末，通知页面（跟读翻页），然后自动续读下一段。
        _position = _segmentStart + _currentLength;
        _positionCallback();
        _segmentFinishedCallback(_position);
        _notify(event);
        unawaited(_advance());
      case SpeechEventKind.paused:
        _cancelWatch();
        _emit(SpeechState.paused);
        _notify(event);
      case SpeechEventKind.resumed:
        _armWatch();
        _emit(SpeechState.speaking);
        _notify(event);
      case SpeechEventKind.stopped:
        _cancelWatch();
        _emit(_supported ? SpeechState.idle : SpeechState.unavailable);
        _notify(event);
      case SpeechEventKind.failed:
        _fail(event.message ?? '语音朗读失败', cause: event);
    }
  }

  /// 读完一段后推进：还有就接着读，读完就收敛到未朗读。
  Future<void> _advance() async {
    if (_destroyed) return;
    if (_state.value != SpeechState.speaking) return;
    if (_index + 1 >= _segments.length) {
      _emit(SpeechState.idle);
      // 全部读完：这是「本章读完」的唯一信号（见 [onCompleted] 说明）。
      _completedCallback();
      return;
    }
    _moveToSegment(_index + 1);
    await _speakCurrent();
  }

  int get _currentLength => _segments.isEmpty
      ? 0
      : _segments[_index.clamp(0, _segments.length - 1)].text.length;

  /// 失败收敛：回到可重试状态，原因写进事件回调。
  void _fail(String message, {SpeechEvent? cause}) {
    _cancelWatch();
    _emit(_supported ? SpeechState.idle : SpeechState.unavailable);
    if (cause != null) _notify(cause);
  }

  void _emit(SpeechState next) {
    if (_destroyed) return;
    _state.value = next;
  }

  void _positionCallback() {
    if (_destroyed) return;
    final callback = onPosition;
    if (callback == null) return;
    try {
      callback(_position);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  void _segmentFinishedCallback(int charOffset) {
    if (_destroyed) return;
    final callback = onSegmentFinished;
    if (callback == null) return;
    try {
      callback(charOffset);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  void _completedCallback() {
    if (_destroyed) return;
    final callback = onCompleted;
    if (callback == null) return;
    try {
      callback();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  void _notify(SpeechEvent event) {
    if (_destroyed) return;
    final callback = onEvent;
    if (callback == null) return;
    try {
      callback(event);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  /// 喂看门狗：静默超过 [silenceTimeout] 就按读完推进，避免会话卡死。
  void _armWatch() {
    _cancelWatch();
    _watch = Timer(silenceTimeout, () {
      if (_destroyed || _state.value != SpeechState.speaking) return;
      LumeLog.warn('[speech] 引擎静默超时，按读完处理并推进');
      _position = _segmentStart + _currentLength;
      _positionCallback();
      _segmentFinishedCallback(_position);
      unawaited(_advance());
    });
  }

  void _cancelWatch() {
    _watch?.cancel();
    _watch = null;
  }
}
