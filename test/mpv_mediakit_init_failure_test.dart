import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_kernel_launcher.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// MPV 初始化抛「MediaKit 未初始化」异常时的自动降级验证。
///
/// 复现的是真机日志里的那条异常：
/// `Exception: MediaKit.ensureInitialized must be called before using any API
///  from package:media_kit.`（栈顶在 `NativeLibrary.path` ← `new NativePlayer`）。
/// 期望：异常被自动捕获、丢弃 MPV、回退 AVPlayer、弹 Toast，
/// 且**绝不把 MPV 写进持久化配置**（避免下次进来又复现）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 真机日志里的原文（用于判断降级是否按预期发生）。
  const mediaKitNotInitialized =
      'Exception: MediaKit.ensureInitialized must be called before using any '
      'API from package:media_kit.';

  late Directory root;

  setUp(() async {
    PlayerFactory.clearMpvInitFailure();
    root = Directory.systemTemp.createTempSync('lume_box_mpv_init');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    // 库必须在真实时钟里先打开：testWidgets 的 fake-async 里等不到真实异步。
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    PlayerFactory.clearMpvInitFailure();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('启动器层：异常被捕获并回退', () {
    test('MPV 抛 MediaKit 未初始化异常 → 回退 AVPlayer + 标准提示', () async {
      final launcher = PlayerKernelLauncher(
        factory: (kernel) {
          if (kernel == PlayerKernel.mpv) {
            throw Exception(mediaKitNotInitialized);
          }
          return _FakePlayer(kernel);
        },
      );

      // 不抛异常：整个降级链必须自己把异常吃掉。
      final launch = await launcher.launch(PlayerKernel.mpv);

      expect(launch, isNotNull);
      expect(launch!.kernel, PlayerKernel.avplayer, reason: '自动降级到 AVPlayer');
      expect(launch.fallbackFrom, PlayerKernel.mpv);
      expect(launch.message, 'MPV初始化失败，已自动切换回AVPlayer播放器');
      expect(PlayerFactory.mpvInitFailed, isTrue, reason: '本次运行熔断 MPV');
    });

    test('熔断后 MPV 不再被放行（逃生入口会给出原因）', () {
      PlayerFactory.markMpvInitFailed();

      expect(PlayerFactory.mpvInitFailed, isTrue);
      expect(
        PlayerFactory.unavailableReason(PlayerKernel.mpv),
        contains('MPV 初始化失败'),
      );
    });
  });
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

  @override
  Future<void> dispose() async {}
}
