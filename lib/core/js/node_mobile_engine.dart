import 'dart:async';

import 'package:flutter/services.dart';

import '../util/lume_log.dart';
import 'sandbox/sandbox_result.dart';

/// Android 专属的 Node-Mobile 猫源引擎（Dart 侧）。
///
/// 原生侧（Kotlin + libnode，Android 构建专属）尚未集成：本类通过方法通道
/// `lumebox/node_mobile` 与「一个图源一个原生 Node 实例」通信，通道契约由测试
/// 固定；原生缺失时 [isSupported] 如实返回 false（引擎在设置页标成不可用），
/// 不假装可用。iOS / Windows 构建不注册这个引擎，原生模块也不会进那两个平台。
///
/// 隔离与回收（任务书第 3 条）：
/// - **实例隔离**：一个引擎只服务一个图源，`start` 带上 sourceId，
///   由原生侧建独立 Node 实例（独立 JS 运行时）；
/// - **超时销毁**：加载 / 调用超时即向原生发 `dispose` 并标记污染，
///   下一次调用重建全新实例（绝不复用可能带着残留状态的实例）；
/// - **异常回收**：原生异常同样按污染处理；
/// - **释放**：`dispose` 无条件杀掉原生实例，且不吃异常（原生缺失也不崩）。
///
/// 网络与文件 IO：原生侧不暴露 node 的 fs / http；执行期注入的桥接对象只连到
/// Dart 侧的同一套宿主代理（与 QuickJS 侧一条纪律）。
class NodeMobileEngine {
  NodeMobileEngine({
    required this.sourceId,
    MethodChannel? channel,
    this.callTimeout = const Duration(seconds: 4),
    this.startTimeout = const Duration(seconds: 10),
    this.disposeTimeout = const Duration(seconds: 2),
  }) : _channel = channel ?? const MethodChannel(methodChannelName);

  /// 通道名（原生实现即 Android 侧的 Kotlin 模块）。
  static const String methodChannelName = 'lumebox/node_mobile';

  /// 本实例服务的图源标识。
  final String sourceId;

  final MethodChannel _channel;

  /// 单次加载 / 调用 / 元信息读取的墙钟预算。
  final Duration callTimeout;

  /// 起实例的预算（Node 启动比单次调用重）。
  final Duration startTimeout;

  /// 销毁实例的预算。
  final Duration disposeTimeout;

  bool _started = false;
  bool _disposed = false;
  bool _poisoned = false;
  int _generation = 0;

  /// 原生实例代数：每次重建递增（与 QuickJS 沙箱同一语义）。
  int get generation => _generation;

  /// 是否已被判污染（超时 / 原生异常后为 true，重建时复位）。
  bool get isPoisoned => _poisoned;

  bool get isDisposed => _disposed;

  /// 原生模块是否就绪。探测而不是假设：Android 之外的构建与「原生未集成」
  /// 都如实返回 false。
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
  }

  /// 载入脚本。失败（含超时回收）返回 false。
  Future<bool> loadScript(String script) async {
    if (_disposed) return false;
    if (!await _ensureStarted()) return false;
    try {
      final loaded = await _channel
          .invokeMethod<bool>('loadScript', <String, Object?>{'script': script})
          .timeout(callTimeout);
      return loaded ?? false;
    } catch (error, stackTrace) {
      await _recycle('载入脚本', error, stackTrace);
      return false;
    }
  }

  /// 读取脚本声明的元信息。
  Future<Map<String, Object?>?> metadata() async {
    if (_disposed) return null;
    if (!await _ensureStarted()) return null;
    try {
      final reply = await _channel.invokeMethod<Object?>('metadata').timeout(callTimeout);
      return reply is Map ? Map<String, Object?>.from(reply) : null;
    } catch (error, stackTrace) {
      await _recycle('读取元信息', error, stackTrace);
      return null;
    }
  }

  /// 调用图源方法，返回与沙箱同一套结果信封（[SandboxResult]），
  /// 因此数据源层的失败归一不需要为 Node-Mobile 单开分支。
  Future<SandboxResult> callResult(String method, [Object? argument]) async {
    if (_disposed) {
      return const SandboxFailure(SandboxErrorKind.disposed, '引擎已释放');
    }
    if (!await _ensureStarted()) {
      return const SandboxFailure(
        SandboxErrorKind.unsupported,
        'Node-Mobile 原生实例不可用（原生模块未集成或启动失败）',
      );
    }
    try {
      final reply = await _channel.invokeMethod<Object?>('call', <String, Object?>{
        'method': method,
        'argument': argument,
      }).timeout(callTimeout);
      return _decodeReply(reply);
    } on TimeoutException {
      await _recycle('调用 $method', TimeoutException('调用超时'), StackTrace.current);
      return const SandboxFailure(
        SandboxErrorKind.timeout,
        'Node-Mobile 调用超时：已销毁实例，下次调用重建',
      );
    } catch (error, stackTrace) {
      await _recycle('调用 $method', error, stackTrace);
      return SandboxFailure(SandboxErrorKind.engine, 'Node-Mobile 调用失败：$error');
    }
  }

  /// 杀掉原生实例并释放通道。可重复调用；原生缺失时不抛。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    try {
      await _channel
          .invokeMethod<void>('dispose', <String, Object?>{'sourceId': sourceId})
          .timeout(disposeTimeout);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }

  /// 起实例（幂等）。成功即视为新一代。
  Future<bool> _ensureStarted() async {
    if (_started) return true;
    try {
      final started = await _channel
          .invokeMethod<bool>('start', <String, Object?>{'sourceId': sourceId})
          .timeout(startTimeout);
      _started = started ?? false;
      if (_started) {
        _poisoned = false;
        _generation += 1;
      }
      return _started;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      _started = false;
      return false;
    }
  }

  /// 超时 / 异常后的回收：立刻销毁原生实例并标记污染，绝不复用。
  Future<void> _recycle(String stage, Object error, StackTrace stackTrace) async {
    LumeLog.warn('[$sourceId] Node-Mobile $stage 失败，回收实例：$error');
    LumeLog.error(error, stackTrace);
    _poisoned = true;
    _started = false;
    try {
      await _channel
          .invokeMethod<void>('dispose', <String, Object?>{'sourceId': sourceId})
          .timeout(disposeTimeout);
    } catch (ignored, stack) {
      LumeLog.error(ignored, stack);
    }
  }

  /// 原生回包 → 沙箱结果信封。
  ///
  /// 约定：`{ok: true, value: <JSON>}` 或 `{ok: false, message: '...'}`；
  /// 其余形态按协议错误处理（宁可报协议错，也不猜）。
  static SandboxResult _decodeReply(Object? reply) {
    if (reply is Map) {
      final ok = reply['ok'] == true;
      if (ok) return SandboxSuccess(reply['value']);
      final message = '${reply['message'] ?? 'Node-Mobile 调用失败'}';
      return SandboxFailure(SandboxErrorKind.script, message);
    }
    return const SandboxFailure(
      SandboxErrorKind.protocol,
      'Node-Mobile 回包不是约定的 JSON 信封',
    );
  }
}
