import 'dart:io';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:flutter/services.dart';
import 'package:lume_box/features/video/playback_entry_preparation.dart';
import 'package:lume_box/core/player/playback_orientation.dart';

import 'dart:async';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => PlayerFactory.clearMpvInitFailure());
  tearDown(() => PlayerFactory.clearMpvInitFailure());

  for (final portrait in [false, true]) {
    test('显式方向预算可等待迟到1.2秒的真实尺寸：portrait=$portrait', () async {
      PlaybackOrientationController.instance.resetForTesting();
      final directions = <List<dynamic>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          directions.add(call.arguments as List<dynamic>);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final player = _DelayedDimensionsPlayer(portrait);
      final prelaunch = PlayerPrelaunch.start(
        PlayerKernel.avplayer,
        factory: (_) => player,
      );
      final media = PlayerMedia(
        uri: Uri.parse('https://example.test/orientation.mp4'),
      );
      await preparePlaybackEntry(
        prelaunch,
        media,
        null,
        sizeTimeout: const Duration(seconds: 2),
      );
      await applyPlaybackEntryOrientation(prelaunch);
      expect(prelaunch.preparedStats?.width, portrait ? 720 : 1920);
      expect(
        directions.single,
        portrait
            ? ['DeviceOrientation.portraitUp']
            : [
                'DeviceOrientation.landscapeLeft',
                'DeviceOrientation.landscapeRight',
              ],
      );
      expect((await prelaunch.take())?.player, same(player));
      expect(player.loads, 1);
      await player.dispose();
    });
  }

  test('entry preflight reads portrait dimensions and transfers the same loaded player', () async {
    final player = _PreflightPlayer();
    final prelaunch = PlayerPrelaunch.start(
      PlayerKernel.avplayer,
      factory: (_) => player,
    );
    final media = PlayerMedia(uri: Uri.parse('https://example.com/short.mp4'));
    await prelaunch.prepareMedia(media);
    expect(prelaunch.preparedStats?.width, 720);
    expect(prelaunch.preparedStats?.height, 1280);
    expect(prelaunch.hasPreparedMedia(media), isTrue);
    expect(player.loads, 1);
    expect(player.pauses, 1);
    expect((await prelaunch.take())?.player, same(player));
    expect(await prelaunch.take(), isNull);
    await prelaunch.discard();
    expect(player.disposals, 0);
    await player.dispose();
  });

  test('default orientation preflight does not hold the loaded player for late dimensions', () async {
    final player = _DelayedDimensionsPlayer(false);
    final prelaunch = PlayerPrelaunch.start(
      PlayerKernel.avplayer,
      factory: (_) => player,
    );
    final media = PlayerMedia(uri: Uri.parse('https://example.test/late.mp4'));
    await preparePlaybackEntry(prelaunch, media, null);
    expect(prelaunch.preparedStats, isNull);
    expect(prelaunch.hasPreparedMedia(media), true);
    expect((await prelaunch.take())?.player, same(player));
    expect(player.loads, 1);
    await player.dispose();
  });

  test('route enters before a pending media load and later takes the same instance', () async {
    final root = await Directory.systemTemp.createTemp('lume-entry-budget-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    addTearDown(() async {
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await root.delete(recursive: true);
    });
    PlaybackOrientationController.instance.resetForTesting();
    final library = await ReadingLibrary.open(Section.video);
    final player = _PreflightPlayer()..pending = Completer<void>();
    final prelaunch = PlayerPrelaunch.start(
      PlayerKernel.avplayer,
      factory: (_) => player,
    );
    final media = PlayerMedia(
      uri: Uri.parse('https://example.test/pending.mp4'),
    );
    final entry = await preparePlaybackRoute(
      media,
      library: library,
      prelaunch: prelaunch,
    );
    expect(entry, same(prelaunch));
    expect(player.pending!.isCompleted, false);
    player.pending!.complete();
    expect((await prelaunch.take())?.player, same(player));
    expect(prelaunch.hasPreparedMedia(media), true);
    expect(player.loads, 1);
    await player.dispose();
  });

  testWidgets(
    'slow first load over 4s keeps its session instead of downloading again',
    (tester) async {
      final player = _PreflightPlayer()..pending = Completer<void>();
      final prelaunch = PlayerPrelaunch.start(
        PlayerKernel.avplayer,
        factory: (_) => player,
      );
      final media = PlayerMedia(
        uri: Uri.parse('https://example.test/slow.m3u8'),
      );
      final preparing = prelaunch.prepareMedia(media);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(player.disposals, 0);
      expect(player.loads, 1);
      player.pending!.complete();
      await tester.pump();
      await preparing;
      expect((await prelaunch.take())?.player, same(player));
      expect(prelaunch.hasPreparedMedia(media), isTrue);
      await player.dispose();
    },
  );

  test('timed out preflight disposes the loading instance and allows a fresh launch', () async {
    final player = _PreflightPlayer()..pending = Completer<void>();
    final prelaunch = PlayerPrelaunch.start(
      PlayerKernel.avplayer,
      factory: (_) => player,
    );
    await prelaunch.prepareMedia(
      PlayerMedia(uri: Uri.parse('https://example.com/slow.mp4')),
      timeout: const Duration(milliseconds: 10),
    );
    expect(prelaunch.preparedStats, isNull);
    expect(await prelaunch.take(), isNull);
    expect(player.disposals, 1);
    player.pending!.complete();
  });

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

class _PreflightPlayer extends _FakePlayer {
  _PreflightPlayer() : super(PlayerKernel.avplayer);
  int loads = 0, pauses = 0;
  Completer<void>? pending;
  @override
  Future<void> load(PlayerMedia media) async {
    loads++;
    if (pending != null) await pending!.future;
    _stats.value = const PlayerStats(width: 720, height: 1280);
  }

  @override
  Future<void> pause() async {
    pauses++;
  }
}

class _FakePlayer extends AbstractPlayer {
  _FakePlayer(this.kernel);

  final PlayerKernel kernel;

  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(),
  );
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
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => Text('fake:${kernel.id}');

  int disposals = 0;

  @override
  Future<void> dispose() async => disposals += 1;
}

class _DelayedDimensionsPlayer extends _FakePlayer {
  _DelayedDimensionsPlayer(this.portrait) : super(PlayerKernel.avplayer);
  final bool portrait;
  Timer? metadata;
  int loads = 0;
  @override
  Future<void> load(PlayerMedia media) async {
    loads++;
    metadata = Timer(const Duration(milliseconds: 1200), () {
      _stats.value = PlayerStats(
        width: portrait ? 720 : 1920,
        height: portrait ? 1280 : 1080,
      );
    });
  }

  @override
  Future<void> dispose() async {
    metadata?.cancel();
    await super.dispose();
  }
}
