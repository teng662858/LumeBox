import 'package:lume_box/features/video/player_source_sheet.dart';

import 'support/fake_source_manager.dart';

import 'package:lume_box/core/intro/intro_models.dart';
import 'package:lume_box/core/intro/intro_store.dart';

import 'dart:async';
import 'dart:convert';

import 'package:lume_box/core/player/pip.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/playback_orientation.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_kernel_launcher.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_experience_store.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/player_settings_sheet.dart';
import 'package:lume_box/features/video/player_speed_meter.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/direct_video_source.dart';
import 'package:lume_box/features/video/video_player_settings.dart';
import 'package:lume_box/features/video/playback_source_validator.dart';
import 'package:lume_box/features/video/video_play_target.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_overlay.dart';

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
    await IntroStore.open();
  });

  tearDown(() async {
    await IntroStore.resetForTesting();
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

      // 外挂字幕：AVPlayer 的文字字幕层支持 SRT / VTT；MPV / MDK 走内核。
      expect(mpv.externalSubtitle, isTrue);
      expect(mdk.externalSubtitle, isTrue);
      expect(avplayer.externalSubtitle, isTrue);
      expect(avplayer.subtitleTracks, isTrue);

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
      expect(PlayerCapabilities.unsupportedMessage, '当前播放器内核不支持该功能，请切换其它播放器');
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
      var settings = const PlayerSettings().copyWith(
        kernel: PlayerKernel.avplayer,
        speed: 1.5,
      );
      settings = settings.copyWith(kernel: PlayerKernel.mpv, speed: 2.0);
      store.save(settings);

      final reloaded = store.load();
      expect(reloaded.kernel, PlayerKernel.mpv);
      expect(reloaded.speed, 2.0, reason: 'MPV 那一格是自己存进去的');
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
      library.setSetting(VideoPlayerSettingsStore.keySubtitleDelay, '-2000');

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
        library.setting(
          VideoPlayerSettingsStore.keyPrefsFor(PlayerKernel.avplayer),
        ),
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
      VideoPlayTarget? target,
      SourceManager? sourceManager,
      DataSource? source,
      PipBackend? pipBackend,
      PlaybackSourceValidator? validator,
      bool fullscreenOnly = false,
      PlayerPrelaunch? prelaunch,
    }) async {
      final created = <_FakePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            fullscreenOnly: fullscreenOnly,
            prelaunch: prelaunch,
            media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
            qualities: qualities,
            catalog: catalog ?? const _AllKernelsCatalog(),
            speedMeter: speedMeter,
            pipBackend: pipBackend,
            sourceValidator: validator,
            target: target,
            sourceManager: sourceManager,
            source: source,
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

    testWidgets('切集 load 抛错保留面板，恢复后可按原集序重试', (tester) async {
      final source = DirectVideoSource(
        id: 'episode-retry',
        name: '测试',
        title: '测试',
        uri: Uri.parse('https://example.com/one.mp4'),
        episodes: const [
          SourceChapter(id: 'one', title: '第1集'),
          SourceChapter(id: 'two', title: '第2集'),
        ],
        resolveEpisode: (_) async =>
            VideoContent(url: Uri.parse('https://example.com/two.mp4')),
      );
      final player = _FakePlayer(kernel: PlayerKernel.avplayer);
      await pump(
        tester,
        player: player,
        source: source,
        target: const VideoPlayTarget(
          sourceId: 'episode-retry',
          itemId: 'show',
          title: '测试',
          chapterIndex: 0,
          chapterId: 'one',
          chapterTitle: '第1集',
        ),
      );
      player.loadError = StateError('fixture load failure');
      await openPlayerAction(tester, '播放源 / 更换线路');
      await tester.pumpAndSettle();
      await tester.tap(find.text('第2集'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSourceSheet), findsOneWidget);
      expect(find.text('切集失败，请重试'), findsWidgets);
      player.loadError = null;
      await tester.tap(find.text('第2集'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSourceSheet), findsNothing);
      expect(player.media?.uri.toString(), 'https://example.com/two.mp4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('选集显示方式保存后重新打开仍保留', (tester) async {
      final source = DirectVideoSource(
        id: 'episode-view',
        name: '测试',
        title: '测试',
        uri: Uri.parse('https://example.com/one.mp4'),
        episodes: const [SourceChapter(id: 'one', title: '第1集')],
      );
      await pump(
        tester,
        source: source,
        target: const VideoPlayTarget(
          sourceId: 'episode-view',
          itemId: 'show',
          title: '测试',
          chapterIndex: 0,
          chapterId: 'one',
          chapterTitle: '第1集',
        ),
      );
      await openPlayerAction(tester, '播放源 / 更换线路');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('视图：网格'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('视图：列表'));
      await tester.pumpAndSettle();
      expect(PlayerExperienceStore.current.text('episodeView'), 'cover');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await openPlayerAction(tester, '播放源 / 更换线路');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PlayerSourceSheet>(find.byType(PlayerSourceSheet))
            .initialView,
        PlayerEpisodeView.cover,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('网页临时图源在播放器切下一集无需从源管理器重新打开', (tester) async {
      final parsed = <int>[];
      final source = DirectVideoSource(
        id: 'web-playlist',
        name: '网页',
        title: '兰香如故',
        uri: Uri.parse('https://fixture.invalid/12.m3u8'),
        selected: 11,
        episodes: List.generate(
          47,
          (i) => SourceChapter(id: 'e$i', title: '第${i + 1}集'),
        ),
        resolveEpisode: (index) async {
          parsed.add(index);
          return VideoContent(
            url: Uri.parse('https://fixture.invalid/${index + 1}.m3u8'),
          );
        },
      );
      final players = await pump(
        tester,
        source: source,
        target: const VideoPlayTarget(
          sourceId: 'web-playlist',
          itemId: 'drama',
          title: '兰香如故',
          chapterIndex: 11,
          chapterId: 'e11',
          chapterTitle: '第12集',
        ),
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一集'));
      await tester.pumpAndSettle();
      expect(parsed, [12]);
      expect(players.last.media!.uri.path, '/13.m3u8');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('同剧关闭字幕只记作品偏好，不关闭全局字幕开关', (tester) async {
      const target = VideoPlayTarget(
        sourceId: 'fixture',
        itemId: 'subtitles',
        title: '字幕测试',
        chapterIndex: 0,
        chapterId: '1',
        chapterTitle: '第一集',
      );
      final library = await ReadingLibrary.open(Section.video);
      library.setSetting(
        'video.subtitle.work.${target.identity}',
        '{"off":true}',
      );
      final player = _FakePlayer();
      await pump(tester, target: target, player: player);
      expect(player.subtitleSelections, contains(null));
      expect(VideoPlayerSettingsStore(library).load().subtitlesEnabled, true);
    });

    testWidgets('字幕总开关关闭时语言偏好不得自动打开字幕', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      VideoPlayerSettingsStore(library).save(
        const PlayerSettings(
          subtitlesEnabled: false,
          presentation: PlaybackPresentation(subtitleLanguage: 'en'),
        ),
      );
      final player = _FakePlayer();
      await pump(tester, player: player);
      expect(player.subtitleSelections, isEmpty);
      expect(VideoPlayerSettingsStore(library).load().subtitlesEnabled, false);
    });

    {
      testWidgets('播放器使用设置页当前凭证加载弹幕，修改后立即重载', (tester) async {
        var stored = <String, String>{};
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(DanmakuSourcesStore.channel, (
          call,
        ) async {
          if (call.method == 'read') return stored;
          stored = Map<String, String>.from(call.arguments as Map);
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            DanmakuSourcesStore.channel,
            null,
          ),
        );
        await DanmakuSourcesStore.save([
          {
            'id': 'official',
            'type': 'official',
            'url': DandanplayCredentials.officialBase,
            'appId': 'sample',
            'appSecret': 'secret',
          },
        ], 'official');
        final pending = Completer<http.Response>();
        final requests = <http.Request>[];
        await http.runWithClient(
          () async {
            final players = await pump(
              tester,
              sourceManager: FakeSourceManager(),
              target: const VideoPlayTarget(
                sourceId: 'test',
                itemId: 'item',
                title: '测试作品(2026)【电视剧】from qq',
                chapterIndex: 12,
                chapterId: 'ep7',
                chapterTitle: '第07集',
              ),
            );
            players.single.emit(playing: false);
            pending.complete(
              http.Response(
                jsonEncode({
                  'comments': [
                    {'p': '1,1,16777215,user', 'm': '已接通的弹幕'},
                  ],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            );
            await tester.pumpAndSettle();
            expect(requests.map((r) => r.url.path), [
              '/api/v2/search/episodes',
              '/api/v2/comment/123450007',
            ]);
            expect(requests.first.url.queryParameters['anime'], '测试作品');
            expect(requests.first.url.queryParameters['episode'], '7');
            final overlay = tester.widget<DanmakuOverlay>(
              find.byType(DanmakuOverlay),
            );
            expect(overlay.track.items.single.text, '已接通的弹幕');
            expect(overlay.settings.enabled, isTrue);
            await const DandanplayCredentials(
              'sample',
              'updated-secret',
              baseUrl: DandanplayCredentials.officialBase,
            ).save();
            await tester.pumpAndSettle();
            expect(requests, hasLength(3));
            final signed = requests.last;
            expect(signed.headers['X-AppId'], 'sample');
            expect(
              signed.headers['X-Signature'],
              isNot(requests[1].headers['X-Signature']),
            );
            expect(
              tester
                  .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
                  .track
                  .length,
              1,
            );
            await tester.pumpWidget(const SizedBox());
          },
          () => MockClient((request) async {
            requests.add(request);
            if (request.url.path.contains('/comment/')) return pending.future;
            return http.Response(
              jsonEncode({
                'success': true,
                'animes': [
                  {
                    'animeTitle': '测试作品',
                    'episodes': [
                      {'episodeId': 123450007, 'episodeTitle': '第7集'},
                    ],
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
      });
    }

    testWidgets('官方鉴权失败在播放器弹幕面板显示原因，不影响播放', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DanmakuSourcesStore.channel,
        (_) async => {
          'baseUrl': DandanplayCredentials.officialBase,
          'appId': 'sample',
          'appSecret': 'secret',
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DanmakuSourcesStore.channel,
          null,
        ),
      );
      await http.runWithClient(
        () async {
          final players = await pump(
            tester,
            sourceManager: FakeSourceManager(),
            target: const VideoPlayTarget(
              sourceId: 'test',
              itemId: 'item',
              title: '作品',
              chapterIndex: 0,
              chapterId: '1',
              chapterTitle: '第1集',
            ),
          );
          expect(players.single.plays, greaterThan(0));
          await openPlayerAction(tester, '弹幕设置');
          expect(find.textContaining('设备时间不准确'), findsOneWidget);
          expect(find.textContaining('HTTP 403'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient(
          (_) async => http.Response(
            '',
            403,
            headers: {'x-error-message': 'Invalid Timestamp'},
          ),
        ),
      );
    });

    testWidgets('A 只在播放推进后静默校验，悬挂检测不阻塞起播，失效只提示', (tester) async {
      final pending = Completer<LumeHttpResponse>();
      var checks = 0;
      final meter = _CountingSpeedMeter();
      addTearDown(meter.dispose);
      final players = await pump(
        tester,
        speedMeter: meter,
        validator: PlaybackSourceValidator(
          request: (uri, headers) {
            checks++;
            return pending.future;
          },
        ),
      );
      final player = players.single;
      expect(player.plays, greaterThan(0));
      expect(checks, 0);
      player.emit(position: const Duration(seconds: 1), playing: true);
      await tester.pump();
      expect(checks, 1);
      expect(player.snapshot.value.playing, isTrue);
      player.emit(position: const Duration(seconds: 2), playing: true);
      await tester.pump();
      expect(checks, 1);
      final original = player.media!.uri;
      final loads = player.loads;
      pending.complete(
        LumeHttpResponse(
          statusCode: 404,
          body: Uint8List(0),
          headers: const {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 404'), findsOneWidget);
      expect(player.media!.uri, original);
      expect(player.loads, loads);
      expect(players.length, 1);
    });

    testWidgets('B 关闭校验后直接起播，校验与主动测速均零请求', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      VideoPlayerSettingsStore(library)
          .save(const PlayerSettings(backgroundSourceValidation: false));
      var checks = 0;
      final meter = _CountingSpeedMeter();
      addTearDown(meter.dispose);
      final players = await pump(
        tester,
        speedMeter: meter,
        validator: PlaybackSourceValidator(
          request: (uri, headers) async {
            checks++;
            return LumeHttpResponse(
              statusCode: 404,
              body: Uint8List(0),
              headers: const {},
            );
          },
        ),
      );
      expect(players.single.plays, greaterThan(0));
      players.single.emit(position: const Duration(seconds: 5), playing: true);
      await tester.pumpAndSettle();
      expect(checks, 0);
      expect(meter.requests, 0);
      expect(find.textContaining('后台校验'), findsNothing);
    });

    testWidgets('切换媒体后旧校验失败不得影响新地址', (tester) async {
      final pending = Completer<LumeHttpResponse>();
      var checks = 0;
      final meter = _CountingSpeedMeter();
      addTearDown(meter.dispose);
      final players = await pump(
        tester,
        speedMeter: meter,
        validator: PlaybackSourceValidator(
          request: (uri, headers) => checks++ == 0
              ? pending.future
              : Future.value(
                  LumeHttpResponse(
                    statusCode: 200,
                    body: Uint8List(0),
                    headers: const {},
                  ),
                ),
        ),
        qualities: [
          VideoQuality(
            label: '1080P',
            url: Uri.parse('https://example.com/a.mp4'),
          ),
          VideoQuality(
            label: '720P',
            url: Uri.parse('https://example.com/720.mp4'),
          ),
        ],
      );
      players.single.emit(position: const Duration(seconds: 1), playing: true);
      await tester.pump();
      await openPlayerAction(tester, '清晰度');
      await tester.pumpAndSettle();
      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();
      pending.complete(
        LumeHttpResponse(
          statusCode: 404,
          body: Uint8List(0),
          headers: const {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('后台校验返回'), findsNothing);
      expect(players.single.media!.uri.path, '/720.mp4');
    });

    testWidgets('播放资源 403 保留当前地址并提供手动网页验证入口', (tester) async {
      final players = await pump(
        tester,
        target: const VideoPlayTarget(
          sourceId: 'hanime1_video',
          itemId: 'https://hanime1.me/watch?v=123',
          title: '样片',
          chapterIndex: 0,
          chapterId: 'https://hanime1.me/watch?v=123',
          chapterTitle: '播放',
        ),
      );
      final address = players.single.media!.uri;
      players.single.emit(error: 'HTTP 403: Forbidden');
      await tester.pumpAndSettle();
      expect(find.text('播放网页验证'), findsOneWidget);
      expect(players.single.media!.uri, address);
    });

    testWidgets('媒体尺寸迟到不会改变底部面板位置与尺寸', (tester) async {
      final players = await pump(tester);
      final before = tester.getRect(
        find.byKey(VideoPlayerPage.controlPanelKey),
      );
      players.single.pushStats(const PlayerStats(width: 1080, height: 1920));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(find.byKey(VideoPlayerPage.controlPanelKey)),
        before,
      );
      players.single.pushStats(const PlayerStats(width: 1920, height: 1080));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getRect(find.byKey(VideoPlayerPage.controlPanelKey)),
        before,
      );
    });

    testWidgets('两套按钮样式立即切换，不重建播放器，暂停后也在三秒淡出', (tester) async {
      final players = await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('暂停'), findsNothing);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('文字'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('文字')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('上集'), findsNothing);
      expect(players.length, 1);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byTooltip('播放'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullscreen-actions')), findsNothing);
      await tester.tap(find.text('fake-view'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放'), findsOneWidget);
    });

    testWidgets('控制栏齐全：前进 / 后退 10 秒、清晰度、全屏、设置、播放源都在', (tester) async {
      await pump(tester);

      expect(find.byTooltip('前进 10 秒'), findsOneWidget);
      expect(find.byTooltip('后退 10 秒'), findsOneWidget);
      expect(find.byTooltip('清晰度'), findsOneWidget);
      expect(find.byTooltip('播放内核'), findsOneWidget);
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      // 用户要求：长播放链接不再铺在控制栏上，改成右侧的小信息图标（弹窗里看 / 换）。
      expect(find.byTooltip('线路 / 选集'), findsOneWidget, reason: '播放源入口（地址与线路）');
      expect(find.byType(TextField), findsNothing, reason: '控制栏不再直接展示长链接');
    });

    testWidgets('控制栏只保留一处设置入口，删除重复文字按钮', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(TextButton, '播放器'), findsNothing);
      expect(find.widgetWithText(TextButton, '字幕'), findsNothing);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsWidgets);
    });

    testWidgets('重新播放保留上次选择的画面适配', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      VideoPlayerSettingsStore(library)
          .save(const PlayerSettings().copyWith(zoom: ZoomMode.scale75));
      final players = await pump(tester);
      players.single.pushStats(const PlayerStats(width: 1920, height: 1080));
      await tester.pumpAndSettle();
      final picture = tester.getRect(find.text('fake-view'));
      expect(picture.width, closeTo(675, 1));
      expect(picture.width / picture.height, closeTo(16 / 9, 0.01));
    });

    testWidgets('播放源弹窗：展示当前地址、复制、按线路切换（手动贴地址入口已删除）', (tester) async {
      final players = await pump(
        tester,
        qualities: <VideoQuality>[
          VideoQuality(
            label: '1080P',
            url: Uri.parse('https://example.com/1080.mp4'),
          ),
          VideoQuality(
            label: '720P',
            url: Uri.parse('https://example.com/720.mp4'),
          ),
        ],
      );

      await openPlayerAction(tester, '播放源 / 更换线路');
      await tester.pumpAndSettle();

      // 弹窗里能看到当前地址（可选中复制），并有复制按钮。
      expect(find.text('当前播放地址'), findsNothing);
      expect(
        find.text('https://example.com/a.mp4'),
        findsNothing,
        reason: '当前地址只通过复制图标获取，不在面板上铺长链接',
      );
      await tester.tap(find.byTooltip('播放信息'));
      await tester.pumpAndSettle();
      expect(find.text('复制地址'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      // 用户口径：手动贴地址的入口整条删除（面板里不再有输入框与播放按钮）。
      expect(find.text('手动地址'), findsNothing);
      expect(find.text('播放这个地址'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      // 线路列表（与「清晰度」按钮同一份数据）：点一条即换源并从当前位置继续。
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerSourceSheet),
          matching: find.byTooltip('画质'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('切换后恢复当前进度'), findsOneWidget);
      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();
      expect(
        players.single.media?.uri.toString(),
        'https://example.com/720.mp4',
      );
      expect(find.textContaining('已切换到 720P'), findsOneWidget);
    });

    testWidgets('单线路：画质面板显示真实空态，保留关闭出口', (tester) async {
      await pump(tester);
      await openPlayerAction(tester, '清晰度');
      await tester.pumpAndSettle();

      expect(find.text('当前片源未提供多画质选项'), findsOneWidget);
    });

    testWidgets('手动选择正在播放的画质仍记录偏好，不重新装载视频', (tester) async {
      final players = await pump(
        tester,
        qualities: [
          VideoQuality(
            label: '1080P',
            url: Uri.parse('https://example.com/1080.mp4'),
          ),
          VideoQuality(
            label: '720P',
            url: Uri.parse('https://example.com/720.mp4'),
          ),
        ],
      );
      final loads = players.single.loads;
      await openPlayerAction(tester, '清晰度');
      await tester.pumpAndSettle();
      await tester.tap(find.text('1080P'));
      await tester.pumpAndSettle();
      final library = await ReadingLibrary.open(Section.video);
      expect(
        library.setting(VideoPlayerSettingsStore.keyManualQualityLabel),
        '1080P',
      );
      expect(players.single.loads, loads);
    });

    testWidgets('多线路：弹菜单，选中后换地址重载并提示', (tester) async {
      final players = await pump(
        tester,
        qualities: <VideoQuality>[
          VideoQuality(
            label: '1080P',
            url: Uri.parse('https://example.com/1080.mp4'),
          ),
          VideoQuality(
            label: '720P',
            url: Uri.parse('https://example.com/720.mp4'),
          ),
        ],
      );
      expect(
        players.single.media?.uri.toString(),
        'https://example.com/1080.mp4',
      );

      await openPlayerAction(tester, '清晰度');
      await tester.pumpAndSettle();
      expect(find.text('1080P'), findsOneWidget);
      expect(find.text('720P'), findsOneWidget);

      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();

      expect(
        players.single.media?.uri.toString(),
        'https://example.com/720.mp4',
      );
      expect(find.textContaining('已切换到 720P'), findsOneWidget);
    });

    for (final percent in <int?>[95, 100, null]) {
      testWidgets('顶边时间靠左电量靠右，位于操作按钮上方：$percent', (tester) async {
        const channel = MethodChannel('lumebox/battery');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => percent);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await pump(tester);
        await tester.binding.setSurfaceSize(const Size(932, 430));
        await tester.tap(find.byTooltip('全屏'));
        await tester.pumpAndSettle();
        final status = tester.getRect(
          find.byKey(const Key('player-status-row')),
        );
        final clock = tester.getRect(
          find.byKey(const Key('player-clock-text')),
        );
        final settings = tester.getRect(find.byTooltip('播放器设置'));
        expect(status.bottom, lessThan(settings.top));
        expect(clock.left, closeTo(status.left, .1));
        expect(status.right, closeTo(settings.right, .1));
        expect(status.height, lessThan(24), reason: '时间和电量只占一行');
        if (percent != null) {
          final battery = tester.getRect(
            find.byKey(const Key('player-battery-text')),
          );
          final group = tester.getRect(
            find.byKey(const Key('player-battery-group')),
          );
          expect(group.right, closeTo(status.right, .1));
          expect(clock.right, lessThan(battery.left));
          expect(clock.center.dy, closeTo(battery.center.dy, .1));
          expect(find.text('$percent%'), findsOneWidget);
        } else {
          expect(find.byKey(const Key('player-battery-text')), findsNothing);
          expect(find.text('--%'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('横屏选集独立，全屏面板也能进画质，移除上一集按钮', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(932, 430));
      await tester.pumpAndSettle();
      expect(find.byTooltip('上一集'), findsNothing);
      await tester.tap(find.byTooltip('线路 / 选集'));
      await tester.pumpAndSettle();
      // 标题行已并入图标工具条：面板里没有大标题，只有集数与图标。
      expect(find.text('选集与线路'), findsNothing);
      expect(find.byTooltip('选集'), findsOneWidget);
      // 全屏也提供画质分区，不必再绕去设置。
      expect(find.byTooltip('画质'), findsOneWidget);
      await tester.tap(find.byTooltip('画质'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('选集'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      // 从设置「清晰度」进来的画质面板没有分区切换，只有列表与信息图标。
      await openPlayerAction(tester, '清晰度');
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSourceSheet), findsOneWidget);
      expect(find.byTooltip('选集'), findsNothing);
      expect(find.byTooltip('线路'), findsNothing);
      expect(find.byTooltip('画质'), findsNothing);
    });

    testWidgets('横屏按钮外移后左右边距为系统安全区加8，点击框至少44', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(932, 430));
      final ratio = tester.view.devicePixelRatio;
      tester.view.viewPadding = FakeViewPadding(
        top: 24 * ratio,
        left: 44 * ratio,
        right: 24 * ratio,
        bottom: 21 * ratio,
      );
      tester.view.padding = FakeViewPadding(
        top: 24 * ratio,
        left: 44 * ratio,
        right: 24 * ratio,
        bottom: 21 * ratio,
      );
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      final play = tester.getRect(find.byTooltip('暂停'));
      final episodes = tester.getRect(find.byTooltip('线路 / 选集'));
      final rotation = tester.getRect(find.byTooltip('横竖屏切换'));
      expect(play.left, closeTo(44 + 8, .01));
      expect(932 - episodes.right, closeTo(24 + 8, .01));
      expect(932 - rotation.right, closeTo(24 + 8, .01));
      expect(
        932 - tester.getRect(find.byTooltip('播放器设置')).right,
        closeTo(24 + 8, .01),
      );
      final status = tester.getRect(find.byKey(const Key('player-status-row')));
      expect(status.top, greaterThanOrEqualTo(24));
      expect(status.left, closeTo(44 + 8, .01));
      expect(932 - status.right, closeTo(24 + 8, .01));
      expect(play.width, greaterThanOrEqualTo(44));
      expect(play.height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });

    testWidgets('横屏右侧文字入口按弹幕、倍速、选集排列，画质与内核收进设置', (tester) async {
      await tester.binding.setSurfaceSize(const Size(932, 430));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;
      expect(x('弹幕：开'), lessThan(x('播放速度（1.0x）')));
      expect(x('播放速度（1.0x）'), lessThan(x('线路 / 选集')));
      expect(find.text('弹幕'), findsOneWidget);
      expect(find.text('1.0×'), findsOneWidget);
      expect(find.text('选集'), findsOneWidget);
      expect(find.byTooltip('清晰度'), findsNothing);
      expect(find.byTooltip('播放内核'), findsNothing);
      expect(find.byTooltip('记片头（长按清除标记）'), findsNothing);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      await tester.dragUntilVisible(
        find.widgetWithText(ChoiceChip, '1.5x').first,
        find.byType(PlayerSettingsSheet),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(PlayerSettingsSheet),
              matching: find.widgetWithText(ChoiceChip, '1.5x'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('1.5x'), findsWidgets);

      // 分类跳转到内核，再回到播放分类，验证各内核独立倍速。
      await tester.tap(find.byKey(const ValueKey('player-category-advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-category-playback')));
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

    testWidgets('弹幕独立入口有效，播放器设置不重复弹幕面板', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      expect(find.text('显示弹幕'), findsNothing);
      Navigator.of(tester.element(find.byType(PlayerSettingsSheet))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('弹幕：开'));
      await tester.pumpAndSettle();
      expect(find.text('来源与匹配'), findsOneWidget);
      await tester.tap(find.text('显示样式'));
      await tester.pumpAndSettle();
      expect(find.text('不透明度'), findsOneWidget);
      await tester.ensureVisible(find.text('恢复默认'));
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

    testWidgets('全屏：完整分辨率与速率，跟着控制浮层一起出现 / 收起', (tester) async {
      final players = await pump(tester);
      players.single.pushStats(
        const PlayerStats(
          width: 1920,
          height: 1080,
          downloadBytesPerSecond: 125000000,
        ),
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      // 顶部显示分辨率，底部显示速率，二者一起收起与唤回。
      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.text('125.0MB/s'), findsOneWidget);
      expect(find.textContaining('网速'), findsNothing);
      // 自动收起：浮层连同这一排一起走，画面上不再压着参数。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('1920×1080'), findsNothing);
      expect(find.text('125.0MB/s'), findsNothing);
      // 点画面唤回。
      await tester.tap(find.text('fake-view'));
      await tester.pump();
      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final fullscreen in [false, true]) {
      testWidgets('弹幕设置避让状态栏，滚动后仍可返回播放：全屏=$fullscreen', (tester) async {
        tester.view.padding = const FakeViewPadding(top: 59);
        tester.view.viewPadding = const FakeViewPadding(top: 59);
        addTearDown(tester.view.reset);
        await pump(tester);
        if (fullscreen) {
          await tester.tap(find.byTooltip('全屏'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('弹幕：开'));
        await tester.pumpAndSettle();
        final back = find.byTooltip('返回播放');
        expect(
          tester.getRect(back).top,
          greaterThanOrEqualTo(59 / tester.view.devicePixelRatio),
        );
        await tester.tap(find.text('显示样式'));
        await tester.pumpAndSettle();
        await tester.drag(find.text('不透明度'), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(back.hitTestable(), findsOneWidget);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭弹幕设置'), findsNothing);
        expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      });
    }

    testWidgets('画面显示一份分辨率与速率（不带「网速」字样），控制卡片不重复显示', (tester) async {
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

      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.text('1.8Mbps'), findsOneWidget);
      expect(find.textContaining('网速'), findsNothing);
      expect(find.textContaining('分辨率 '), findsNothing);
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
            .ancestor(
              of: find.text('fake-view'),
              matching: find.byType(SizedBox),
            )
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
        lessThanOrEqualTo(16),
        reason: '控制区紧接画面，不再预留大块空白',
      );
      expect(
        VideoPlayerPage.controlBottomGap,
        lessThan(16),
        reason: '底部留白收窄 = 整块控制区（进度条 + 下面所有按钮）跟着往下挪',
      );

      // 顺序没变：信息行在上，进度条居中，按钮在下（只动垂直位置，不动结构）。
      final infoY = tester.getCenter(find.text('1080×1920')).dy;
      final sliderY = tester.getCenter(find.byType(Slider).first).dy;
      final buttonY = tester.getCenter(find.byTooltip('播放器设置')).dy;
      expect(infoY, lessThan(sliderY));
      expect(sliderY, lessThan(buttonY));
    });

    testWidgets('播放错误时控制栏保持可见，允许重试与退出全屏', (tester) async {
      final players = await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      players.single.emit(
        playing: true,
        error: 'tcp: ffurl_read returned 0xffffffc4',
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('重试播放'), findsOneWidget);
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
    });

    testWidgets('锁定按钮自动隐藏，播放报错后仍可点击画面唤回并解锁', (tester) async {
      final players = await pump(tester);
      await tester.tap(find.byTooltip('锁定（防误触）'));
      await tester.pump();
      expect(find.byTooltip('解除锁定'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byTooltip('解除锁定'), findsNothing);
      players.single.emit(error: 'fixture error');
      await tester.pump();
      await tester.tap(find.byKey(const Key('locked-player-surface')));
      await tester.pump();
      expect(find.byTooltip('解除锁定'), findsOneWidget);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pump();
      expect(find.byKey(const Key('locked-player-surface')), findsNothing);
    });

    testWidgets('长按使用4倍临时速度，松手恢复1.25倍且不覆盖已保存倍速', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      VideoPlayerSettingsStore(library).save(
        const PlayerSettings().copyWith(
          speed: 1.25,
          gestures: const PlayerGestureOptions(boostMultiplier: 4),
        ),
      );
      final players = await pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('fake-view')),
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(players.single.lastAppliedSettings!.speed, 4);
      await gesture.up();
      await tester.pump();
      expect(players.single.lastAppliedSettings!.speed, 1.25);
      expect(VideoPlayerSettingsStore(library).load().speed, 1.25);
    });

    testWidgets('音乐模式和静音音量从偏好恢复，切换音乐模式写回本机', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      final preferences = PlayerExperienceStore.forLibrary(library);
      preferences.update({'volume': .35, 'muted': true, 'musicMode': true});
      final players = await pump(tester);
      expect(players.single.volume, 0);
      expect(find.text('fake-view'), findsNothing);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('音乐模式'),
        find.byType(PlayerSettingsSheet),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '音乐模式'));
      await tester.pumpAndSettle();
      expect(preferences.value.flag('musicMode'), false);
      expect(preferences.value.number('volume', 1, 0, 1), .35);
    });

    testWidgets('缓冲延迟显示小型进度条，结束后收起', (tester) async {
      final players = await pump(tester);
      players.single.emit(buffering: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      final notice = find.byKey(const Key('player-buffering-notice'));
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        tester.getCenter(notice).dy,
        closeTo(tester.getCenter(find.text('fake-view')).dy, 1),
      );
      players.single.emit(buffering: false);
      await tester.pump();
      expect(notice, findsNothing);
    });

    testWidgets('全屏锁定后解锁按钮避让顶部和右侧系统安全区', (tester) async {
      final ratio = tester.view.devicePixelRatio;
      tester.view.viewPadding = FakeViewPadding(
        top: 59 * ratio,
        right: 44 * ratio,
      );
      tester.view.padding = FakeViewPadding(top: 59 * ratio, right: 44 * ratio);
      addTearDown(tester.view.reset);
      final players = await pump(tester);
      players.single.pushStats(const PlayerStats(width: 1920, height: 1080));
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('锁定（防误触）'));
      await tester.pumpAndSettle();
      final unlock = find.byTooltip('解除锁定');
      expect(unlock, findsOneWidget);
      final rect = tester.getRect(unlock);
      expect(rect.top, greaterThanOrEqualTo(59));
      expect(rect.right, lessThanOrEqualTo(900 - 44));
      await tester.tap(unlock);
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
    });

    testWidgets('竖屏锁定时播放报错仍能解锁，恢复设置入口', (tester) async {
      final players = await pump(tester);
      await tester.tap(find.byTooltip('锁定（防误触）'));
      await tester.pumpAndSettle();
      players.single.emit(error: 'connection closed');
      await tester.pump();
      expect(find.byTooltip('解除锁定'), findsOneWidget);
      await tester.tap(find.byTooltip('解除锁定'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放器设置'), findsOneWidget);
    });

    testWidgets('倍速点击弹出选项，选择后生效且可关闭', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('播放速度（1.0x）'));
      await tester.pumpAndSettle();
      expect(find.text('播放速度'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '2.0x'));
      await tester.pumpAndSettle();
      expect(find.text('播放速度'), findsNothing);
      expect(find.byTooltip('播放速度（2.0x）'), findsOneWidget);
    });

    testWidgets('未出现首帧不自动测速', (tester) async {
      final client = _CountingClient(bytes: 256 * 1024);
      final meter = PlaybackSpeedMeter(http: LumeHttp(client: client));
      addTearDown(meter.dispose);
      final players = await pump(tester, speedMeter: meter);
      players.single.emit(playing: true, duration: const Duration(minutes: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(client.urls, isEmpty);
      expect(find.textContaining('测速'), findsNothing);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.textContaining('测速'), findsNothing);
      expect(find.widgetWithText(TextButton, '播放器'), findsNothing);
      expect(find.widgetWithText(TextButton, '字幕'), findsNothing);
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

    testWidgets('全屏顶栏只有一个锁，移除未接入的投屏入口', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();

      // 左侧锁定与右侧屏幕方向控制位于画面两边。
      // 提示文案在 Tooltip.message 上（不是 Text 节点），动态项用谓词匹配。
      Finder tipContains(String part) => find.byWidgetPredicate(
        (widget) => widget is Tooltip && (widget.message ?? '').contains(part),
        description: 'Tooltip 含「$part」',
      );

      expect(find.byTooltip('退出全屏'), findsWidgets);
      expect(find.byTooltip('投屏（本版本未接入）'), findsNothing);
      expect(tipContains('弹幕：'), findsWidgets);
      expect(tipContains('播放速度（'), findsOneWidget);
      expect(find.byTooltip('锁定（防误触）'), findsOneWidget);
      // 音轨入口已按用户口径从播放页拿掉（设置弹窗里仍可切）。
      expect(find.byTooltip('音轨'), findsNothing);
      expect(find.byTooltip('字幕'), findsNothing);
      // 低频的内核选择收进播放器设置。
      expect(find.byTooltip('播放内核'), findsNothing);
      expect(find.byTooltip('播放器设置'), findsOneWidget);
      expect(find.byTooltip('横竖屏切换'), findsOneWidget);
      await tester.tap(find.byTooltip('横竖屏切换'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('横竖屏切换'), findsOneWidget);
      // 点画面：立即收起控制栏；再点一次唤出（用户口径）。
      await tester.tap(find.byType(Scaffold).first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放器设置'), findsNothing);
      await tester.tap(find.byType(Scaffold).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      expect(find.text('播放器设置'), findsOneWidget);
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

      final players = await pump(tester);
      players.single.pushStats(const PlayerStats(width: 1920, height: 1080));
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();

      final landscape = calls.lastWhere(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(
        landscape.arguments,
        containsAll(<String>[
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
        reason: '进全屏自动横屏（左右都收）',
      );

      await tester.tap(find.byTooltip('退出全屏').first);
      await tester.pumpAndSettle();
      final portrait = calls.lastWhere(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(portrait.arguments, <String>['DeviceOrientation.portraitUp']);
    });

    testWidgets('竖屏短剧入场首帧使用预检尺寸且不重复加载', (tester) async {
      final calls = _captureOrientations(tester);
      final player = _FakePlayer(kernel: PlayerKernel.avplayer);
      player.pushStats(const PlayerStats(width: 720, height: 1280));
      late PlayerPrelaunch prelaunch;
      await tester.runAsync(() async {
        prelaunch = PlayerPrelaunch.start(
          PlayerKernel.avplayer,
          factory: (_) => player,
        );
        await prelaunch.prepareMedia(
          PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
        );
      });
      await pump(tester, fullscreenOnly: true, prelaunch: prelaunch);
      expect(player.loads, 1, reason: '入场接手已经加载的同一个实例');
      final entries = calls.where(
        (c) => c.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(entries, isNotEmpty);
      expect(
        entries.every(
          (c) => (c.arguments as List).contains('DeviceOrientation.portraitUp'),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('未知尺寸先保持竖屏，迟到的短剧尺寸不会触发横屏闪动', (tester) async {
      final calls = _captureOrientations(tester);
      final players = await pump(tester, fullscreenOnly: true);
      expect(_lastOrientations(calls), ['DeviceOrientation.portraitUp']);
      players.single.pushStats(const PlayerStats(width: 720, height: 1280));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
            .every(
              (c) => !(c.arguments as List).contains(
                'DeviceOrientation.landscapeLeft',
              ),
            ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
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
      expect(_lastOrientations(calls), <String>[
        'DeviceOrientation.portraitUp',
      ], reason: '竖屏短剧（宽 < 高）进全屏就是竖屏全屏');

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
      PlaybackOrientationController.instance.apply(
        PlaybackOrientation.landscape,
      );
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
      PlaybackOrientationController.instance.apply(
        PlaybackOrientation.portrait,
      );
      await tester.pumpAndSettle();
      expect(_lastOrientations(calls), <String>[
        'DeviceOrientation.portraitUp',
      ]);
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

    testWidgets('进度条拖动：拖动中节流快 seek，松手精确 seek', (tester) async {
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
      // 拖动中会节流快 seek（150ms 一次），但不会每帧都发，也不进精确 seek。
      expect(
        players.single.fastSeeks.length,
        lessThanOrEqualTo(1),
        reason: '拖动中节流，不每帧 seek',
      );
      expect(players.single.seeks, isEmpty, reason: '拖动中不做过精确跳转');
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(
        players.single.fastSeeks.length,
        lessThanOrEqualTo(4),
        reason: '连续拖动也按 150ms 节流',
      );

      await gesture.up();
      await tester.pump();
      expect(players.single.seeks, isNotEmpty, reason: '松手要落到精确位置');
      expect(
        find.textContaining('拖动到'),
        findsOneWidget,
        reason: '内核尚未确认跳转，保留目标位置避免回弹',
      );
      players.single.emit(
        position: players.single.seeks.last,
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('拖动到'), findsNothing);
    });

    testWidgets('拖动中快 seek 串行且只留最新落点', (tester) async {
      final players = await pump(tester);
      players.single.emit(
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();

      // 快 seek 挂在闸门上：模拟内核还在处理上一次跳转。
      final gate = Completer<void>();
      players.single.seekGate = gate;

      final slider = find.byType(Slider).first;
      final box = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(box.left + box.width * 0.5, box.center.dy),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(
        players.single.fastSeeks.length,
        1,
        reason: '上一次快 seek 没回来之前不并发下发',
      );

      // 放行之后只补一次「最新落点」，中间那些落点不补发。
      gate.complete();
      players.single.seekGate = null;
      await tester.pump(const Duration(milliseconds: 200));
      expect(players.single.fastSeeks.length, 2, reason: '排队的多个落点合并成最新一个');
      expect(
        players.single.fastSeeks.last,
        isNot(players.single.fastSeeks.first),
        reason: '补发的是最新落点，不是被打断的那个',
      );
      await gesture.up();
      await tester.pump();
      // 让内核把位置落到松手的目标上：确认成功就不会再挂看门狗。
      players.single.emit(
        position: players.single.seeks.last,
        duration: const Duration(minutes: 10),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('松手后内核跳转不返回：预览不滞留，自动重发一次', (tester) async {
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
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 200));

      // 松手这一刻起，内核的 seek 一直不返回。
      final gate = Completer<void>();
      players.single.seekGate = gate;
      await gesture.up();
      await tester.pump();
      expect(players.single.seeks, hasLength(1));
      expect(find.textContaining('拖动到'), findsOneWidget);

      // 2s 超时后不再挂着：预览文字收掉（缓冲由内核状态自己表达）。
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('拖动到'),
        findsNothing,
        reason: '跳转回调不来也必须收尾，不能把预览留在屏幕上',
      );

      // 6s 看门狗：位置没动且还在缓冲，自动重发同一跳转。
      players.single.emit(buffering: true);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(players.single.seeks.length, 2, reason: '卡住不动时自动重发一次同一跳转');
      expect(players.single.seeks.last, players.single.seeks.first);
      // 放行并让位置到位：重发这次确认成功，不再挂下一轮看门狗。
      players.single.seekGate = null;
      players.single.emit(
        position: players.single.seeks.last,
        duration: const Duration(minutes: 10),
      );
      gate.complete();
      await tester.pumpAndSettle();
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
    testWidgets('跳转被内核拒绝：给出失败提示，保持暂停状态', (tester) async {
      final player = _FakePlayer()..seekError = StateError('seek rejected');
      await pump(tester, player: player);
      player.emit(
        position: const Duration(seconds: 74),
        duration: const Duration(minutes: 10),
        playing: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('前进 10 秒'));
      await tester.pump();
      expect(find.text('跳转失败，请重试'), findsOneWidget);
      expect(player.snapshot.value.position, const Duration(seconds: 74));
      expect(player.snapshot.value.playing, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏：播放移到底栏，中央没有快进控件且只有一个选集入口', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      final slider = tester.getRect(find.byType(Slider));
      final play = tester.getCenter(find.byTooltip('暂停'));
      final episodes = tester.getCenter(find.byTooltip('线路 / 选集'));
      expect(play.dy, greaterThan(slider.bottom));
      expect(find.byTooltip('后退 10 秒'), findsNothing);
      expect(find.byTooltip('前进 10 秒'), findsNothing);
      expect(episodes.dy, greaterThan(slider.bottom));
      expect(find.byTooltip('停止'), findsNothing);
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      expect(find.byTooltip('记片头（长按清除标记）'), findsNothing);
      expect(find.byTooltip('弹幕：开'), findsOneWidget);
      expect(find.byTooltip('锁定（防误触）'), findsOneWidget);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSettingsSheet), findsOneWidget);
    });

    for (final size in const [Size(844, 390), Size(375, 812), Size(320, 568)]) {
      testWidgets('全屏常用功能在安全区内且无溢出：$size', (tester) async {
        final players = await pump(
          tester,
          target: const VideoPlayTarget(
            sourceId: 'local',
            itemId: 'layout',
            title: '很长的视频标题用于检查横竖屏排列和自动省略不得挤出按钮',
            chapterIndex: 0,
            chapterId: 'one',
            chapterTitle: '第1集',
          ),
        );
        await tester.tap(find.byTooltip('全屏'));
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(size);
        players.single.emit(
          duration: const Duration(minutes: 90),
          position: const Duration(minutes: 15),
        );
        players.single.pushStats(
          const PlayerStats(
            width: 1920,
            height: 1080,
            downloadBytesPerSecond: 128000,
          ),
        );
        await tester.pumpAndSettle();
        for (final label in [
          '退出全屏',
          '播放器设置',
          '播放速度（1.0x）',
          '线路 / 选集',
          '锁定（防误触）',
        ]) {
          final rect = tester.getRect(find.byTooltip(label));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        expect(tester.takeException(), isNull);
        final gradient = tester.getRect(
          find.byKey(const Key('fullscreen-control-gradient')),
        );
        expect(gradient.size, size, reason: '渐变覆盖全画面，安全区边缘不形成矩形边界');
        expect(find.byTooltip('播放内核'), findsNothing);
        expect(find.byTooltip('清晰度'), findsNothing);
        expect(find.text('第1集 · 1920×1080'), findsOneWidget);
        final slider = tester.getRect(find.byType(Slider));
        final time = tester.getRect(find.text('15:00'));
        expect(time.center.dy, closeTo(slider.center.dy, 2));
        expect(slider.top, greaterThan(size.height * .65));
      });
    }

    testWidgets('集名后显示完整分辨率，速率在进度条上方且随媒体更新', (tester) async {
      const title = '播放布局验证';
      final players = await pump(
        tester,
        target: const VideoPlayTarget(
          sourceId: 'local',
          itemId: 'layout',
          title: title,
          chapterIndex: 0,
          chapterId: 'one',
          chapterTitle: '第1集',
        ),
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      players.single.pushStats(
        const PlayerStats(
          width: 1920,
          height: 800,
          downloadBytesPerSecond: 125000000,
        ),
      );
      await tester.pumpAndSettle();
      final stats = tester.getRect(find.text('第1集 · 1920×800'));
      final speed = tester.getRect(find.text('125.0MB/s'));
      final top = tester.getRect(find.byKey(const Key('fullscreen-topbar')));
      final slider = tester.getRect(find.byType(Slider));
      final actions = tester.getRect(
        find.byKey(const Key('fullscreen-actions')),
      );
      expect(top.contains(stats.center), isTrue);
      final titleRect = tester.getRect(find.text(title).first);
      expect(stats.top, greaterThanOrEqualTo(titleRect.bottom));
      expect(stats.left, closeTo(titleRect.left, .1));
      expect(speed.bottom, lessThanOrEqualTo(slider.top));
      expect(speed.right, closeTo(actions.right, .1));
      expect(find.byTooltip('清晰度'), findsNothing);
      expect(find.text('800P'), findsNothing);
      players.single.pushStats(const PlayerStats(width: 1280, height: 720));
      await tester.pumpAndSettle();
      expect(find.text('第1集 · 1280×720'), findsOneWidget);
      expect(find.text('第1集 · 1920×800'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('关闭全屏速率显示会保存偏好，重新进入仍生效且保留分辨率', (tester) async {
      final players = await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      players.single.pushStats(
        const PlayerStats(
          width: 1920,
          height: 800,
          downloadBytesPerSecond: 1250000,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1.3MB/s'), findsOneWidget);
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-category-advanced')));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('显示播放速率'),
        find.byType(PlayerSettingsSheet),
        const Offset(0, -160),
      );
      await tester.tap(find.text('显示播放速率'));
      await tester.pumpAndSettle();
      expect(
        PlayerExperienceStore.current.flag('showNetworkSpeed', true),
        isFalse,
      );
      Navigator.of(tester.element(find.byType(PlayerSettingsSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.text('1.3MB/s'), findsNothing);
      expect(find.text('1920×800'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final reopened = await pump(tester);
      reopened.single.pushStats(
        const PlayerStats(
          width: 1920,
          height: 800,
          downloadBytesPerSecond: 1250000,
        ),
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullscreen-network-speed')), findsNothing);
      expect(find.text('1920×800'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('播放页提示走顶部胶囊：1.6 秒、不排队、不再是黑条', (tester) async {
      await pump(tester);
      // 快捷记片头按钮在没有作品身份时会弹一句提示。
      await tester.tap(find.text('记片头'));
      await tester.pumpAndSettle();
      expect(find.textContaining('从源条目起播才能记片头片尾'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing, reason: '播放页不再用黑条');
      // 新提示顶掉旧的：连着两条不会排队压两条（用户口径）。
      await tester.tap(find.text('记片头'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('从源条目起播才能记片头片尾'),
        findsOneWidget,
        reason: '不排队，只有一条',
      );
      // 1.6 秒后自己消失。
      await tester.pump(const Duration(milliseconds: 1700));
      expect(find.textContaining('从源条目起播才能记片头片尾'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('双击右侧前进 10 秒，提示走顶部胶囊', (tester) async {
      final players = await pump(tester);
      players.single.emit(
        duration: const Duration(minutes: 2),
        position: const Duration(seconds: 30),
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      final size = tester
          .getRect(find.byKey(const Key('fullscreen-control-gradient')))
          .size;
      final right = Offset(size.width * .88, size.height * .5);
      await tester.tapAt(right);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(right);
      await tester.pumpAndSettle();
      expect(players.single.seeks.last, const Duration(seconds: 40));
      expect(find.text('前进 10 秒'), findsOneWidget, reason: '轻提示不是黑条');
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 1700));
      expect(find.text('前进 10 秒'), findsNothing, reason: '1.6 秒后淡出');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('全屏底部控制区贴住底部（用户口径：整块往下移）', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      final height = tester.getSize(find.byType(Scaffold).first).height;
      final bottomRow = tester.getRect(find.byTooltip('线路 / 选集'));
      expect(
        height - bottomRow.bottom,
        lessThan(48),
        reason: '底排按钮离底边只留安全区 + 6pt，不再悬在半空',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('全屏控制栏自动隐藏：播放中无操作 3 秒收起，点屏幕唤回', (tester) async {
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
      expect(find.byType(Slider), findsNothing, reason: '无操作 3 秒后控制栏自动隐藏');

      await tester.tap(find.byType(Scaffold).first);
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget, reason: '点屏幕再显示');
    });

    testWidgets('无障碍导航：播放中全屏控制栏保持可访问', (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final players = await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      players.single.emit(playing: true, duration: const Duration(minutes: 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);
      expect(find.byTooltip('前进 10 秒'), findsNothing);
      expect(find.byTooltip('退出全屏'), findsWidgets);
    });

    testWidgets('播放中开启无障碍导航：恢复隐藏的控制栏并取消计时', (tester) async {
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final players = await pump(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      players.single.emit(playing: true, duration: const Duration(minutes: 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
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
      expect(find.byType(Slider), findsOneWidget, reason: '关掉自动隐藏后控制栏一直显示');
    });
    for (final kernel in PlayerKernel.values) {
      testWidgets('画中画保留 $kernel 内核、自动播放；短暂 inactive 不关闭窗口', (tester) async {
        (await ReadingLibrary.open(Section.video))
            .setSetting(VideoPlayerSettingsStore.keyKernel, kernel.id);
        final backend = _TestPipBackend();
        addTearDown(backend.close);
        final created = await pump(tester, pipBackend: backend);
        created.single.emit(playing: false);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.picture_in_picture_alt));
        await tester.pumpAndSettle();
        expect(created.length, 1, reason: '画中画不重建或切换内核');
        expect(created.single.kernel, kernel);
        expect(created.single.snapshot.value.playing, true);
        expect(backend.started, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(backend.stopped, 0, reason: '开窗引起的短暂焦点变化不能立即退出画中画');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(backend.stopped, 1);
      });
    }
    {
      for (final mode in ['portrait', 'landscape', 'pip']) {
        testWidgets('同剧第二集自动跳过贯穿布局与画中画：mode=$mode', (tester) async {
          final store = (await tester.runAsync(IntroStore.open))!;
          store.update({
            'active': true,
            'manual': true,
            'reuseManualSeason': true,
            'countdown': 3,
          });
          const first = EpisodeIdentity(series: 'fixture:series', episode: 1);
          store.rememberSeries(first, 600000, [
            const SkipSegment(
              kind: SegmentKind.opening,
              startMs: 0,
              endMs: 60000,
              confidence: 1,
              source: 'manual',
            ),
            const SkipSegment(
              kind: SegmentKind.ending,
              startMs: 540000,
              endMs: 600000,
              confidence: 1,
              source: 'manual',
            ),
          ]);
          final backend = _TestPipBackend();
          addTearDown(backend.close);
          final players = await pump(
            tester,
            pipBackend: backend,
            sourceManager: FakeSourceManager(),
            target: const VideoPlayTarget(
              sourceId: 'fixture',
              itemId: 'series',
              title: '测试剧',
              chapterIndex: 1,
              chapterId: 'ep2',
              chapterTitle: '第2集',
            ),
          );
          final player = players.single;
          player.emit(
            playing: true,
            position: Duration.zero,
            duration: const Duration(seconds: 620),
          );
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          });
          await tester.pump(const Duration(milliseconds: 100));
          if (mode == 'landscape') {
            await tester.tap(find.byTooltip('全屏').first);
            await tester.pumpAndSettle();
          } else if (mode == 'pip') {
            await tester.tap(find.byIcon(Icons.picture_in_picture_alt).first);
            await tester.pumpAndSettle();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
          }
          player.emit(
            playing: true,
            position: const Duration(seconds: 5),
            duration: const Duration(seconds: 620),
          );
          await tester.pump(const Duration(seconds: 4));
          expect(player.seeks, contains(const Duration(seconds: 60)));
          player.emit(
            playing: true,
            position: const Duration(seconds: 565),
            duration: const Duration(seconds: 620),
          );
          await tester.pump(const Duration(seconds: 4));
          expect(
            player.seeks,
            contains(const Duration(seconds: 620)),
            reason: '片尾按剩余60秒适配新集',
          );
          if (mode == 'pip') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
      }
    }

    testWidgets('退出播放页立即暂停并停止，画中画退出失败也释放播放器', (tester) async {
      final backend = _TestPipBackend()..stopFailure = true;
      addTearDown(backend.close);
      final created = await pump(tester, pipBackend: backend);
      await tester.tap(find.byIcon(Icons.picture_in_picture_alt));
      await tester.pumpAndSettle();
      final player = created.single;
      expect(player.snapshot.value.playing, true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.snapshot.value.playing, false);
      expect(player.pauses, greaterThan(0));
      expect(player.stops, greaterThan(0));
      expect(player.disposals, 1);
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

  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(),
  );
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: 'fake'),
  );

  final subtitleSelections = <String?>[];
  @override
  Future<void> selectSubtitleTrack(String? id) async {
    subtitleSelections.add(id);
  }

  PlayerMedia? media;
  final List<Duration> seeks = <Duration>[];

  /// 拖动中的快 seek（内核允许落到关键帧那一档）。
  final List<Duration> fastSeeks = <Duration>[];

  /// 非 null 时 seek / seekFast 都挂在它上面：模拟「内核的跳转回调不来」。
  Completer<void>? seekGate;

  Object? seekError;
  Object? loadError;
  int plays = 0, pauses = 0, stops = 0, disposals = 0, loads = 0;
  double volume = 1;
  PlayerSettings? lastAppliedSettings;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  void pushStats(PlayerStats next) => _stats.value = next;

  void emit({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    String? error,
  }) {
    _snapshot.value = PlayerSnapshot(
      position: position ?? _snapshot.value.position,
      duration: duration ?? _snapshot.value.duration,
      playing: playing ?? _snapshot.value.playing,
      buffering: buffering ?? _snapshot.value.buffering,
      error: error,
    );
  }

  @override
  Future<void> load(PlayerMedia media) async {
    if (loadError case final error?) throw error;
    loads++;
    this.media = media;
  }

  @override
  Future<void> play() async {
    plays++;
    emit(playing: true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    emit(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    if (seekError case final error?) throw error;
    seeks.add(position);
    final gate = seekGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> seekFast(Duration position) async {
    fastSeeks.add(position);
    final gate = seekGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    lastAppliedSettings = settings;
  }

  @override
  Widget buildView() => const Text('fake-view');

  @override
  Future<void> dispose() async {
    disposals++;
  }
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
      headers: const <String, String>{
        'content-range': 'bytes 0-262143/99999999',
      },
    );
  }
}

Future<void> openPlayerAction(WidgetTester tester, String action) async {
  if (action == '清晰度' && find.byTooltip('清晰度').evaluate().isEmpty) {
    await tester.tap(find.byTooltip('播放器设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ListTile, '画质'));
    await tester.tap(find.widgetWithText(ListTile, '画质'));
    await tester.pumpAndSettle();
    return;
  }
  final tooltip = switch (action) {
    '播放源 / 更换线路' => '线路 / 选集',
    '清晰度' => '清晰度',
    '弹幕设置' => '弹幕：开',
    _ => '播放器设置',
  };
  await tester.tap(find.byTooltip(tooltip).first);
  await tester.pumpAndSettle();
}

class _TestPipBackend implements PipBackend {
  final _events = StreamController<PipEvent>.broadcast();
  int started = 0, stopped = 0;
  bool stopFailure = false;
  @override
  Future<bool> isSupported() async => true;
  @override
  Stream<PipEvent> get events => _events.stream;
  @override
  Future<void> start() async {
    started++;
    _events.add(const PipEvent(PipEventKind.entered));
  }

  @override
  Future<void> stop() async {
    stopped++;
    if (stopFailure) throw StateError('fixture PiP teardown failure');
    _events.add(const PipEvent(PipEventKind.exited));
  }

  Future<void> close() => _events.close();
}

class _CountingSpeedMeter extends PlaybackSpeedMeter {
  int requests = 0;
  @override
  Future<void> measure(
    Uri uri, {
    Map<String, String>? headers,
    bool force = false,
  }) async {
    requests++;
  }
}
