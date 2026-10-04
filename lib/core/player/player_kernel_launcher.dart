import 'dart:async';

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'player_factory.dart';
import 'player_settings.dart';

/// 一次内核启动的结果。
class PlayerLaunch {
  const PlayerLaunch({
    required this.player,
    required this.kernel,
    this.fallbackFrom,
    this.message,
  });

  /// 真正可用的播放器。
  final AbstractPlayer player;

  /// **实际生效**的内核（回退后是 AVPlayer，不是用户点的那个）。
  final PlayerKernel kernel;

  /// 非空表示这是一次「初始化失败后回退」：值是被丢弃的那个内核。
  final PlayerKernel? fallbackFrom;

  /// 回退提示文案（页面直接拿它弹 Toast）。
  final String? message;

  bool get didFallback => fallbackFrom != null;
}

/// 内核启动器：把「创建播放器」从 UI 同步路径里摘出来，并加超时保护。
///
/// 任务书（MPV 卡死修复）要求的三件事都落在这里：
/// 1. **后台异步**：创建动作排在事件循环的后续任务里（先让页面把「正在准备播放器」
///    渲染出来），绝不出现在 `build` / `initState` 的同步路径上；
/// 2. **8 秒超时**：初始化整体限时 [PlayerFactory.mpvInitTimeout]；超时或抛错
///    一律丢弃刚建出来的实例（[AbstractPlayer.dispose]），回退 AVPlayer；
/// 3. **熔断**：失败的内核在本次运行内标记（[PlayerFactory.markMpvInitFailed]），
///    并交由页面决定落库——**失败的那次绝不写进配置**。
///
/// 实现边界（如实记录）：原生库装载这类调用是同步阻塞的，Dart 无法抢占式中断
/// 它，所以「8 秒」约束的是**我们等待创建的时长**：超时后立即丢弃 + 回退，用户
/// 不会再卡在没有任何反应的状态；但若底层调用本身耗时很久，UI 线程在那一小段
/// 里仍会被占住（这是 FFI 的固有性质，不是本层能绕开的）。
class PlayerKernelLauncher {
  PlayerKernelLauncher({
    AbstractPlayer? Function(PlayerKernel kernel)? factory,
    this.timeout = PlayerFactory.mpvInitTimeout,
  }) : _factory = factory ?? ((kernel) => PlayerFactory.create(kernel: kernel));

  final AbstractPlayer? Function(PlayerKernel kernel) _factory;

  /// 初始化整体限时。
  final Duration timeout;

  /// 启动内核；返回 null 表示连兜底内核都不可用（调用方按骨架处理）。
  Future<PlayerLaunch?> launch(PlayerKernel kernel) async {
    // 让出一帧：把创建排到当前帧之后，UI 先渲染「准备中」。
    await Future<void>.delayed(Duration.zero);

    final player = await _createWithin(kernel);
    if (player != null) {
      return PlayerLaunch(player: player, kernel: kernel);
    }

    // 主内核起不来：能回退就回退，回退不了就把失败如实交出去。
    final fallback = _fallbackFor(kernel);
    if (fallback == null) {
      if (kernel != PlayerKernel.avplayer) _markFailed(kernel);
      return null;
    }
    _markFailed(kernel);
    final fallbackPlayer = await _createWithin(fallback);
    if (fallbackPlayer == null) return null;
    return PlayerLaunch(
      player: fallbackPlayer,
      kernel: fallback,
      fallbackFrom: kernel,
      message: '${kernel.label}初始化失败，已自动切换回${fallback.label}播放器',
    );
  }

  /// 限时创建：超时或抛错都丢弃实例、返回 null（不向调用方抛异常）。
  Future<AbstractPlayer?> _createWithin(PlayerKernel kernel) async {
    final started = DateTime.now();
    AbstractPlayer? created;
    try {
      created = await Future<AbstractPlayer?>(() => _factory(kernel))
          .timeout(timeout);
    } on TimeoutException {
      LumeLog.warn(
        '[player] ${kernel.label} 初始化超时（${timeout.inSeconds}s），丢弃该实例',
      );
      return null;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] ${kernel.label} 初始化异常，丢弃该实例');
      return null;
    }
    if (created == null) return null;

    // 耗时复核：原生初始化是同步阻塞调用，Dart 无法抢占式中断它——那种情况下
    // `.timeout` 的定时器要等阻塞结束才有机会跑，甚至会被已完成的 future 抢先。
    // 因此这里再量一次钟：实际耗时超预算就判定失败，把刚建出来的实例丢掉。
    final elapsed = DateTime.now().difference(started);
    if (elapsed > timeout) {
      LumeLog.warn(
        '[player] ${kernel.label} 初始化耗时 ${elapsed.inMilliseconds}ms '
        '超过预算 ${timeout.inMilliseconds}ms，判定失败并丢弃实例',
      );
      await _discard(created, kernel);
      return null;
    }
    return created;
  }

  /// 丢弃不用的实例：释放失败只记日志，不影响回退流程。
  Future<void> _discard(AbstractPlayer player, PlayerKernel kernel) async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('[player] 丢弃 ${kernel.label} 实例时释放失败');
    }
  }

  /// 回退目标：AVPlayer（除它以外没有可兜底的内核）。
  PlayerKernel? _fallbackFor(PlayerKernel kernel) =>
      kernel == PlayerKernel.avplayer ? null : PlayerKernel.avplayer;

  void _markFailed(PlayerKernel kernel) {
    if (kernel == PlayerKernel.mpv) PlayerFactory.markMpvInitFailed();
    LumeLog.warn('[player] ${kernel.label} 初始化失败：本次运行内不再提供');
  }
}
