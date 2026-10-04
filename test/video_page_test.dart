import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/pip.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 视频板块接线的验证：设置加载与生效、打开媒体、画中画按钮与事件、
/// 运行时切换内核（拆旧建新 + 位置接回 + 落库）、退出时的资源顺序。
///
/// 平台能力与原生后端都用替身注入，因此在 Windows 上就能跑完整链路；
/// 真实平台目录下非 iOS 只渲染骨架占位，另有用例覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_video');
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
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('装备替身的完整链路', () {
    late List<String> log;

    setUp(() {
      log = <String>[];
    });

    Future<List<_FakePlayer>> pumpVideo(
      WidgetTester tester, {
      required Set<PlayerKernel> available,
      _FakePipBackend? pip,
    }) async {
      final created = <_FakePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPage(
            catalog: _FakeCatalog(available),
            playerFactory: (kernel) {
              final player = _FakePlayer(kernel, log);
              created.add(player);
              return player;
            },
            pipBackend: pip,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return created;
    }

    Future<void> openMedia(WidgetTester tester) async {
      await tester.enterText(
        find.byType(TextField),
        'https://example.com/a.mp4',
      );
      await tester.tap(find.byIcon(Icons.download));
      await tester.pumpAndSettle();
    }

    testWidgets('启动：按本板块设置创建内核并立即应用设置', (tester) async {
      final store = await VideoPlayerSettingsStore.open();
      store.save(const PlayerSettings(speed: 1.5));

      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );

      expect(created, hasLength(1));
      expect(created.single.kernel, PlayerKernel.avplayer);
      expect(created.single.applied?.speed, 1.5);
      expect(find.text('player:avplayer'), findsOneWidget);
    });

    testWidgets('画中画：未加载媒体时进入被拒，加载后全链路可用', (tester) async {
      final pip = _FakePipBackend();
      addTearDown(pip.close);
      await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
        pip: pip,
      );

      // 边界检查：没有媒体时进入被拒。
      await tester.tap(find.byTooltip('进入画中画'));
      await tester.pumpAndSettle();
      expect(find.text('媒体尚未就绪'), findsOneWidget);
      expect(pip.started, 0);
      // 清掉这条提示：SnackBar 串行展示，后面的断言才不会被它排在前面。
      ScaffoldMessenger.of(
        tester.element(find.byType(VideoPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();

      await openMedia(tester);
      await tester.tap(find.byTooltip('进入画中画'));
      await tester.pumpAndSettle();
      expect(pip.started, 1);

      // 原生 entered 事件把状态推到「画中画播放中」。
      pip.emit(PipEventKind.entered);
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出画中画'), findsOneWidget);

      await tester.tap(find.byTooltip('退出画中画'));
      await tester.pumpAndSettle();
      expect(pip.stopped, 1);
      expect(find.byTooltip('进入画中画'), findsOneWidget);

      // 原生失败事件 → 可读提示，不冒泡异常。
      pip.emit(PipEventKind.failed, message: '原生中断');
      await tester.pumpAndSettle();
      expect(find.text('原生中断'), findsOneWidget);
    });

    testWidgets('运行时切换内核：拆旧建新，媒体与位置接回，设置落库', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer, PlayerKernel.mpv},
      );

      await openMedia(tester);
      expect(created.single.media?.uri.toString(), 'https://example.com/a.mp4');
      created.single
          .setPosition(const Duration(seconds: 30), playing: true);
      await tester.pump();

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(created, hasLength(2));
      expect(created[0].disposals, 1, reason: '旧内核必须释放');
      final next = created[1];
      expect(next.kernel, PlayerKernel.mpv);
      expect(next.media?.uri.toString(), 'https://example.com/a.mp4');
      expect(next.seeks, contains(const Duration(seconds: 30)));
      expect(next.calls, contains('play'));
      expect(find.text('player:mpv'), findsOneWidget);

      // 落库：重新读取设置存储，内核已是 MPV。
      final store = await VideoPlayerSettingsStore.open();
      expect(store.load().kernel, PlayerKernel.mpv);
    });

    testWidgets('MPV 初始化失败：自动回退 AVPlayer、弹提示，且绝不把 MPV 写进配置', (tester) async {
      PlayerFactory.clearMpvInitFailure();
      addTearDown(PlayerFactory.clearMpvInitFailure);
      final created = <_FakePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPage(
            catalog: _FakeCatalog(const <PlayerKernel>{
              PlayerKernel.avplayer,
              PlayerKernel.mpv,
            }),
            playerFactory: (kernel) {
              // MPV 初始化失败：启动器必须丢弃它并回退 AVPlayer。
              if (kernel == PlayerKernel.mpv) throw StateError('libmpv 装载失败');
              final player = _FakePlayer(kernel, <String>[]);
              created.add(player);
              return player;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 切到 MPV：初始化抛错 → 回退 AVPlayer + 提示。
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        find.text('MPV初始化失败，已自动切换回AVPlayer播放器'),
        findsOneWidget,
        reason: '必须给用户可读提示',
      );
      expect(created, isNotEmpty);
      expect(
        created.every((player) => player.kernel == PlayerKernel.avplayer),
        isTrue,
        reason: 'MPV 从未被真正采用（创建阶段就失败了）',
      );
      expect(created.last.kernel, PlayerKernel.avplayer, reason: '页面回退到 AVPlayer');

      // 关键约束：失败的那次绝不写进库，避免下次进来又卡。
      final store = await VideoPlayerSettingsStore.open();
      expect(
        store.load().kernel,
        PlayerKernel.avplayer,
        reason: 'MPV 初始化失败时禁止把 MPV 写入持久化配置',
      );
    });

    testWidgets('HUD：显示当前内核给出的参数，换内核不改上层 UI', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer, PlayerKernel.mpv},
      );
      await openMedia(tester);

      // AVPlayer 内核：只有它拿得到的项（分辨率 + 缓冲）。
      created.single.pushStats(const PlayerStats(
        engineLabel: 'AVPlayer',
        width: 1280,
        height: 720,
        buffered: Duration(seconds: 4),
      ));
      await tester.pump();
      expect(find.text('AVPlayer'), findsOneWidget);
      expect(find.text('1280×720'), findsOneWidget);
      expect(find.text('缓冲 4s'), findsOneWidget);

      // 换成 MPV 内核：同一块 HUD 直接显示 MPV 的参数，页面代码零改动。
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      final mpv = created[1];
      mpv.pushStats(const PlayerStats(
        engineLabel: 'MPV',
        videoCodec: 'hevc',
        videoBitrateKbps: 1800,
        fps: 30,
        width: 1920,
        height: 1080,
        buffered: Duration(seconds: 9),
      ));
      await tester.pump();
      expect(find.text('MPV'), findsWidgets);
      expect(find.text('HEVC'), findsOneWidget);
      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.text('30FPS'), findsOneWidget);
      expect(find.text('1.8Mbps'), findsOneWidget);
      expect(find.text('缓冲 9s'), findsOneWidget);
      expect(find.text('1280×720'), findsNothing, reason: '旧内核的参数不该残留');
    });

    testWidgets('倍速改动即时生效并落库', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(created.single.applied?.speed, 1.5);
      final store = await VideoPlayerSettingsStore.open();
      expect(store.load().speed, 1.5);
    });

    testWidgets('退出页面：先退画中画、再释放播放器、最后关库', (tester) async {
      final pip = _FakePipBackend(log);
      addTearDown(pip.close);
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
        pip: pip,
      );
      await openMedia(tester);
      await tester.tap(find.byTooltip('进入画中画'));
      await tester.pumpAndSettle();
      pip.emit(PipEventKind.entered);
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(pip.stopped, 1);
      expect(created.single.disposals, 1);
      expect(
        log.indexOf('pip.stop'),
        lessThan(log.indexOf('player.dispose')),
        reason: '画中画必须在播放器释放之前退出',
      );
      expect(ReadingLibrary.find(Section.video), isNull, reason: '库句柄已关闭');
    });
  });

  testWidgets('设置库打不开：播放器不启动，页面给出可读提示', (tester) async {
    // 让本板块的目录解析失败：清掉作用域缓存并把 path_provider 置空。
    ReadingLibrary.close(Section.video);
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => null,
    );

    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPage(
          catalog: const _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
          playerFactory: (kernel) {
            created++;
            return _FakePlayer(kernel, <String>[]);
          },
          pipBackend: _FakePipBackend(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('播放器设置库不可用'), findsOneWidget);
    expect(created, 0);
  });

  testWidgets(
    '非 iOS（平台目录）：渲染 UI 骨架占位，不接线播放与画中画',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: LumeTheme.build(), home: const VideoPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      expect(
        find.text('播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位'),
        findsOneWidget,
      );
      expect(find.byTooltip('播放器设置'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    },
    skip: Platform.isIOS,
  );
}

class _FakeCatalog implements PlayerKernelCatalog {
  const _FakeCatalog(this.available);

  final Set<PlayerKernel> available;

  @override
  bool isAvailable(PlayerKernel kernel) => available.contains(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}

class _FakePipBackend implements PipBackend {
  _FakePipBackend([this.log]);

  final List<String>? log;
  int started = 0;
  int stopped = 0;

  final StreamController<PipEvent> _events =
      StreamController<PipEvent>.broadcast();

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<void> start() async {
    started++;
  }

  @override
  Future<void> stop() async {
    stopped++;
    log?.add('pip.stop');
  }

  @override
  Stream<PipEvent> get events => _events.stream;

  void emit(PipEventKind kind, {String? message}) =>
      _events.add(PipEvent(kind, message: message));

  Future<void> close() => _events.close();
}

class _FakePlayer implements AbstractPlayer {
  _FakePlayer(this.kernel, this.log);

  final PlayerKernel kernel;
  final List<String> log;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  /// 测试可控的 HUD 参数：验证「上层只吃 PlayerStats」。
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: 'fake'),
  );

  PlayerSettings? applied;
  PlayerMedia? media;
  int disposals = 0;
  final List<String> calls = <String>[];
  final List<Duration> seeks = <Duration>[];

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  /// 测试驱动：模拟内核推来新的 HUD 参数。
  void pushStats(PlayerStats value) => _stats.value = value;

  @override
  Future<void> load(PlayerMedia media) async {
    calls.add('load');
    this.media = media;
    _snapshot.value = PlayerSnapshot(duration: const Duration(minutes: 2));
  }

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    calls.add('applySettings');
    applied = settings;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    seeks.add(position);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Widget buildView() => Text('player:${kernel.id}');

  @override
  Future<void> dispose() async {
    disposals++;
    log.add('player.dispose');
    _snapshot.dispose();
  }

  void setPosition(Duration position, {bool playing = false}) {
    _snapshot.value = PlayerSnapshot(
      position: position,
      duration: const Duration(minutes: 2),
      playing: playing,
    );
  }
}
