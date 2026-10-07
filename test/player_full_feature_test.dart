import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/player_settings_sheet.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

/// 播放器全套功能对齐（真机反馈的第 5 项）：能力矩阵、按内核分别记住、
/// 统一控制面板、清晰度切换、统一提示。
///
/// 这一份把「界面层的契约」钉住：控件**不随内核变化显隐**、不支持的项点了弹统一
/// 提示、倍速 / 画面 / 字幕按内核分别记住、清晰度只在图源给了多线路时弹菜单。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_player_full');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    await SectionScope.open(Section.video);
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  setUp(() => PlayerFactory.clearMpvInitFailure());

  /// 三套内核各一份能力矩阵（**唯一声明处**）。
  group('能力矩阵：控件不随内核显隐，差异只在提示', () {
    test('每一项都有明确归属：AVPlayer / MPV / MDK', () {
      final avplayer = PlayerCapabilities.of(PlayerKernel.avplayer);
      final mpv = PlayerCapabilities.of(PlayerKernel.mpv);
      final mdk = PlayerCapabilities.of(PlayerKernel.mdk);

      // 音轨：三套都能（avfoundation 明确支持音频轨选择）。
      expect(avplayer.audioTracks, isTrue);
      expect(mpv.audioTracks, isTrue);
      expect(mdk.audioTracks, isTrue);

      // 字幕样式：只有 MPV（Flutter 字幕层）；AVPlayer 按系统样式、MDK 内嵌渲染。
      expect(mpv.subtitleStyle, isTrue);
      expect(avplayer.subtitleStyle, isFalse);
      expect(mdk.subtitleStyle, isFalse);

      // 外挂字幕：MPV / MDK 有通路，AVPlayer 没有。
      expect(mpv.externalSubtitle, isTrue);
      expect(mdk.externalSubtitle, isTrue);
      expect(avplayer.externalSubtitle, isFalse);

      // 延迟与硬解：只有 MPV 两项俱全（libmpv 属性通道）。
      expect(mpv.subtitleDelay, isTrue);
      expect(mpv.audioDelay, isTrue);
      expect(mpv.hardwareDecoding, isTrue);
      expect(avplayer.audioDelay, isFalse);
      expect(mdk.audioDelay, isFalse);
      expect(mdk.hardwareDecoding, isFalse);
      expect(mdk.subtitleDelay, isTrue);

      // 后台音频 / 锁屏控制 / 缓冲参数：走宿主原生通道，与内核无关。
      for (final caps in <PlayerCapabilities>[avplayer, mpv, mdk]) {
        expect(caps.backgroundAudio, isTrue);
        expect(caps.nowPlaying, isTrue);
      }
      expect(avplayer.bufferingParams, isTrue);
      expect(mpv.bufferingParams, isTrue);
      expect(mdk.bufferingParams, isFalse);
    });

    test('统一提示文案（用户点名的口径）', () {
      expect(
        PlayerCapabilities.unsupportedMessage,
        '当前播放器内核不支持该功能，请切换其它播放器',
      );
    });

    test('替身播放器默认「什么都不支持」：能力必须显式声明', () {
      final player = _FakePlayer();
      expect(player.capabilities, PlayerCapabilities.none);
    });
  });

  group('按内核分别记住（倍速 / 画面 / 字幕）', () {
    test('切内核读的是那个内核自己的值', () {
      var settings = const PlayerSettings();
      // AVPlayer：1.5x 速 + 旋转 90
      settings = settings.copyWith(speed: 1.5, rotation: RotationMode.cw90);
      expect(settings.speed, 1.5);
      expect(settings.rotation, RotationMode.cw90);

      // 切到 MPV：拿到的是 MPV 自己的默认值，不是 AVPlayer 调好的
      settings = settings.copyWith(kernel: PlayerKernel.mpv);
      expect(settings.speed, PlayerSettings.defaultSpeed);
      expect(settings.rotation, RotationMode.none);

      // 在 MPV 上调 2.0x + 填充
      settings = settings.copyWith(speed: 2.0, zoom: ZoomMode.fill);
      expect(settings.speed, 2.0);

      // 切回 AVPlayer：1.5x 与旋转 90 还在
      settings = settings.copyWith(kernel: PlayerKernel.avplayer);
      expect(settings.speed, 1.5, reason: 'AVPlayer 的倍速按内核记住');
      expect(settings.rotation, RotationMode.cw90);
      expect(settings.zoom, ZoomMode.fit);

      // MPV 那份也没丢
      settings = settings.copyWith(kernel: PlayerKernel.mpv);
      expect(settings.speed, 2.0);
      expect(settings.zoom, ZoomMode.fill);
    });

    test('倍速档位：0.25~4.0、步长 0.25', () {
      expect(PlayerSettings.minSpeed, 0.25);
      expect(PlayerSettings.maxSpeed, 4.0);
      expect(PlayerSettings.speeds.first, 0.25);
      expect(PlayerSettings.speeds.last, 4.0);
      for (var index = 1; index < PlayerSettings.speeds.length; index++) {
        expect(
          PlayerSettings.speeds[index] - PlayerSettings.speeds[index - 1],
          closeTo(0.25, 1e-9),
          reason: '相邻档位差 0.25',
        );
      }
    });

    test('倍速归一：非档位值落到最近档位', () {
      expect(PlayerSettings.normalizeSpeed(0.3), 0.25);
      expect(PlayerSettings.normalizeSpeed(1.6), 1.5);
      expect(PlayerSettings.normalizeSpeed(3.9), 4.0);
      expect(PlayerSettings.normalizeSpeed(9), 4.0);
      expect(PlayerSettings.normalizeSpeed(double.nan), 1.0);
    });

    test('字幕底色归一：夹到 0..1 并归到 0.05', () {
      expect(KernelPrefs.normalizeSubtitleBackground(0.42), 0.4);
      expect(KernelPrefs.normalizeSubtitleBackground(-1), 0.0);
      expect(KernelPrefs.normalizeSubtitleBackground(3), 1.0);
      expect(
        KernelPrefs.normalizeSubtitleBackground(double.nan),
        KernelPrefs.defaultSubtitleBackground,
      );
    });

    test('偏好 JSON 往返：坏值只影响那一项', () {
      const prefs = KernelPrefs(
        speed: 1.25,
        zoom: ZoomMode.scale125,
        rotation: RotationMode.cw270,
        mirrored: true,
        subtitleSize: SubtitleSize.large,
        subtitleColor: SubtitleColor.yellow,
        subtitleOutline: SubtitleOutline.thick,
        subtitleBackground: 0.8,
        subtitleDelay: Duration(milliseconds: -1500),
        audioDelay: Duration(milliseconds: 500),
      );
      expect(KernelPrefs.fromJson(prefs.toJson()), prefs);

      final broken = KernelPrefs.fromJson(<String, Object?>{
        'speed': 'not-a-number',
        'zoom': 'nope',
        'rotation': 90,
        'mirrored': true,
        'subtitleDelayMs': 999999,
      });
      expect(broken.speed, PlayerSettings.defaultSpeed);
      expect(broken.zoom, ZoomMode.fit);
      expect(broken.rotation, RotationMode.cw90, reason: '角度也能反查');
      expect(broken.mirrored, isTrue);
      expect(broken.subtitleDelay, const Duration(seconds: 10), reason: '越界夹回');
    });
  });

  group('设置持久化：每内核一格 + 老库迁移', () {
    test('写库后按内核各读各的', () async {
      final store = await VideoPlayerSettingsStore.open();
      var settings = const PlayerSettings()
          .copyWith(kernel: PlayerKernel.avplayer, speed: 1.5);
      settings = settings.copyWith(kernel: PlayerKernel.mpv, speed: 2.0);
      store.save(settings);

      final reloaded = store.load();
      expect(reloaded.kernel, PlayerKernel.mpv);
      expect(
        reloaded.speed,
        2.0,
        reason: 'MPV 那一格是自己存进去的',
      );
      expect(
        reloaded.copyWith(kernel: PlayerKernel.avplayer).speed,
        1.5,
        reason: 'AVPlayer 那一格也在（上次保存时的值）',
      );
    });

    test('老库（只有全局键）能读出来并迁给当前内核', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting(VideoPlayerSettingsStore.keyKernel, 'avplayer');
      library.setSetting(VideoPlayerSettingsStore.keySpeed, '1.75');
      library.setSetting(VideoPlayerSettingsStore.keySubtitleSize, 'large');
      library.setSetting(
        VideoPlayerSettingsStore.keySubtitleDelay,
        '-2000',
      );

      final store = VideoPlayerSettingsStore(library);
      final loaded = store.load();
      expect(loaded.kernel, PlayerKernel.avplayer);
      expect(loaded.speed, 1.75, reason: '老键里的倍速迁过来');
      expect(loaded.subtitleSize, SubtitleSize.large);
      expect(loaded.subtitleDelay, const Duration(seconds: -2));

      // 迁移后写一次：老键仍镜像（回退到旧版本也读得懂）。
      store.save(loaded);
      expect(library.setting(VideoPlayerSettingsStore.keySpeed), '1.75');
      expect(
        library.setting(VideoPlayerSettingsStore.keyPrefsFor(PlayerKernel.avplayer)),
        isNotNull,
      );
    });
  });

  group('控制面板与设置弹窗', () {
    Future<List<_FakePlayer>> pump(
      WidgetTester tester, {
      PlayerKernelCatalog? catalog,
      List<VideoQuality> qualities = const <VideoQuality>[],
      _FakePlayer? player,
    }) async {
      final created = <_FakePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
            qualities: qualities,
            catalog: catalog ?? const _AllKernelsCatalog(),
            playerFactory: (kernel) {
              final created_ = player ?? _FakePlayer(kernel: kernel);
              created.add(created_);
              return created_;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return created;
    }

    testWidgets('控制栏齐全：前进 / 后退 10 秒、清晰度、全屏、设置都在', (tester) async {
      await pump(tester);

      expect(find.byTooltip('前进 10 秒'), findsOneWidget);
      expect(find.byTooltip('后退 10 秒'), findsOneWidget);
      expect(find.byTooltip('清晰度'), findsOneWidget);
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(find.byTooltip('播放这个地址'), findsOneWidget, reason: '手动地址入口');
    });

    testWidgets('单线路：点清晰度弹提示，不弹菜单（按钮仍在）', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('清晰度'));
      await tester.pumpAndSettle();

      expect(find.text('当前图源不提供多清晰度选项'), findsOneWidget);
    });

    testWidgets('多线路：弹菜单，选中后换地址重载并提示', (tester) async {
      final players = await pump(
        tester,
        qualities: <VideoQuality>[
          VideoQuality(label: '1080P', url: Uri.parse('https://example.com/1080.mp4')),
          VideoQuality(label: '720P', url: Uri.parse('https://example.com/720.mp4')),
        ],
      );
      expect(players.single.media?.uri.toString(), 'https://example.com/a.mp4');

      await tester.tap(find.byTooltip('清晰度'));
      await tester.pumpAndSettle();
      expect(find.text('1080P'), findsOneWidget);
      expect(find.text('720P'), findsOneWidget);

      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();

      expect(players.single.media?.uri.toString(), 'https://example.com/720.mp4');
      expect(find.textContaining('已切换到 720P'), findsOneWidget);
    });

    testWidgets('设置弹窗：不支持的字幕样式项照旧显示，点了弹统一提示', (tester) async {
      // AVPlayer：字幕样式不支持（能力矩阵里为 false）。
      await pump(tester, catalog: const _AvPlayerOnlyCatalog());
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();

      // 控件都在（不因内核而消失）。面板可滚动，先滚到字幕那一段。
      await tester.dragUntilVisible(
        find.text('字号'),
        find.byType(PlayerSettingsSheet),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(find.text('字号'), findsOneWidget);
      expect(find.text('大'), findsOneWidget);

      // 点一个不支持的项：弹统一提示。
      // 这颗芯片被 IgnorePointer 包着（有意：它不该接受触摸，触摸要落到外层
      // 的提示手势上），因此这里关掉「必须命中指定控件」的告警。
      await tester.tap(find.text('大'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text(PlayerCapabilities.unsupportedMessage), findsOneWidget);
    });

    testWidgets('设置弹窗：切内核后倍速显示那个内核自己的值', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();

      // AVPlayer 上调 1.5x。
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(find.text('1.5x'), findsWidgets);

      // 切到 MPV：显示的是 MPV 自己的 1x（按内核分别记住）。
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      // 倍速滑杆在弹窗里（控制栏的进度条也是 Slider，因此先限定在弹窗内）。
      final slider = tester.widget<Slider>(
        find
            .descendant(
              of: find.byType(PlayerSettingsSheet),
              matching: find.byType(Slider),
            )
            .first,
      );
      expect(
        slider.value,
        1.0,
        reason: 'MPV 的倍速是它自己记住的那一份，不继承 AVPlayer 的 1.5x',
      );
    });

    testWidgets('设置弹窗里有弹幕区（与弹幕设置弹窗同一份控件）', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('弹幕'),
        find.byType(PlayerSettingsSheet),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(find.text('弹幕'), findsOneWidget);
      // 面板内的控件（标题已由外层 section 给，面板不重复标题）。
      expect(find.text('显示弹幕'), findsOneWidget);
      expect(find.text('不透明度'), findsOneWidget);
      expect(find.text('恢复默认'), findsOneWidget);

      // 改一项：立即生效（面板自持状态）。
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(find.text('不透明度'), findsOneWidget);
    });

    testWidgets('全屏：收起控制栏与顶栏，点画面唤回', (tester) async {
      await pump(tester);
      expect(find.text('视频地址或本地路径'), findsOneWidget);

      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsWidgets);
      expect(find.text('视频地址或本地路径'), findsNothing, reason: '全屏收起标准控制栏');

      // 退出全屏回到常规布局。
      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pumpAndSettle();
      expect(find.text('视频地址或本地路径'), findsOneWidget);
    });

    testWidgets('锁屏：收起控制栏，只剩解锁按钮；再点回来', (tester) async {
      await pump(tester);
      expect(find.byTooltip('锁定（防误触）'), findsOneWidget);

      await tester.tap(find.byTooltip('锁定（防误触）'));
      await tester.pumpAndSettle();
      expect(find.text('视频地址或本地路径'), findsNothing, reason: '锁定时控制全收起');
      expect(find.byTooltip('解除锁定'), findsOneWidget);

      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pumpAndSettle();
      expect(find.text('视频地址或本地路径'), findsOneWidget);
    });

    testWidgets('进度条拖动：显示预览，松手才 seek', (tester) async {
      final players = await pump(tester);
      players.single.emit(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();

      final slider = find.byType(Slider).first;
      final box = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(box.left + box.width * 0.5, box.center.dy),
      );
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(find.textContaining('拖动到'), findsOneWidget);
      expect(players.single.seeks, isEmpty, reason: '拖动中不反复 seek');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(players.single.seeks, isNotEmpty, reason: '松手才 seek');
      expect(find.textContaining('拖动到'), findsNothing);
    });

    testWidgets('前进 10 秒：按当前位次跳转', (tester) async {
      final players = await pump(tester);
      players.single.emit(
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('前进 10 秒'));
      await tester.pumpAndSettle();
      expect(players.single.seeks.last, const Duration(seconds: 40));

      // 替身不会自己走表：手动把它推到刚 seek 的位置，再验后退。
      players.single.emit(
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('后退 10 秒'));
      await tester.pumpAndSettle();
      expect(players.single.seeks.last, const Duration(seconds: 30));

      // 越界夹到 0。
      players.single.emit(
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('后退 10 秒'));
      await tester.pumpAndSettle();
      expect(players.single.seeks.last, Duration.zero);
    });
  });
}

/// 三套内核都可用。
class _AllKernelsCatalog implements PlayerKernelCatalog {
  const _AllKernelsCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => true;

  @override
  String? unavailableReason(PlayerKernel kernel) => null;
}

/// 只有 AVPlayer 可用（用于验「不支持的字幕样式项」）。
class _AvPlayerOnlyCatalog implements PlayerKernelCatalog {
  const _AvPlayerOnlyCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => kernel == PlayerKernel.avplayer;

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}

/// 替身播放器：只记命令，能力矩阵用默认（全不支持）。
class _FakePlayer extends AbstractPlayer {
  _FakePlayer({this.kernel});

  final PlayerKernel? kernel;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: 'fake'),
  );

  PlayerMedia? media;
  final List<Duration> seeks = <Duration>[];

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  void emit({Duration? position, Duration? duration, bool? playing, String? error}) {
    _snapshot.value = PlayerSnapshot(
      position: position ?? _snapshot.value.position,
      duration: duration ?? _snapshot.value.duration,
      playing: playing ?? _snapshot.value.playing,
      error: error,
    );
  }

  @override
  Future<void> load(PlayerMedia media) async {
    this.media = media;
  }

  @override
  Future<void> play() async => emit(playing: true);

  @override
  Future<void> pause() async => emit(playing: false);

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> stop() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => const Text('fake-view');

  @override
  Future<void> dispose() async {}
}
