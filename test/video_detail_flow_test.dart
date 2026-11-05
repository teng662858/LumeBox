import 'package:lume_box/core/player/playback_diagnostics.dart';
import 'package:lume_box/features/video/video_resume_match.dart';
import 'package:lume_box/features/video/detail_poster_background.dart';
import 'package:lume_box/core/intro/intro_store.dart';
import 'package:lume_box/core/media/media_library.dart';

import 'dart:io';
import 'dart:async';

import 'package:lume_box/core/net/network_queue.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/reading/comic_image_tools.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lume_box/shared/widgets/source_translation.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_detail_page.dart';
import 'package:lume_box/features/video/direct_video_source.dart';
import 'package:lume_box/features/video/video_play_target.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

class DetailSource extends FakeReadingDataSource {
  DetailSource() : super(section: Section.video);
  int parses = 0;
  bool failParse = false;
  String extension = 'mp4';
  bool failDetail = false;
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(
    items: [SourceItem(id: 'movie', title: '详情测试片')],
    hasMore: false,
  );
  @override
  Future<SourceDetail?> detail(String id) async {
    if (failDetail) {
      throw const SourceException(SourceErrorKind.callFailed, 'fixture没有详情接口');
    }
    return SourceDetail(
      mediaType: 'video',
      id: id,
      title: '详情测试片',
      description: '源站原始简介',
    );
  }

  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'e1', title: '第1集'),
    SourceChapter(id: 'e2', title: '第2集'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    parses++;
    if (failParse) {
      throw const SourceException(SourceErrorKind.network, 'fixture解析失败');
    }
    return VideoContent(
      url: Uri.parse('https://example.test/$chapterId.$extension'),
      headers: const {'Referer': 'https://source.test/watch'},
    );
  }
}

class NetdiskDiagnosticSource extends DetailSource {
  static const diagnostic =
      '2 个网盘 · 夸克A OK（匿名 video_preview，无 Cookie，仅 120 秒预览，HTTP 200） / 百度A OK';
  @override
  Future<SourceDetail?> detail(String id) async => SourceDetail(
    id: id,
    title: '网盘演示',
    subtitle: diagnostic,
    description: '剧集简介',
  );
}

class MultiLineDetailSource extends DetailSource {
  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'a1', title: '第1集', line: '线路A'),
    SourceChapter(id: 'a2', title: '第2集', line: '线路A'),
    SourceChapter(id: 'b1', title: '线路B · 第1集'),
    SourceChapter(id: 'b2', title: '线路B · 第2集'),
  ];
}

class NumericDetailSource extends DetailSource {
  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'e1', title: '01'),
    SourceChapter(id: 'e2', title: '02'),
    SourceChapter(id: 'e3', title: '03'),
  ];
}

class LongDetailSource extends DetailSource {
  @override
  Future<List<SourceChapter>> chapters(String id) async => [
    for (var i = 1; i <= 230; i++) SourceChapter(id: 'e$i', title: '第$i集'),
  ];
}

class RoutePlayer extends AbstractPlayer {
  Completer<void>? loadGate;
  int loads = 0;
  final state = ValueNotifier(const PlayerSnapshot());
  final information = ValueNotifier(
    const PlayerStats(width: 1920, height: 1080),
  );
  PlayerMedia? media;
  final seeks = <Duration>[];
  @override
  ValueListenable<PlayerSnapshot> get snapshot => state;
  @override
  ValueListenable<PlayerStats> get stats => information;
  @override
  Future<void> load(PlayerMedia value) async {
    media = value;
    loads++;
    await loadGate?.future;
  }

  @override
  Future<void> play() async {
    state.value = const PlayerSnapshot(playing: true);
  }

  @override
  Future<void> pause() async {
    state.value = const PlayerSnapshot();
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> applySettings(PlayerSettings value) async {}
  @override
  Widget buildView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose() async {}
}

class RouteCatalog implements PlayerKernelCatalog {
  const RouteCatalog();
  @override
  bool isAvailable(PlayerKernel kernel) => kernel == PlayerKernel.avplayer;
  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : 'fixture unavailable';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late DetailSource source;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-detail');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
    await MediaLibrary.instance.boot();
    await IntroStore.open();
    library.setSetting(
      VideoPlayerSettingsStore.keyBackgroundSourceValidation,
      'false',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => {'known': true, 'audio': true, 'video': true},
        );
    source = DetailSource();
  });
  tearDown(() async {
    await IntroStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });

  for (final compact in [false, true]) {
    testWidgets('下载图标紧邻翻译，点击直接选集：compact=$compact', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            source: source,
            item: const SourceItem(id: 'movie', title: '详情测试片'),
            library: library,
            onPlay: (_, _, _, _) async => fail('下载入口不应播放视频'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(VideoDetailPage)) as dynamic;
      state.setDetailStyle(!compact);
      await tester.pumpAndSettle();
      final download = find.byKey(const Key('video-detail-download'));
      await tester.ensureVisible(download);
      await tester.pumpAndSettle();
      final translation = find.byKey(const Key('video-detail-translation'));
      expect(
        tester.getCenter(download).dx,
        greaterThan(tester.getCenter(translation).dx),
      );
      expect(
        (tester.getCenter(download).dy - tester.getCenter(translation).dy)
            .abs(),
        lessThan(1),
      );
      if (compact) {
        final sort = find.byTooltip('倒序排列');
        expect(
          tester.getCenter(sort).dx,
          greaterThan(tester.getCenter(download).dx),
        );
        expect(
          (tester.getCenter(sort).dy - tester.getCenter(download).dy).abs(),
          lessThan(1),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(find.text('选择下载章节 / 剧集'), findsOneWidget);
      expect(find.text('第1集'), findsWidgets);
      expect(find.text('第2集'), findsWidgets);
      expect(source.parses, 0);
    });
  }

  for (final extension in ['mp4', 'm3u8']) {
    testWidgets('$extension 起播不等待额外音轨探测', (tester) async {
      source.extension = extension;
      var probes = 0, opened = 0;
      final gate = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/mediaTracks'),
            (call) async {
              if (call.method != 'inspect') return null;
              probes++;
              return gate.future;
            },
          );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            source: source,
            item: SourceItem(id: 'fast-$extension', title: '详情测试片'),
            library: library,
            onPlay: (media, target, qualities, prelaunch) async {
              opened++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      try {
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('video-detail-play')));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        expect(opened, 1);
        expect(probes, 0);
        expect(source.parses, 1);
        final timing = PlaybackDiagnostics.snapshot.lastWhere(
          (e) => e['stage'] == 'source-resolve-complete',
        );
        expect(timing['source'], source.id);
        expect(timing['elapsedMs'], isA<int>());
      } finally {
        gate.complete({'known': true, 'video': true, 'audio': true});
      }
    });
  }

  testWidgets('换源选择对应剧集，并把时间点写入目标源进度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoPlayTarget? played;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'resume-new', title: '详情测试片'),
          library: library,
          resumeRequest: const VideoResumeRequest(
            title: '详情测试片',
            chapterTitle: '第2集',
            chapterIndex: 1,
            position: Duration(seconds: 75),
            duration: Duration(minutes: 40),
          ),
          onPlay: (_, target, _, _) async {
            played = target;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.selected, 1);
    expect(state.lineResume.position, const Duration(seconds: 75));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('video-detail-play')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(played?.chapterId, 'e2');
    expect(
      library.videoProgress('resume-new', sourceId: source.id)?.position,
      const Duration(seconds: 75),
    );
  });
  testWidgets('换源存在多个相同集号时先确认，未选择前不解析播放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final multi = MultiLineDetailSource();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: multi,
          item: const SourceItem(id: 'ambiguous', title: '详情测试片'),
          library: library,
          resumeRequest: const VideoResumeRequest(
            title: '详情测试片',
            chapterTitle: '第1集',
            chapterIndex: 0,
            position: Duration(seconds: 60),
            duration: Duration.zero,
          ),
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('确认续播剧集'), findsOneWidget);
    expect(multi.parses, 0);
    await tester.tap(find.text('线路B · 第1集'));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.currentLine, '线路B');
    expect(state.lineResume.position, const Duration(seconds: 60));
  });

  testWidgets('换源续播未选剧集时明确提示，不转移进度或自动播放', (tester) async {
    final multi = MultiLineDetailSource();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: multi,
          item: const SourceItem(id: 'resume-cancel', title: '详情测试片'),
          library: library,
          resumeRequest: const VideoResumeRequest(
            title: '详情测试片',
            chapterTitle: '第1集',
            chapterIndex: 0,
            position: Duration(seconds: 60),
            duration: Duration.zero,
          ),
          onPlay: (_, _, _, _) async => fail('未选择剧集不能自动播放'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('确认续播剧集'), findsOneWidget);
    Navigator.of(tester.element(find.text('确认续播剧集'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('未选择对应剧集，请手动选集后播放；原进度未转移'), findsOneWidget);
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.lineResume, isNull);
    expect(multi.parses, 0);
  });

  testWidgets('沉浸详情的TMDB小标和评分放在类型旁，不挤占年份行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'brand', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    state.tmdb.metadata = const TmdbMetadata(
      overview: '',
      posters: [],
      rating: 8.7,
      year: '2026',
      genres: ['剧情', '喜剧'],
    );
    state.tmdb.notifyListeners();
    await tester.pumpAndSettle();
    final badge = find.byKey(const Key('video-detail-tmdb-status'));
    expect(badge, findsOneWidget);
    expect(find.text('8.7'), findsOneWidget);
    expect(find.textContaining('★ 8.7'), findsNothing);
    expect(find.byIcon(Icons.verified_outlined), findsNothing);
    final genres = find.byKey(const Key('video-detail-genres'));
    expect(tester.getCenter(badge).dy, closeTo(tester.getCenter(genres).dy, 1));
    expect(
      tester.getTopLeft(badge).dx,
      greaterThan(tester.getTopRight(genres).dx),
    );
    expect(
      tester.getBottomLeft(badge).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const Key('video-detail-play'))).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部超分范围开启且海报仍在处理中，详情选集和播放不等待超分', (tester) async {
    final started = Completer<void>(), finish = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ComicImageTools.debugAutomaticSupported = true;
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'superResolve') {
        if (!started.isCompleted) started.complete();
        await finish.future;
        return (call.arguments as Map)['bytes'];
      }
      return null;
    });
    final tools = ComicImageTools(
      settings: ComicImageToolsSettings()
        ..automatic = true
        ..upscaleCovers = true
        ..upscaleVideoPosters = true
        ..concurrency = 1,
    );
    final png = img.encodePng(
      img.Image(width: 4, height: 8)..setPixelRgb(0, 0, 30, 150, 200),
    );
    final pipeline = SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      diskCache: false,
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: png,
        headers: const {'content-type': 'image/png'},
      ),
      decodeTransform: (bytes) =>
          tools.automatic(bytes, surface: UpscaleSurface.videoPoster),
    );
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
      tools.dispose();
      pipeline.dispose();
      ComicImageTools.debugAutomaticSupported = null;
      messenger.setMockMethodCallHandler(ComicImageTools.channel, null);
    });
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(
            id: 'movie',
            title: '详情测试片',
            cover: 'https://fixture.example/poster.png',
          ),
          library: library,
          imagePipeline: pipeline,
          onPlay: (_, _, _, _) async {
            opened++;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => started.future.timeout(const Duration(seconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.loading, false);
    expect(state.chapters, hasLength(2));
    expect(source.parses, 0);
    final play = find.byKey(const Key('video-detail-play'));
    await tester.ensureVisible(play);
    await tester.runAsync(() async {
      await tester.tap(play);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(opened, 1, reason: '不能等待海报超分完成才能播放');
    expect(source.parses, 1);
    expect(finish.isCompleted, false);
    finish.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('网页47集详情保留目录并从网页选中的第12集开始播放', (tester) async {
    final web = DirectVideoSource(
      id: 'web',
      name: '独狼影视聚合',
      title: '兰香如故',
      uri: Uri.parse('https://fixture.invalid/12.m3u8'),
      selected: 11,
      episodes: List.generate(
        47,
        (i) => SourceChapter(id: 'e$i', title: '第${i + 1}集'),
      ),
    );
    VideoPlayTarget? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: web,
          item: const SourceItem(id: 'drama47', title: '兰香如故'),
          initialChapterId: 'e11',
          library: library,
          recordHistory: false,
          onPlay: (_, target, _, _) async => opened = target,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.chapters, hasLength(47));
    expect(state.selected, 11);
    final play = find.byKey(const Key('video-detail-play'));
    await tester.ensureVisible(play);
    await tester.runAsync(() async {
      await tester.tap(play);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(opened!.chapterId, 'e11');
    expect(opened!.chapterIndex, 11);
  });
  testWidgets('网盘诊断不占据标题资料，限制保留且完整详情可以展开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: NetdiskDiagnosticSource(),
          item: const SourceItem(id: 'netdisk', title: '网盘演示'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    const summary = '2 个网盘 · 可用 2 集 · 含 120 秒预览线路';
    expect(find.text(summary), findsOneWidget);
    expect(find.textContaining('HTTP 200'), findsNothing);
    await tester.tap(find.byKey(const Key('video-detail-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网盘资源详情'));
    await tester.pumpAndSettle();
    expect(find.text(NetdiskDiagnosticSource.diagnostic), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    state.setDetailStyle(false);
    await tester.pumpAndSettle();
    expect(find.text(summary), findsOneWidget);
    expect(find.textContaining('HTTP 200'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('线路切换不预解析，数字选集只播放所选线路并保持索引', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = MultiLineDetailSource();
    VideoPlayTarget? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, target, _, _) async => opened = target,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('video-detail-original-line-selector')),
      findsOneWidget,
    );
    expect(find.text('选集 · 共 2 集'), findsNothing);
    expect(
      tester
          .widget<SourceText>(
            find.descendant(
              of: find.byKey(const Key('video-detail-summary')),
              matching: find.byType(SourceText),
            ),
          )
          .maxLines,
      2,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('video-detail-summary'))).dy,
      greaterThan(
        tester.getBottomLeft(find.byKey(const Key('video-detail-play'))).dy,
      ),
    );
    expect(find.text('线路A'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('video-detail-play'))).width,
      closeTo((440 - 32) * .82, 2),
    );
    expect(find.byKey(const Key('video-detail-quick-actions')), findsNothing);
    expect(find.byKey(const Key('video-detail-favorite')), findsOneWidget);
    expect(find.text('展开'), findsNothing);
    expect(find.text('全站找片'), findsNothing);
    expect(source.parses, 0);
    await tester.ensureVisible(
      find.byKey(const Key('video-detail-original-line-selector')),
    );
    await tester.tap(
      find.byKey(const Key('video-detail-original-line-selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路B · 2 集').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-detail-more')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('紧凑版（当前版）'));
    await tester.tap(
      find.ancestor(
        of: find.text('紧凑版（当前版）'),
        matching: find.byType(CheckedPopupMenuItem<String>),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('video-compact-line-selector')),
      findsOneWidget,
      reason: '紧凑版将线路选择放在选集标题旁',
    );
    await tester.ensureVisible(
      find.byKey(const Key('video-compact-line-selector')),
    );
    await tester.tap(find.byKey(const Key('video-compact-line-selector')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-compact-line-线路A')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('video-compact-line-线路B')));
    await tester.pumpAndSettle();
    expect(source.parses, 0, reason: '悬浮选择线路不会提前解析播放');
    expect(
      find.byKey(const Key('video-detail-tmdb-status')),
      findsOneWidget,
      reason: '未匹配时保留配置和手动匹配入口',
    );
    expect(find.byKey(const Key('video-detail-metadata-row')), findsOneWidget);
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    state.tmdb.metadata = const TmdbMetadata(
      overview: '',
      posters: [],
      cast: ['示例演员'],
      year: '2026',
      genres: ['剧情'],

      recommendations: [TmdbRecommendation(title: '推荐示例', poster: '')],
    );
    state.tmdb.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-detail-tmdb-status')), findsOneWidget);
    expect(find.text('示例演员'), findsOneWidget);
    final castTitle = tester.getRect(
      find.byKey(const Key('video-detail-cast-title')),
    );
    final avatar = tester.getRect(
      find.byKey(const ValueKey('video-detail-cast-avatar-0')),
    );
    expect(avatar.width, 48);
    expect(avatar.left, greaterThan(castTitle.right));
    expect(avatar.center.dy, closeTo(castTitle.center.dy, .1));
    expect(find.text('TMDB · 已匹配'), findsOneWidget);
    expect(find.textContaining('2026 · 剧情'), findsOneWidget);
    expect(find.text('相似影片 · 全站找片'), findsNothing);
    expect(find.text('推荐示例'), findsNothing);
    expect(source.parses, 0);
    final second = find.byKey(const ValueKey('video-detail-episode-1'));
    await tester.ensureVisible(second);
    await tester.runAsync(() async {
      await tester.tap(second);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(opened?.chapterId, 'b2');
    expect(opened?.chapterIndex, 1);
    expect(opened?.chapterTitle, '第2集');
    expect(source.parses, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('紧凑版大海报居中标题，五至六列数字选集按十集切换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    library.setSetting('video.detail.originalStyle', 'false');
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie',
        chapterIndex: 1,
        chapterId: 'e2',
        chapterTitle: '第2集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 12, seconds: 36),
        duration: const Duration(minutes: 40),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: LongDetailSource(),
          item: const SourceItem(
            id: 'movie',
            title: '详情测试片',
            cover: 'https://fixture.test/poster.jpg',
          ),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const Key('video-detail-compact-banner')))
          .height,
      closeTo(576.4, .1),
    );
    final play = find.byKey(const Key('video-detail-play'));
    final progress = find.byKey(const Key('video-detail-compact-progress'));
    expect(
      tester.getTopLeft(progress).dy,
      greaterThan(tester.getBottomRight(play).dy),
    );
    expect(
      find.byKey(const ValueKey('video-detail-episode-9')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('video-detail-episode-10')), findsNothing);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('video-detail-episode-5')))
          .dy,
      closeTo(
        tester
            .getTopLeft(find.byKey(const ValueKey('video-detail-episode-0')))
            .dy,
        .1,
      ),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('video-detail-episode-6')))
          .dy,
      greaterThan(
        tester
            .getBottomLeft(find.byKey(const ValueKey('video-detail-episode-0')))
            .dy,
      ),
    );
    final range = find.byKey(const ValueKey('video-compact-range-10'));
    await tester.ensureVisible(range);
    await tester.tap(range);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-episode-10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-episode-19')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('video-detail-episode-0')), findsNothing);
    expect(find.byKey(const ValueKey('video-detail-episode-20')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(320, 900));
    await tester.pumpAndSettle();
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('video-detail-episode-14')))
          .dy,
      closeTo(
        tester
            .getTopLeft(find.byKey(const ValueKey('video-detail-episode-10')))
            .dy,
        .1,
      ),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('video-detail-episode-15')))
          .dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey('video-detail-episode-10')),
            )
            .dy,
      ),
    );
    expect(tester.takeException(), isNull);
    final dynamic detailState = tester.state(find.byType(VideoDetailPage));
    for (final original in [true, false, true]) {
      detailState.setDetailStyle(original);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '两版切换期间不得读取单一 scroll.position',
      );
      final view = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('video-detail-scroll')),
      );
      expect(view.controller!.positions.length, 1);
    }
  });

  testWidgets('隐藏空演员和重复入口，保留布局与逐集续播，缺集不自动换线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    library.setSetting('video.detail.originalStyle', 'false');
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie',
        chapterIndex: 1,
        chapterId: 'a2',
        chapterTitle: '第2集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 12, seconds: 36),
        duration: const Duration(minutes: 40),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: MultiLineDetailSource(),
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.originalStyle, false);
    expect(find.text('继续看 · 第2集'), findsOneWidget);
    expect(find.text('看到 12:36 / 40:00'), findsOneWidget);
    expect(find.text('演员'), findsNothing);
    expect(find.text('全部'), findsNothing);
    expect(find.text('追番'), findsNothing);
    expect(
      find.byKey(const ValueKey('video-episode-progress-1')),
      findsOneWidget,
    );
    state.lines['缺集线路'] = [const SourceChapter(id: 'c3', title: '第3集')];
    expect(state.changeLine('缺集线路'), false);
    await tester.pumpAndSettle();
    expect(state.currentLine, '线路A');
    expect(state.selected, 1);
    expect(find.text('该线路没有对应集，请在选集里手动选择'), findsOneWidget);
    expect(state.changeLine('线路B'), true);
    await tester.pumpAndSettle();
    expect(find.text('继续看 · 第2集'), findsOneWidget);
    expect(state.lineResume.position, const Duration(minutes: 12, seconds: 36));
  });

  testWidgets('列表选集不显示重复数字，每两集之间有可见分隔线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: NumericDetailSource(),
          item: const SourceItem(id: 'numeric', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.byKey(const Key('video-detail-select-episodes'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('列表显示').last);
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      final tile = tester.widget<ListTile>(
        find.byKey(ValueKey('video-detail-picker-episode-$i')),
      );
      expect(tile.subtitle, isNull);
    }
    final dividers = tester
        .widgetList<Divider>(find.byType(Divider))
        .where((d) => d.indent == 48 && d.endIndent == 24)
        .toList();
    expect(dividers, hasLength(2));
    final first = tester.getRect(
      find.byKey(const ValueKey('video-detail-picker-episode-0')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('video-detail-picker-episode-1')),
    );
    expect(first.height, 56);
    expect(second.top - first.top, 57);
    expect(dividers.every((d) => d.thickness == .5 && d.color!.a > .1), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选集移除搜索和跳集，定位按钮回到当前集', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = LongDetailSource();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'long', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    state.selected = 202;
    await tester.ensureVisible(
      find.byKey(const Key('video-detail-select-episodes')),
    );
    await tester.tap(find.byKey(const Key('video-detail-select-episodes')));
    await tester.pumpAndSettle();
    expect(find.text('搜索剧集名称'), findsNothing);
    expect(find.text('跳转到第几集'), findsNothing);
    await tester.tap(find.byTooltip('倒序排列').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('定位当前集').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-202')),
      findsOneWidget,
    );
    expect(source.parses, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器报错换线路仍播放同一集并恢复时间点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = MultiLineDetailSource();
    final manager = FakeSourceManager(
      sources: [
        SourceDescriptor(
          id: source.id,
          name: source.name,
          version: '1',
          enabled: true,
        ),
      ],
      opened: {source.id: source},
    );
    final player = RoutePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerPage(
          library: library,
          sourceManager: manager,
          playerFactory: (_) => player,
          catalog: const RouteCatalog(),
          media: PlayerMedia(uri: Uri.parse('https://example.test/a2.mp4')),
          target: VideoPlayTarget(
            sourceId: source.id,
            itemId: 'movie',
            title: '详情测试片',
            chapterIndex: 1,
            chapterId: 'a2',
            chapterTitle: '第2集',
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    player.state.value = const PlayerSnapshot(
      error: 'fixture连接失败',
      position: Duration(seconds: 75),
      duration: Duration(minutes: 40),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多恢复方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('换线路继续看'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路B'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(player.media!.uri.path, '/b2.mp4');
    expect(player.seeks, contains(const Duration(seconds: 75)));
    expect(source.parses, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('窄屏大字长剧集分页显示，选集弹层不一次构建全部按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: VideoDetailPage(
          source: LongDetailSource(),
          item: const SourceItem(id: 'long', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-detail-more')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('紧凑版（当前版）'));
    await tester.tap(
      find.ancestor(
        of: find.text('紧凑版（当前版）'),
        matching: find.byType(CheckedPopupMenuItem<String>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton).evaluate().length, lessThan(55));
    expect(
      find.byKey(const ValueKey('video-detail-episode-5')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-episode-9')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('video-detail-episode-10')), findsNothing);
    final picker = find.byKey(const Key('video-detail-select-episodes'));
    await Scrollable.ensureVisible(tester.element(picker), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-50')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('方向预检等待受限，先进入播放页，尺寸返回后复用同一实例横屏播放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final entryDirections = <List<dynamic>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        entryDirections.add(call.arguments as List<dynamic>);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final players = <RoutePlayer>[];
    final loadGate = Completer<void>();
    addTearDown(() {
      if (!loadGate.isCompleted) loadGate.complete();
    });
    final manager = FakeSourceManager(
      sources: [
        SourceDescriptor(
          id: source.id,
          name: source.name,
          version: '1',
          enabled: true,
        ),
      ],
      opened: {source.id: source},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPage(
          library: library,
          sourceManager: manager,
          catalog: const RouteCatalog(),
          playerFactory: (_) {
            final player = RoutePlayer()..loadGate = loadGate;
            players.add(player);
            return player;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情测试片'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.text('源站原始简介'), findsOneWidget);
    expect(players, isEmpty);
    expect(source.parses, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-detail-episode-1')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('video-detail-episode-1')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(
      find.byType(VideoPlayerPage),
      findsOneWidget,
      reason: '不在详情页等待慢媒体加载，播放页接手同一项预备任务',
    );
    expect(loadGate.isCompleted, isFalse);
    loadGate.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(entryDirections.first, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(players.single.loads, 1, reason: '进入播放页只加载一次媒体');
    expect(source.parses, 1);
    expect(players.length, 1);
    expect(players.single.media?.uri.path, '/e2.mp4');
    expect(
      players.single.media?.headers?['Referer'],
      'https://source.test/watch',
    );
    expect(find.byKey(const Key('fullscreen-controls')), findsOneWidget);
    expect(find.byKey(VideoPlayerPage.controlPanelKey), findsNothing);
    final instance = tester.state(find.byType(VideoPlayerPage));
    players.single.information.value = const PlayerStats(
      width: 1920,
      height: 1080,
    );
    await tester.binding.setSurfaceSize(const Size(900, 400));
    await tester.pumpAndSettle();
    expect(
      identical(instance, tester.state(find.byType(VideoPlayerPage))),
      isTrue,
    );
    expect(players.length, 1);
    expect(source.parses, 1);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('退出全屏'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.byType(VideoPlayerPage), findsNothing);
  });
  testWidgets('当前剧集封面显示用户主题色边框，切集后边框跟随', (tester) async {
    const accent = Colors.tealAccent;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: accent)
              .copyWith(primary: accent),
        ),
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('video-detail-episode-border-0'));
    expect(first, findsOneWidget);
    final decoration =
        tester.widget<DecoratedBox>(first).decoration as BoxDecoration;
    expect((decoration.border! as Border).top.color, accent);
    final second = find.byKey(const ValueKey('video-detail-episode-1'));
    await tester.ensureVisible(second);
    await tester.runAsync(() async {
      await tester.tap(second);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(first, findsNothing);
    expect(
      find.byKey(const ValueKey('video-detail-episode-border-1')),
      findsOneWidget,
    );
  });

  testWidgets('详情实际取色保留海报下部暗红，不被大片灰蓝背景冲淡', (tester) async {
    final settings = TmdbSettings.instance;
    final oldEnabled = settings.enabled;
    final oldBackdrop = settings.detailBackdropEnabled;
    settings.enabled = false;
    settings.detailBackdropEnabled = true;
    addTearDown(() {
      settings.enabled = oldEnabled;
      settings.detailBackdropEnabled = oldBackdrop;
    });
    final poster = img.Image(width: 24, height: 32);
    for (var y = 0; y < poster.height; y++) {
      for (var x = 0; x < poster.width; x++) {
        if (y < 22) {
          poster.setPixelRgb(x, y, 140, 152, 175);
        } else {
          poster.setPixelRgb(x, y, 160, 40, 45);
        }
      }
    }
    final png = img.encodePng(poster);
    final pipeline = SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      diskCache: false,
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: png,
        headers: const {'content-type': 'image/png'},
      ),
    );
    addTearDown(pipeline.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(
            id: 'poster-hue-regression',
            title: '详情测试片',
            cover: 'https://fixture.example/lower-red-poster.png',
          ),
          library: library,
          imagePipeline: pipeline,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final background = tester
        .widget<ColoredBox>(
          find.byKey(const Key('video-detail-poster-color-background')),
        )
        .color;
    expect(
      find.byKey(const Key('video-detail-surface-gradient')),
      findsOneWidget,
    );
    final tone = HSVColor.fromColor(background);
    expect(tone.hue < 15 || tone.hue > 345, isTrue);
    expect(tone.saturation, greaterThan(.5));
    expect(tone.value, lessThan(.4));
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      background,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('详情使用同一海报色相渐变，不叠加另一张横版图，开关可关闭', (tester) async {
    final settings = TmdbSettings.instance;
    final oldEnabled = settings.enabled;
    final oldBackdrop = settings.detailBackdropEnabled;
    addTearDown(() {
      settings.enabled = oldEnabled;
      settings.detailBackdropEnabled = oldBackdrop;
    });
    settings.detailBackdropEnabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    settings.enabled = true;
    state.setState(() {
      state.tmdb.metadata = const TmdbMetadata(
        overview: '',
        posters: [],
        backdrops: ['https://preview.invalid/backdrop.jpg'],
      );
    });
    await tester.pumpAndSettle();
    final background = find.byKey(
      const Key('video-detail-poster-color-background'),
    );
    expect(find.byType(DetailPosterBackground), findsNothing);
    expect(
      tester.widget<ColoredBox>(background).color,
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
    );
    state.setState(() {
      state.tmdb.metadata = const TmdbMetadata(overview: '', posters: []);
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<ColoredBox>(background).color,
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
    );
    settings.detailBackdropEnabled = false;
    state.setState(() {});
    await tester.pumpAndSettle();
    expect(find.byType(DetailPosterBackground), findsNothing);
    expect(background, findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xff11131a),
    );
  });

  testWidgets('源未实现详情接口仍保留剧集和显式播放流程', (tester) async {
    source.failDetail = true;
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(
            id: 'movie',
            title: '详情测试片',
            mediaType: 'video',
          ),
          library: library,
          onPlay: (_, _, _, _) async {
            opened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无简介'), findsOneWidget);
    expect(find.byKey(const Key('video-detail-immersive')), findsOneWidget);
    expect(find.byKey(const Key('video-detail-gradient')), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.black,
    );
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(source.parses, 0);
    await tester.ensureVisible(find.byKey(const Key('video-detail-play')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('video-detail-play')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(source.parses, 1);
  });
  testWidgets('冷源加载失败也保留详情，不跳转播放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          loadSource: () async => throw const SourceException(
            SourceErrorKind.callFailed,
            'fixture源加载失败',
          ),
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {
            fail('不应打开播放器');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.textContaining('fixture源加载失败'), findsWidgets);
    expect(find.byType(VideoPlayerPage), findsNothing);
  });

  testWidgets('解析失败留在详情并提示，不调用打开播放器回调', (tester) async {
    source.failParse = true;
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {
            opened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-detail-episode-1')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('video-detail-episode-1')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(source.parses, 1);
    await tester.ensureVisible(find.byKey(const Key('video-detail-play')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('video-detail-play')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.textContaining('解析失败：'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('video-detail-play')))
          .onPressed,
      isNotNull,
    );
  });
}
