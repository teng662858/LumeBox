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
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

import 'support/fake_source_manager.dart';

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
          if (kernel == PlayerKernel.mpv) throw Exception(mediaKitNotInitialized);
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

  group('页面层：回退、提示与"不落库"', () {
    testWidgets('MPV 初始化抛异常：弹 Toast、用 AVPlayer、库里不写 MPV', (tester) async {
      final created = <_FakePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPage(
            catalog: _Catalog(const <PlayerKernel>{
              PlayerKernel.avplayer,
              PlayerKernel.mpv,
            }),
            playerFactory: (kernel) {
              if (kernel == PlayerKernel.mpv) {
                throw Exception(mediaKitNotInitialized);
              }
              final player = _FakePlayer(kernel);
              created.add(player);
              return player;
            },
            sourceManager: FakeSourceManager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 首页是图源展示页：先切到「播放」页签（设置齿轮在那里）。
      await tester.tap(find.widgetWithText(Tab, '播放'));
      await tester.pumpAndSettle();

      // 在设置里选 MPV：初始化抛异常 → 自动回退。
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      // 1) Toast 文案（任务书指定原文）。
      expect(
        find.text('MPV初始化失败，已自动切换回AVPlayer播放器'),
        findsOneWidget,
      );
      // 2) 实际生效的是 AVPlayer：页面上就是 AVPlayer 的渲染面。
      expect(find.text('fake:avplayer'), findsOneWidget);
      expect(
        created.map((player) => player.kernel).toSet(),
        <PlayerKernel>{PlayerKernel.avplayer},
        reason: 'MPV 从未被真正采用',
      );
      // 3) 关键约束：错误内核不进持久化配置。
      final store = await VideoPlayerSettingsStore.open();
      expect(
        store.load().kernel,
        PlayerKernel.avplayer,
        reason: 'MPV 初始化失败时禁止把 MPV 写入本地配置',
      );
      // 4) 熔断生效：本次运行内不再尝试 MPV。
      expect(PlayerFactory.mpvInitFailed, isTrue);
    });

    testWidgets('启动时库里的内核是 MPV 且初始化失败：照样回退并改写为 AVPlayer', (tester) async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(
        const PlayerSettings(
          kernel: PlayerKernel.mpv,
          speed: 1.5,
          subtitlesEnabled: false,
        ),
      );
      store.close();

      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPage(
            catalog: _Catalog(const <PlayerKernel>{
              PlayerKernel.avplayer,
              PlayerKernel.mpv,
            }),
            playerFactory: (kernel) {
              if (kernel == PlayerKernel.mpv) {
                throw Exception(mediaKitNotInitialized);
              }
              return _FakePlayer(kernel);
            },
            sourceManager: FakeSourceManager(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('MPV初始化失败，已自动切换回AVPlayer播放器'),
        findsOneWidget,
      );

      final probe = await VideoPlayerSettingsStore.open();
      final saved = probe.load();
      expect(saved.kernel, PlayerKernel.avplayer, reason: '回退后的内核落库');
      expect(saved.speed, 1.5, reason: '只改内核，倍速与字幕保留');
      expect(saved.subtitlesEnabled, isFalse);
    });
  });
}

class _Catalog implements PlayerKernelCatalog {
  const _Catalog(this.available);

  final Set<PlayerKernel> available;

  @override
  bool isAvailable(PlayerKernel kernel) => available.contains(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
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

  @override
  Future<void> dispose() async {}
}
