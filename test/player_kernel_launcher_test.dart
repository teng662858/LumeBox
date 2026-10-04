import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_kernel_launcher.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';

/// 内核启动器的验证（MPV 卡死修复的核心）：异步创建、8 秒超时、
/// 失败丢弃实例并回退 AVPlayer、失败内核熔断。
void main() {
  setUp(() => PlayerFactory.clearMpvInitFailure());
  tearDown(() => PlayerFactory.clearMpvInitFailure());

  test('正常内核：创建成功即原样返回，没有回退', () async {
    final launcher = PlayerKernelLauncher(
      factory: (kernel) => _FakePlayer(kernel),
    );

    final launch = await launcher.launch(PlayerKernel.avplayer);

    expect(launch, isNotNull);
    expect(launch!.kernel, PlayerKernel.avplayer);
    expect(launch.didFallback, isFalse);
    expect(launch.message, isNull);
    expect(PlayerFactory.mpvInitFailed, isFalse);
  });

  test('后台异步：创建动作不会在调用它的同步路径上执行', () async {
    var created = 0;
    final launcher = PlayerKernelLauncher(
      factory: (kernel) {
        created += 1;
        return _FakePlayer(kernel);
      },
    );

    final future = launcher.launch(PlayerKernel.avplayer);
    // 关键：刚调用 launch 时同步阶段里还没有碰过工厂（先让 UI 渲染加载态）。
    expect(created, 0, reason: '创建必须排在事件循环的后续任务里');
    await future;
    expect(created, 1);
  });

  test('MPV 抛异常：丢弃实例、回退 AVPlayer、熔断并给出提示', () async {
    var mpvCreated = 0;
    final launcher = PlayerKernelLauncher(
      factory: (kernel) {
        if (kernel == PlayerKernel.mpv) {
          mpvCreated += 1;
          throw StateError('libmpv 装载失败');
        }
        return _FakePlayer(kernel);
      },
    );

    final launch = await launcher.launch(PlayerKernel.mpv);

    expect(mpvCreated, 1);
    expect(launch, isNotNull);
    expect(launch!.kernel, PlayerKernel.avplayer, reason: '实际生效的是 AVPlayer');
    expect(launch.fallbackFrom, PlayerKernel.mpv);
    expect(launch.message, 'MPV初始化失败，已自动切换回AVPlayer播放器');
    expect(PlayerFactory.mpvInitFailed, isTrue, reason: '本次运行内熔断 MPV');
    expect(
      PlayerFactory.unavailableReason(PlayerKernel.mpv),
      contains('MPV 初始化失败'),
    );
  });

  test('MPV 初始化超预算：丢弃实例并回退（不把用户挂在等待里）', () async {
    _FakePlayer? discarded;
    final stuck = PlayerKernelLauncher(
      factory: (kernel) {
        if (kernel != PlayerKernel.mpv) return _FakePlayer(kernel);
        // 模拟「原生初始化把线程卡住」：同步阻塞超过预算，然后才返回实例。
        final end = DateTime.now().add(const Duration(milliseconds: 200));
        while (DateTime.now().isBefore(end)) {
          // busy wait
        }
        discarded = _FakePlayer(kernel);
        return discarded;
      },
      timeout: const Duration(milliseconds: 50),
    );

    final launch = await stuck.launch(PlayerKernel.mpv);

    expect(launch, isNotNull);
    expect(launch!.kernel, PlayerKernel.avplayer, reason: '超预算的内核不许生效');
    expect(launch.didFallback, isTrue);
    expect(launch.message, 'MPV初始化失败，已自动切换回AVPlayer播放器');
    expect(PlayerFactory.mpvInitFailed, isTrue);
    expect(discarded, isNotNull, reason: '实例建出来了');
    expect(discarded!.disposals, 1, reason: '超预算的实例必须被丢弃（释放）');
  });

  test('连续失败：熔断后 isAvailable 不再放行 MPV', () async {
    PlayerFactory.markMpvInitFailed();
    expect(PlayerFactory.mpvInitFailed, isTrue);
    // 平台目录以熔断状态回答（Windows 上本就不可用，这里断言的是原因文案）。
    expect(
      PlayerFactory.unavailableReason(PlayerKernel.mpv),
      contains('已自动回退 AVPlayer'),
    );
    PlayerFactory.clearMpvInitFailure();
    expect(PlayerFactory.mpvInitFailed, isFalse);
  });

  test('AVPlayer 也起不来：返回 null（没有可回退的内核），不误熔断', () async {
    final launcher = PlayerKernelLauncher(
      factory: (kernel) => null,
      timeout: const Duration(milliseconds: 20),
    );

    expect(await launcher.launch(PlayerKernel.avplayer), isNull);
    expect(launcher, isNotNull);
    expect(PlayerFactory.mpvInitFailed, isFalse);
  });

  test('MPV 失败但 AVPlayer 也起不来：回退失败返回 null', () async {
    final launcher = PlayerKernelLauncher(
      factory: (kernel) =>
          kernel == PlayerKernel.mpv ? throw StateError('mpv 崩了') : null,
    );

    expect(await launcher.launch(PlayerKernel.mpv), isNull);
    expect(PlayerFactory.mpvInitFailed, isTrue, reason: 'MPV 已判定失败');
  });
}

class _FakePlayer implements AbstractPlayer {
  _FakePlayer(this.kernel);

  final PlayerKernel kernel;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    const PlayerStats(engineLabel: 'fake'),
  );

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => Text('fake:${kernel.id}');

  int disposals = 0;

  @override
  Future<void> dispose() async => disposals += 1;
}
