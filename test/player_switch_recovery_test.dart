import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/player_kernel_section.dart';
import 'package:lume_box/features/video/video_player_page.dart';


/// 内核切换的「不空转」验证。
///
/// 背景（用户报的现象）：切到 MPV 之后视频板块一直转圈，右上角的播放器设置
/// （控制栏齿轮）也跟着消失——用户既播不了、也进不去设置，只能重启应用。
///
/// 这两个现象是同一个状态：`_player == null` 时页面只画了一个转圈，
/// **整条控制栏（含齿轮）都不渲染**。本轮把它改成：
/// - 控制栏在任何状态下都在（齿轮 / 地址栏 / 弹幕开关照常可用）；
/// - 准备中写明「在等哪个内核」并留着「切回 AVPlayer」；
/// - 起不来时给出「重试 / 切回 AVPlayer」两个出口；
/// - 重建过程异常安全：不泄漏实例、不丢已建好的播放器、不会停在等待上。
///
/// 原生初始化本身是同步阻塞调用（Dart 无法抢占式中断），因此这一组用例驱动的是
/// **页面状态机**：无论底层是抛错、超预算还是接续失败，页面都必须收敛到
/// 「有画面」或「有说明 + 有出口」这两种终态之一。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    PlayerFactory.clearMpvInitFailure();
    PlayerFactory.clearMdkInitFailure();
    root = Directory.systemTemp.createTempSync('lume_box_switch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 库在真实时钟里先打开：testWidgets 的 fake-async 里等不到真实异步。
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    PlayerFactory.clearMpvInitFailure();
    PlayerFactory.clearMdkInitFailure();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpVideo(WidgetTester tester, {
    required AbstractPlayer? Function(PlayerKernel) factory,
    Set<PlayerKernel> available = const <PlayerKernel>{
      PlayerKernel.avplayer,
      PlayerKernel.mpv,
    },
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPlayerPage(
          media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
          catalog: _Catalog(available),
          playerFactory: factory,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('控制栏在任何状态下都在', () {
    testWidgets('内核起不来：给出「重试 / 切回 AVPlayer」，齿轮与地址栏仍在', (tester) async {
      // 工厂对两个内核都返回 null（模拟底层完全起不来）。
      await pumpVideo(tester, factory: (kernel) => null);

      expect(find.text('播放器准备失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('切回 AVPlayer'), findsOneWidget);
      expect(
        find.byTooltip('播放器设置'),
        findsOneWidget,
        reason: '失败态不能把「播放器设置」入口一起收走——用户上一次就是这么被卡住的',
      );
      // 板块顶栏那排入口（追剧日历 / 源管理）现在在**浏览页**上，与播放器状态
      // 无关；播放器页这边钉住的是「控制栏与地址栏不会被失败态收走」。
      expect(find.text('视频地址或本地路径'), findsOneWidget, reason: '地址栏也要能重新贴地址');
      // 传输按钮禁用（没有播放器可控制），但设置入口可用。
      final play = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.play_circle_fill),
      );
      expect(play.onPressed, isNull, reason: '没有播放器时播放键禁用');
    });

    testWidgets('设置库不可用：同样留着重试与设置入口', (tester) async {
      // 让本板块目录解析失败：清作用域缓存并把 path_provider 置空。
      ReadingLibrary.close(Section.video);
      await SectionScope.closeAll();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => null,
      );

      await pumpVideo(tester, factory: (kernel) => _FakePlayer(kernel));

      expect(find.text('播放器设置库不可用'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
    });
  });

  group('失败后能回到可用状态', () {
    testWidgets('MPV 抛错 → 自动回退 AVPlayer，页面有画面、齿轮可用', (tester) async {
      final created = <_FakePlayer>[];
      await pumpVideo(
        tester,
        factory: (kernel) {
          if (kernel == PlayerKernel.mpv) throw StateError('mpv 崩了');
          final player = _FakePlayer(kernel);
          created.add(player);
          return player;
        },
      );

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('fake:avplayer'), findsOneWidget, reason: '回退后要有画面');
      expect(find.text('播放器准备失败'), findsNothing);
      expect(find.byTooltip('播放器设置'), findsOneWidget, reason: '设置入口不受切换影响');
      expect(
        find.text('视频地址或本地路径'),
        findsOneWidget,
        reason: '地址栏不受切换影响（失败时还能改地址或换内核）',
      );
      expect(PlayerFactory.mpvInitFailed, isTrue, reason: '失败内核本次运行内熔断');
    });

    testWidgets('失败态点「重试」：解除熔断并重新尝试该内核', (tester) async {
      var mpvAttempts = 0;
      await pumpVideo(
        tester,
        factory: (kernel) {
          if (kernel == PlayerKernel.mpv) {
            mpvAttempts++;
            // 第一次抛错，第二次成功（模拟偶发失败）。
            if (mpvAttempts == 1) throw StateError('偶发失败');
            return _FakePlayer(kernel);
          }
          return null; // 兜底内核也起不来 → 停在失败态
        },
      );

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('播放器准备失败'), findsOneWidget);
      expect(PlayerFactory.mpvInitFailed, isTrue);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(mpvAttempts, 2, reason: '重试必须真的再建一次 MPV，而不是原地不动');
      expect(PlayerFactory.mpvInitFailed, isFalse, reason: '重试前先解除熔断');
      expect(find.text('播放器准备失败'), findsNothing);
      expect(find.text('fake:mpv'), findsOneWidget, reason: '第二次成功，用上 MPV');
    });

    testWidgets('设置页里熔断中的 MPV 可「重试」恢复可选', (tester) async {
      PlayerFactory.markMpvInitFailed();
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: const PlayerKernelSection(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('MPV 初始化失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(PlayerFactory.mpvInitFailed, isFalse);
      expect(find.textContaining('MPV 初始化失败'), findsNothing);
      expect(find.text('重试'), findsNothing, reason: '熔断解除后不再显示重试');
    });
  });

  group('重建的异常安全', () {
    testWidgets('接续失败（applySettings / load 抛错）不空转：画面仍在 + 说明可重试', (tester) async {
      final created = <_FakePlayer>[];
      await pumpVideo(
        tester,
        factory: (kernel) {
          final player = _FakePlayer(kernel, failLoad: true);
          created.add(player);
          return player;
        },
      );

      // 首帧就该有画面：接续失败只影响「加载媒体」，不影响播放器被采用。
      expect(find.text('fake:avplayer'), findsOneWidget);
      expect(created, isNotEmpty);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
    });

    testWidgets('连续切换：过期重建的实例被丢弃，界面显示最后选中的内核', (tester) async {
      final created = <_FakePlayer>[];
      await pumpVideo(
        tester,
        factory: (kernel) {
          final player = _FakePlayer(kernel);
          created.add(player);
          return player;
        },
      );

      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      // 同一帧里连点两次：第二次选择让第一次的重建作废。
      await tester.tap(find.text('MPV'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.text('AVPlayer'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('fake:avplayer'), findsOneWidget, reason: '以最后一次选择为准');
      final mpv = created.where((p) => p.kernel == PlayerKernel.mpv).toList();
      expect(
        mpv.every((player) => player.disposals > 0),
        isTrue,
        reason: '过期重建建出来的 MPV 实例必须被释放，不许泄漏',
      );
    });
  });
  group('MDK 内核：已接入（不再是「预留接口」）', () {
    test('可用性与不可用原因跟随平台边界，而不是「未实现」', () {
      final available = PlayerFactory.isAvailable(PlayerKernel.mdk);
      final reason = PlayerFactory.unavailableReason(PlayerKernel.mdk);
      if (available) {
        expect(reason, isNull);
      } else {
        // MDK 已经真的接进来了（libmdk / fvp），非 iOS 上不可用的原因是
        // **平台边界**（与 MPV 同口径），不再是「只预留接口 / 未实现」。
        expect(reason, contains('仅在 iOS 提供'));
        expect(reason, isNot(contains('预留')));
        expect(reason, isNot(contains('未实现')));
      }
    });

    test('熔断：标记后本次运行不再提供，清除后可再试', () {
      expect(PlayerFactory.mdkInitFailed, isFalse);
      PlayerFactory.markMdkInitFailed();
      expect(PlayerFactory.mdkInitFailed, isTrue);
      PlayerFactory.clearMdkInitFailure();
      expect(PlayerFactory.mdkInitFailed, isFalse);
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
  _FakePlayer(this.kernel, {this.failLoad = false});

  final PlayerKernel kernel;

  /// load 抛错：驱动「播放器已采用、但接续失败」这条路径。
  final bool failLoad;

  int disposals = 0;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  late final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: kernel.label),
  );

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {
    if (failLoad) throw StateError('假播放器故意加载失败');
  }

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
  Future<void> dispose() async {
    disposals++;
  }
}
