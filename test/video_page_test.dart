import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/brightness.dart';
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

import 'support/fake_source_manager.dart';

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

    /// 切到「播放」页签：首页是图源展示页（浏览），播放器在同板块的第二个页签。
    Future<void> openPlayerTab(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(Tab, '播放'));
      await tester.pumpAndSettle();
    }

    Future<List<_FakePlayer>> pumpVideo(
      WidgetTester tester, {
      required Set<PlayerKernel> available,
      _FakePipBackend? pip,
      _FakeBrightnessBackend? brightness,
      bool withSourceManager = false,
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
            brightnessBackend: brightness ?? _FakeBrightnessBackend(),
            // 首页是图源展示页：默认注入空图源管理器（不碰真实板块库），
            // 交给正版实现时才走真库。
            sourceManager: withSourceManager ? null : FakeSourceManager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openPlayerTab(tester);
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
            sourceManager: FakeSourceManager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, '播放'));
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

    testWidgets('手势：右半屏上下滑改音量并下发给内核', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      // 起点在右半边 → 音量。音量初值就是 1.0（最大），因此向下滑才看得出变化。
      await _dragInSteps(
        tester,
        from: Offset(layer.right - 40, layer.center.dy),
        total: Offset(0, layer.height / 4),
      );

      expect(created.single.volumes, isNotEmpty, reason: '音量手势必须真的下发给内核');
      expect(
        created.single.volumes.last,
        closeTo(0.75, 0.06),
        reason: '下滑 1/4 屏 → 1.0 − 0.25',
      );
    });

    testWidgets('手势：音量滑过头也不会越界（钳在 0..1）', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      await _dragInSteps(
        tester,
        from: Offset(layer.right - 40, layer.center.dy),
        total: Offset(0, layer.height * 1.5),
      );

      expect(created.single.volumes, isNotEmpty);
      for (final volume in created.single.volumes) {
        expect(volume, inInclusiveRange(0.0, 1.0), reason: '音量越界会炸内核');
      }
      expect(created.single.volumes.last, 0.0, reason: '滑到底就是静音');
    });

    testWidgets('手势：左半屏上下滑只改亮度，不动音量', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      await _dragInSteps(
        tester,
        from: Offset(layer.left + 40, layer.center.dy),
        total: Offset(0, -layer.height / 4),
      );

      expect(created.single.volumes, isEmpty, reason: '左半边是亮度，不该碰音量');
      expect(find.textContaining('亮度'), findsNothing, reason: '松手后提示浮层收起');
    });

    testWidgets('手势：水平拖在松手时才 seek（拖动中不反复 seek）', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);
      created.single.seeks.clear();

      final layer = _gestureLayerRect(tester);
      final gesture = await tester.startGesture(layer.center);
      await tester.pump(const Duration(milliseconds: 16));
      // 分多步移动：真实触摸本来就是一串 move 事件，单步大跳会先被
      // 识别器的 slop 吃掉，测不出真实行为。
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(Offset(layer.width / 8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(created.single.seeks, isEmpty, reason: '拖动中只更新预览，不 seek');

      await gesture.up();
      await tester.pumpAndSettle();

      expect(created.single.seeks, hasLength(1));
      // 整屏宽对应 90 秒窗口。
      final expected = 90 * layer.width / 2 / layer.width;
      expect(
        created.single.seeks.single.inSeconds.toDouble(),
        closeTo(expected, 3.0),
        reason: '滑半屏 ≈ 45 秒',
      );
    });

    testWidgets('手势：调暗后画面上真的盖了遮罩（亮度要看得见）', (tester) async {
      await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      ColoredBox? overlay() {
        final found = find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.color.a > 0 &&
              widget.color.a < 1 &&
              widget.color.r == 0 &&
              widget.color.g == 0 &&
              widget.color.b == 0,
        );
        return found.evaluate().isEmpty ? null : found.evaluate().first.widget as ColoredBox;
      }

      expect(overlay(), isNull, reason: '默认亮度不该有遮罩');

      final layer = _gestureLayerRect(tester);
      await _dragInSteps(
        tester,
        from: Offset(layer.left + 40, layer.center.dy),
        total: Offset(0, layer.height / 2),
      );

      final mask = overlay();
      expect(mask, isNotNull, reason: '下滑半屏后必须出现变暗遮罩');
      expect(mask!.color.a, greaterThan(0.2));
    });

    testWidgets('亮度：支持系统亮度时改系统值，不再叠遮罩', (tester) async {
      final brightness = _FakeBrightnessBackend()..supported = true;
      brightness.current = 0.6;
      await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
        brightness: brightness,
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      // 起点在左半边 → 亮度。下滑变暗。
      await _dragInSteps(
        tester,
        from: Offset(layer.left + 40, layer.center.dy),
        total: Offset(0, layer.height / 5),
      );

      expect(brightness.applied, isNotEmpty, reason: '应改系统亮度');
      expect(
        brightness.applied.last,
        closeTo(0.4, 0.08),
        reason: '从 0.6 下滑 1/5 屏 → 约 0.4',
      );
      expect(
        _brightnessMask(tester),
        isNull,
        reason: '系统亮度生效时不该再叠遮罩（否则暗两次）',
      );
    });

    testWidgets('亮度：不支持系统亮度时回退为遮罩（画面确实变暗）', (tester) async {
      final brightness = _FakeBrightnessBackend()..supported = false;
      await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
        brightness: brightness,
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      await _dragInSteps(
        tester,
        from: Offset(layer.left + 40, layer.center.dy),
        total: Offset(0, layer.height / 2),
      );

      expect(brightness.applied, isEmpty, reason: '不支持时不该调用后端');
      expect(_brightnessMask(tester), isNotNull, reason: '降级路径要看得见变暗');
    });

    testWidgets('亮度：进页面时对齐当前系统亮度（不跳变）', (tester) async {
      final brightness = _FakeBrightnessBackend()..supported = true;
      brightness.current = 0.35;
      await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
        brightness: brightness,
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      // 只下滑一点点：若起点没对齐到 0.35，结果会明显偏离。
      await _dragInSteps(
        tester,
        from: Offset(layer.left + 40, layer.center.dy),
        total: Offset(0, layer.height / 20),
      );

      expect(
        brightness.applied.last,
        closeTo(0.30, 0.06),
        reason: '起点应是 0.35 而不是 1.0（否则会跳到别的值）',
      );
    });

    testWidgets('长按临时倍速，松手恢复原倍速', (tester) async {
      final created = await pumpVideo(
        tester,
        available: <PlayerKernel>{PlayerKernel.avplayer},
      );
      await openMedia(tester);

      final layer = _gestureLayerRect(tester);
      final gesture = await tester.startGesture(layer.center);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(created.single.applied?.speed, 2.0, reason: '长按在 1.0x 基础上翻倍');
      expect(find.textContaining('快进'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(created.single.applied?.speed, 1.0, reason: '松手恢复用户设置倍速');
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
            catalog: _FakeCatalog(const <PlayerKernel>{PlayerKernel.avplayer}),
            playerFactory: (kernel) {
              created++;
              return _FakePlayer(kernel, <String>[]);
            },
            pipBackend: _FakePipBackend(),
            sourceManager: FakeSourceManager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, '播放'));
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
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPage(sourceManager: FakeSourceManager()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, '播放'));
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

/// 手势层覆盖的画面区域（用于按比例计算拖拽位移）。
///
/// 手势层是 Positioned.fill 盖在播放区上的 GestureDetector，带 GlobalKey，
/// 因此直接取它的矩形——它就是手势的真实有效范围（含视频黑边）。
Rect _gestureLayerRect(WidgetTester tester) {
  final detector = find.byWidgetPredicate(
    (widget) => widget is GestureDetector && widget.onPanDown != null,
  );
  return tester.getRect(detector.first);
}

/// 分多步完成一次拖拽。
///
/// 必须分步：拖拽识别器要先跨过 slop 才成立，成立的那一帧之前的位移不会
/// 作为 update 回调出来；单步大跳会让手势「像没生效」。
Future<void> _dragInSteps(
  WidgetTester tester, {
  required Offset from,
  required Offset total,
  int steps = 8,
}) async {
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 16));
  final step = Offset(total.dx / steps, total.dy / steps);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 取当前的亮度遮罩（没有则返回 null）。
///
/// 遮罩是「纯黑 + 半透明」的 ColoredBox；用这个特征把它从其他装饰里认出来。
Color? _brightnessMask(WidgetTester tester) {
  final found = find.byWidgetPredicate(
    (widget) =>
        widget is ColoredBox &&
        widget.color.a > 0 &&
        widget.color.a < 1 &&
        widget.color.r == 0 &&
        widget.color.g == 0 &&
        widget.color.b == 0,
  );
  if (found.evaluate().isEmpty) return null;
  return (found.evaluate().first.widget as ColoredBox).color;
}

/// 替身亮度后端：记录下发的亮度值。
class _FakeBrightnessBackend implements BrightnessBackend {
  bool supported = false;
  double? current;
  final List<double> applied = <double>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> setBrightness(double value) async => applied.add(value);

  @override
  Future<double?> currentBrightness() async => current;
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
  final List<double> volumes = <double>[];

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
  Future<void> setVolume(double volume) async => volumes.add(volume);

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
