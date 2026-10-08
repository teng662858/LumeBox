import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/playback_orientation.dart';
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
import 'package:lume_box/features/video/player_source_sheet.dart';
import 'package:lume_box/features/video/player_speed_meter.dart';
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

  // 方向偏好是应用级单例：每条用例从「自动」起步，免得相互串。
  setUp(PlaybackOrientationController.instance.resetForTesting);
  tearDown(PlaybackOrientationController.instance.resetForTesting);

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
      PlaybackSpeedMeter? speedMeter,
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
            speedMeter: speedMeter,
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

    testWidgets('控制栏齐全：前进 / 后退 10 秒、清晰度、全屏、设置、播放源都在', (tester) async {
      await pump(tester);

      expect(find.byTooltip('前进 10 秒'), findsOneWidget);
      expect(find.byTooltip('后退 10 秒'), findsOneWidget);
      expect(find.byTooltip('清晰度'), findsOneWidget);
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      // 用户要求：长播放链接不再铺在控制栏上，改成右侧的小信息图标（弹窗里看 / 换）。
      expect(find.byTooltip('播放源'), findsOneWidget, reason: '播放源入口（地址与线路）');
      expect(find.byType(TextField), findsNothing, reason: '控制栏不再直接展示长链接');
    });

    testWidgets('进度条右下两个文字入口：播放器 / 字幕（用户点名）', (tester) async {
      await pump(tester);

      // 两个入口是**文字按钮**（不是又两颗图标），文案就是那两个字。
      // 两套布局（全屏浮层右下角 / 常规面板右排）共用同一份入口，因此至少一颗；
      // 屏幕小的档位另一套会收起，不在这里断言具体数量。
      expect(
        find.byTooltip('播放器设置（内核 / 画面 / 手势 / 控制栏）'),
        findsWidgets,
        reason: '「播放器」文字入口',
      );
      expect(
        find.byTooltip('字幕设置（开关 / 字号 / 颜色 / 描边 / 阴影 / 垂直偏移 / 延迟）'),
        findsWidgets,
        reason: '「字幕」文字入口',
      );
      expect(find.widgetWithText(TextButton, '播放器'), findsWidgets);
      expect(find.widgetWithText(TextButton, '字幕'), findsWidgets);

      // 点「字幕」要真的把设置面板打开（字幕段就在那个面板里）。
      await tester.tap(find.widgetWithText(TextButton, '字幕').first);
      await tester.pumpAndSettle();
      // 面板确实打开了（字幕段就在这个面板里，其内容由 player_settings_page_test
      // 与字幕三项的单测覆盖；这里只钉「文字入口点了有反应」）。
      expect(
        find.byType(BottomSheet),
        findsWidgets,
        reason: '点「字幕」要弹出设置面板',
      );
    });

    testWidgets('播放源弹窗：展示当前地址、复制、按线路切换、手动贴地址', (tester) async {
      final players = await pump(
        tester,
        qualities: <VideoQuality>[
          VideoQuality(label: '1080P', url: Uri.parse('https://example.com/1080.mp4')),
          VideoQuality(label: '720P', url: Uri.parse('https://example.com/720.mp4')),
        ],
      );

      await tester.tap(find.byTooltip('播放源'));
      await tester.pumpAndSettle();

      // 弹窗里能看到当前地址（可选中复制），并有复制按钮。
      expect(find.text('当前播放地址'), findsOneWidget);
      expect(
        find.text('https://example.com/a.mp4'),
        findsNWidgets(2),
        reason: '当前地址展示一处 + 手动地址框预填一处',
      );
      expect(find.byTooltip('复制地址'), findsOneWidget);

      // 线路列表（与「清晰度」按钮同一份数据）：点一条即换源并从当前位置继续。
      expect(find.text('线路（切换后从当前位置继续）'), findsOneWidget);
      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();
      expect(players.single.media?.uri.toString(), 'https://example.com/720.mp4');
      expect(find.textContaining('已切换到 720P'), findsOneWidget);
    });

    testWidgets('播放源弹窗：手动贴地址起播；地址无效就地报错不关面板', (tester) async {
      final players = await pump(tester);

      await tester.tap(find.byTooltip('播放源'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://example.com/manual.mp4',
      );
      await tester.tap(find.text('播放这个地址'));
      await tester.pumpAndSettle();

      expect(players.single.media?.uri.toString(), 'https://example.com/manual.mp4');
      expect(find.byType(PlayerSourceSheet), findsNothing, reason: '交出去了就关面板');

      // 空地址：就地报错，面板留在原地。
      await tester.tap(find.byTooltip('播放源'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('播放这个地址'));
      await tester.pumpAndSettle();
      expect(find.text('请先填写视频地址'), findsOneWidget);
      expect(find.byType(PlayerSourceSheet), findsOneWidget, reason: '出错不关面板');
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

    testWidgets('打开视频即自动播放（用户要求）', (tester) async {
      final players = await pump(tester);
      expect(
        players.single.plays,
        greaterThan(0),
        reason: '装载与续播定位之后要自动起播，不必再点一下播放键',
      );
      expect(find.byTooltip('暂停'), findsOneWidget, reason: '控制栏显示为「正在播放」');
    });

    testWidgets('信息行：分辨率 / 码率来自内核参数', (tester) async {
      final players = await pump(tester);
      players.single.pushStats(
        const PlayerStats(
          engineLabel: 'AVPlayer',
          width: 1920,
          height: 1080,
          videoBitrateKbps: 1800,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('分辨率 1920×1080'), findsOneWidget);
      expect(find.textContaining('码率 1.8Mbps'), findsOneWidget);
    });

    testWidgets('竖屏短剧：按视频原始比例居中渲染，两侧留黑边（不拉伸）', (tester) async {
      final players = await pump(tester);
      players.single.pushStats(
        const PlayerStats(engineLabel: 'AVPlayer', width: 1080, height: 1920),
      );
      await tester.pumpAndSettle();

      // 画面框的宽高比 = 视频原始比例（9:16），不是被拉伸去填满播放区。
      final box = tester.getSize(
        find
            .ancestor(of: find.text('fake-view'), matching: find.byType(SizedBox))
            .first,
      );
      expect(box.width / box.height, closeTo(1080 / 1920, 0.01));

      // 播放区（含两侧留边）是黑底：这就是用户要的「黑边」。
      final hasBlackBackdrop = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .any((widget) => widget.color == Colors.black);
      expect(hasBlackBackdrop, isTrue, reason: '多余位置留黑边（不再露出浅色页面底）');
    });

    testWidgets('底部控制区下移：上方留白拉大、底部留白收窄（用户要求）', (tester) async {
      final players = await pump(tester);
      players.single.pushStats(
        const PlayerStats(engineLabel: 'AVPlayer', width: 1080, height: 1920),
      );
      await tester.pumpAndSettle();

      final panel = tester.widget<Padding>(
        find.byKey(VideoPlayerPage.controlPanelKey),
      );
      final padding = panel.padding as EdgeInsets;
      expect(padding.top, VideoPlayerPage.controlTopGap);
      expect(padding.bottom, VideoPlayerPage.controlBottomGap);
      expect(
        VideoPlayerPage.controlTopGap,
        greaterThan(52),
        reason: '比原先「地址行(≈52) + 信息行」那段距离还大：进度条与画面的空白变大',
      );
      expect(
        VideoPlayerPage.controlBottomGap,
        lessThan(16),
        reason: '底部留白收窄 = 整块控制区（进度条 + 下面所有按钮）跟着往下挪',
      );

      // 顺序没变：信息行在上，进度条居中，按钮在下（只动垂直位置，不动结构）。
      final infoY = tester.getCenter(find.textContaining('分辨率 1080×1920')).dy;
      final sliderY = tester.getCenter(find.byType(Slider).first).dy;
      final buttonY = tester.getCenter(find.byTooltip('播放器设置')).dy;
      expect(infoY, lessThan(sliderY));
      expect(sliderY, lessThan(buttonY));
    });

    testWidgets('网速：点「测速」实测播放地址，读数显示在信息行', (tester) async {
      final client = _CountingClient(bytes: 256 * 1024);
      final meter = PlaybackSpeedMeter(
        http: LumeHttp(client: client, source: '测速'),
      );
      addTearDown(meter.dispose);
      await pump(tester, speedMeter: meter);

      // 起播自动测一次（同一地址不重复测）。
      expect(client.urls, hasLength(1), reason: '起播自动测一次');
      expect(
        client.headers.first['Range'],
        startsWith('bytes=0-'),
        reason: '用 Range 只取前一段，不把整片视频拉下来',
      );
      expect(meter.kbps.value, isNotNull, reason: '读数已经出来了');
      expect(find.textContaining('网速'), findsOneWidget, reason: '信息行显示实测网速');

      // 点一下强制重测。
      await tester.tap(find.byIcon(Icons.speed));
      await tester.pumpAndSettle();
      expect(client.urls, hasLength(2), reason: '点「网速」可强制重测');
      expect(find.textContaining('网速'), findsOneWidget);
    });

    testWidgets('全屏：收起控制栏与顶栏，点画面唤回', (tester) async {
      await pump(tester);
      expect(find.byKey(VideoPlayerPage.controlPanelKey), findsOneWidget);

      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsWidgets);
      expect(
        find.byKey(VideoPlayerPage.controlPanelKey),
        findsNothing,
        reason: '全屏收起标准控制栏（换成压在画面上的浮层）',
      );

      // 退出全屏回到常规布局。
      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pumpAndSettle();
      expect(find.byKey(VideoPlayerPage.controlPanelKey), findsOneWidget);
    });

    testWidgets('全屏：锁横屏；退出全屏：还原竖屏（用户要求）', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();

      final landscape = calls.lastWhere(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(
        landscape.arguments,
        containsAll(<String>['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']),
        reason: '进全屏自动横屏（左右都收）',
      );

      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pumpAndSettle();
      final portrait = calls.lastWhere(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(portrait.arguments, <String>['DeviceOrientation.portraitUp']);
    });

    testWidgets('全屏：竖屏短剧进竖屏全屏，横片进横屏全屏（用户要求）', (tester) async {
      final calls = _captureOrientations(tester);
      final players = await pump(tester);

      // 竖屏短剧（1080×1920）：全屏 = 竖屏。
      players.single.pushStats(
        const PlayerStats(engineLabel: 'AVPlayer', width: 1080, height: 1920),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(
        _lastOrientations(calls),
        <String>['DeviceOrientation.portraitUp'],
        reason: '竖屏短剧（宽 < 高）进全屏就是竖屏全屏',
      );

      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pumpAndSettle();

      // 横片（1920×1080）：全屏 = 横屏（两个方向都收）。
      players.single.pushStats(
        const PlayerStats(engineLabel: 'AVPlayer', width: 1920, height: 1080),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(
        _lastOrientations(calls),
        containsAll(<String>[
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
        reason: '普通横片照旧横屏全屏',
      );
    });

    testWidgets('方向锁定：强制横屏 / 强制竖屏覆盖自动判断（用户要求）', (tester) async {
      final calls = _captureOrientations(tester);
      PlaybackOrientationController.instance
          .apply(PlaybackOrientation.landscape);
      addTearDown(PlaybackOrientationController.instance.resetForTesting);

      final players = await pump(tester);
      // 竖屏短剧 + 强制横屏：仍然是横屏（锁定覆盖自动判断）。
      players.single.pushStats(
        const PlayerStats(engineLabel: 'AVPlayer', width: 1080, height: 1920),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(
        _lastOrientations(calls),
        containsAll(<String>[
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
      );

      // 改成强制竖屏：当场换回竖屏（不必退出全屏重进）。
      PlaybackOrientationController.instance
          .apply(PlaybackOrientation.portrait);
      await tester.pumpAndSettle();
      expect(_lastOrientations(calls), <String>['DeviceOrientation.portraitUp']);
    });

    testWidgets('锁屏：收起控制栏，只剩解锁按钮；再点回来', (tester) async {
      await pump(tester);
      expect(find.byTooltip('锁定（防误触）'), findsOneWidget);

      await tester.tap(find.byTooltip('锁定（防误触）'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(VideoPlayerPage.controlPanelKey),
        findsNothing,
        reason: '锁定时控制全收起',
      );
      expect(find.byTooltip('解除锁定'), findsOneWidget);

      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pumpAndSettle();
      expect(find.byKey(VideoPlayerPage.controlPanelKey), findsOneWidget);
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
  testWidgets('全屏浮层：进度条贴底、按钮分左下 / 右下两组（用户要求）', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();

    final slider = tester.getRect(find.byType(Slider).first);
    final stop = tester.getCenter(find.byTooltip('停止'));
    expect(slider.bottom, lessThan(stop.dy), reason: '进度条在按钮组上方');

    // 左下角一组：传输控制 + 媒体类；右下角一组：窗口与信息类。
    final leftMost = tester.getCenter(find.byTooltip('后退 10 秒')).dx;
    final leftDanmaku = tester.getCenter(find.byTooltip('弹幕设置')).dx;
    final rightSource = tester.getCenter(find.byTooltip('播放源')).dx;
    final rightSettings = tester.getCenter(find.byTooltip('播放器设置')).dx;
    expect(leftMost, lessThan(leftDanmaku), reason: '左组按顺序排开');
    expect(
      leftDanmaku,
      lessThan(rightSource),
      reason: '媒体类在左、信息类在右（不再全挤中间）',
    );
    expect(rightSource, lessThan(rightSettings));
    expect(rightSettings, greaterThan(450), reason: '右组落在屏幕右半边');
    expect(leftMost, lessThan(450), reason: '左组落在屏幕左半边');
  });

  testWidgets('全屏控制栏自动隐藏：播放中无操作 4 秒收起，点屏幕唤回', (tester) async {
    final players = await pump(tester);
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget, reason: '刚进全屏控制栏可见');

    players.single.emit(
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 10),
      playing: true,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(
      find.byType(Slider),
      findsNothing,
      reason: '无操作 4 秒后控制栏自动隐藏',
    );

    await tester.tap(find.byType(Scaffold).first);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget, reason: '点屏幕再显示');
  });

  testWidgets('关掉「自动隐藏控制栏」后：怎么放着都不收起', (tester) async {
    final players = await pump(tester);
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('播放器设置'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('自动隐藏控制栏'),
      find.byType(PlayerSettingsSheet),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(Row, '自动隐藏控制栏'),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    players.single.emit(
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 10),
      playing: true,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(
      find.byType(Slider),
      findsOneWidget,
      reason: '关掉自动隐藏后控制栏一直显示',
    );
  });
  testWidgets('画中画：非 MPV 内核点时先切到 MPV（否则按钮点了没反应）', (tester) async {
    final created = await pump(tester); // 默认 AVPlayer
    expect(created.single.kernel, PlayerKernel.avplayer);

    await tester.tap(find.byTooltip('播放器设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 直接点画中画按钮：应当给一句说明并切到 MPV（本机三内核都可用）。
    await tester.tap(find.byIcon(Icons.picture_in_picture_alt));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('画中画需要 MPV 内核'),
      findsOneWidget,
      reason: '要说明为什么要换内核，而不是静默切换',
    );
    expect(
      created.length,
      greaterThan(1),
      reason: '换内核会重建播放器（新实例是 MPV）',
    );
    expect(created.last.kernel, PlayerKernel.mpv);
  });

  });
}

/// 抓取平台方向调用：返回一个持续追加的调用列表（测试用）。
List<MethodCall> _captureOrientations(WidgetTester tester) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

/// 最近一次下发的方向（平台渠道收到的是字符串列表）。
List<String> _lastOrientations(List<MethodCall> calls) {
  final call = calls.lastWhere(
    (call) => call.method == 'SystemChrome.setPreferredOrientations',
  );
  return (call.arguments as List<Object?>).cast<String>();
}

/// 三套内核都可用。
class _AllKernelsCatalog implements PlayerKernelCatalog {  const _AllKernelsCatalog();

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
  int plays = 0;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  void pushStats(PlayerStats next) => _stats.value = next;

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
  Future<void> play() async {
    plays++;
    emit(playing: true);
  }

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

/// 假 HTTP 客户端：返回固定体积的响应，用于网速表计时（真实等待极短）。
class _CountingClient extends http.BaseClient {
  _CountingClient({required this.bytes});

  final int bytes;
  final List<String> urls = <String>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    urls.add(request.url.toString());
    headers.add(Map<String, String>.from(request.headers));
    // 让「耗时为 0」不会发生：真实网络里耗时不会为 0，这里补 5ms。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return http.StreamedResponse(
      Stream<List<int>>.value(List<int>.filled(bytes, 0)),
      206,
      headers: const <String, String>{'content-range': 'bytes 0-262143/99999999'},
    );
  }
}
