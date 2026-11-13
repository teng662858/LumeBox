import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/video/video_detail_page.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/media/playback_focus.dart';
import 'package:lume_box/core/intro/intro_store.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_play_target.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_download_center.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

import 'support/fake_source_manager.dart';

/// 视频板块首页 = 当前图源的内容展示页（用户要求把图源展示页放到板块首页）。
///
/// 验证：首页列出本板块当前图源的列表；点条目**直接起播**——条目自带地址
/// （视频类脚本常见的 `{title, url}`）直接放，否则走「剧集 → 内容」链路；
/// 没有可用图源时给出导入引导。
///
/// 起播的落点是**独立播放器页**（[VideoPlayerPage]）：视频板块只有【浏览】
/// 一个页签，条目点击不再切页签（真机反馈的改造）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const video = Section.video;

  late Directory root;
  late _VideoSource source;
  late FakeSourceManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_video_home');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    // 视频板块的设置库在真实时钟里先打开：testWidgets 的 fake-async 里等不到真实异步。
    await MediaLibrary.instance.boot();
    await IntroStore.open();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => {'known': true, 'audio': true, 'video': true},
        );
    final library = await ReadingLibrary.open(video);
    // These routing fixtures use fake media, so they must not start real probes.
    library.setSetting(
      VideoPlayerSettingsStore.keyBackgroundSourceValidation,
      'false',
    );
    library.setSetting(VideoPlayerSettingsStore.keyControlStyle, 'text');
    source = _VideoSource();
    manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'demo-video',
          name: '公开样片测试源',
          version: '1.0.0',
          enabled: true,
        ),
      ],
      opened: <String, DataSource>{'demo-video': source},
    );
  });

  tearDown(() async {
    await IntroStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<List<_FakePlayer>> pumpBoard(WidgetTester tester) async {
    final created = <_FakePlayer>[];
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPage(
          catalog: const _FakeCatalog(<PlayerKernel>{PlayerKernel.avplayer}),
          playerFactory: (kernel) {
            final player = _FakePlayer(kernel);
            created.add(player);
            return player;
          },
          sourceManager: manager,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    return created;
  }

  testWidgets('历史记录优先打开已下载文件，不请求源详情和播放地址', (tester) async {
    final library = ReadingLibrary.find(video)!;
    library.recordHistoryItem(
      sourceId: 'demo-video',
      itemId: 'offline',
      title: '离线影片',
    );
    final progress = VideoProgress(
      section: video,
      sourceId: 'demo-video',
      itemId: 'offline',
      chapterId: 'e3',
      chapterIndex: 2,
      chapterTitle: '第3集',
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 2),
      updatedAt: DateTime.now(),
    );
    library.saveProgress(progress);
    final downloads = VideoDownloadCenter.instance;
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('demo-video', 'offline', 'e3'),
      sourceId: 'demo-video',
      itemId: 'offline',
      chapterId: 'e3',
      title: '离线影片',
      chapterTitle: '第3集',
      chapterIndex: 2,
      state: 'done',
      fileName: 'movie.mp4',
    );
    await tester.runAsync(() async {
      await downloads.boot();
      downloads.tasks.add(task);
      await Directory(downloads.folder(task)).create(recursive: true);
      await downloads.localFile(task).writeAsBytes([1, 2, 3]);
    });
    addTearDown(() => downloads.tasks.remove(task));
    await pumpBoard(tester);
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    final history = tester.widget<ReadingHistorySheet>(
      find.byType(ReadingHistorySheet),
    );
    history.onResume(library.history().single, progress);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsOneWidget);
    expect(
      tester.widget<VideoPlayerPage>(find.byType(VideoPlayerPage)).media?.uri,
      downloads.localFile(task).uri,
    );
    expect(source.chapterCalls, isEmpty);
    expect(source.contentCalls, isEmpty);
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .target
          ?.chapterId,
      'e3',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('首页就是图源展示页：列表直接可见，播放器不占首页', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'https://example.com/demo.mp4', title: '测试视频'),
    ];
    await pumpBoard(tester);

    // 首页（第一个页签）显示当前图源与条目。
    expect(find.text('公开样片测试源'), findsOneWidget);
    expect(find.text('测试视频'), findsOneWidget);
    expect(find.text('视频地址或本地路径'), findsNothing, reason: '播放器的地址栏不该占着首页');
    // Playback controls now belong to UIKit and are exercised by the native
    // integration suite. This source-flow test stops at the media handoff.
  });

  testWidgets('等待其他音频释放焦点时离开详情不会再打开播放器', (tester) async {
    source.items = const [SourceItem(id: 'https://example.com/movie.mp4', title: '等待焦点')];
    await pumpBoard(tester);
    await tester.tap(find.text('等待焦点'));
    await tester.pumpAndSettle();
    final detail = find.byType(VideoDetailPage);
    final pending = Completer<void>();
    var releasing = false;
    Future<void> release() {
      releasing = true;
      return pending.future;
    }
    await PlaybackFocus.acquire('test-audio', onRelease: release);
    try {
      final page = tester.widget<VideoDetailPage>(detail);
      const target = VideoPlayTarget(sourceId: 'demo-video', itemId: 'movie', title: '等待焦点',
        chapterIndex: 0, chapterId: 'movie', chapterTitle: '正片');
      unawaited(page.onPlay(PlayerMedia(uri: Uri.parse('https://example.com/movie.mp4')), target, [], null));
      await tester.pump();
      expect(releasing, isTrue);
      Navigator.of(tester.element(detail)).pop();
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(VideoPlayerPage), findsNothing);
      expect(PlaybackFocus.owner, 'test-audio');
    } finally {
      if (!pending.isCompleted) pending.complete();
      PlaybackFocus.unregister('test-audio', release);
    }
  });

  testWidgets('条目没有地址：走剧集链路，选一集后起播取到的视频地址', (tester) async {
    source.items = const <SourceItem>[SourceItem(id: 'movie-1', title: '示例影片')];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
      SourceChapter(id: 'movie-1-e2', title: '第 2 集'),
    ];
    source.contentUrl = 'https://example.com/movie-1-e2.mp4';
    await pumpBoard(tester);

    await tapWithDetailPlay(tester, find.text('示例影片'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    // 多集先让用户选。
    expect(
      find.byKey(const ValueKey('video-detail-episode-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-episode-1')),
      findsOneWidget,
    );
    await tapWithDetailPlay(tester, find.text('第 2 集'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media
          ?.uri
          .toString(),
      'https://example.com/movie-1-e2.mp4',
    );
    expect(source.contentCalls, [
      ('movie-1', 'movie-1-e1'),
      ('movie-1', 'movie-1-e2'),
    ], reason: '先探测首集内容类型，再解析用户选择的第二集，各一次');
  });

  testWidgets('站内路径 id（/watch?v=…）不能当成本地文件：走剧集 + 内容取地址（真机 -17913 回归）', (
    tester,
  ) async {
    // 真机：H動漫網 / Hanime1 的条目 id 是站内路径（`/9434719.html`、`/watch?v=…`），
    // 早先被 `directAddress` 判成本地文件 → 起播打开一个不存在的 file://，
    // AVPlayer 报「未知错误 -17913」且日志里地址域名是空的。
    source.items = const <SourceItem>[
      SourceItem(id: '/watch?v=123', title: '樣片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: '/watch?v=123', title: '播放'),
    ];
    source.contentUrl = 'https://hanime1.me/download/123.mp4';
    source.contentHeaders = const <String, String>{
      'User-Agent': 'src-ua',
      'Referer': 'https://hanime1.me/watch?v=123',
    };
    await pumpBoard(tester);

    await tapWithDetailPlay(tester, find.text('樣片'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(source.chapterCalls, isNotEmpty, reason: '站内路径要先问剧集');
    expect(source.contentCalls, isNotEmpty, reason: '再取这一集的播放地址');
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .uri
          .toString(),
      'https://hanime1.me/download/123.mp4',
    );
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .uri
          .scheme,
      'https',
    );
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .headers?['Referer'],
      'https://hanime1.me/watch?v=123',
      reason: '图源给的防盗链头必须一起交给内核',
    );
  });

  testWidgets('完整 watch 网页地址必须解析 content，不能直接当媒体播放', (tester) async {
    // 真机：H動漫網 / Hanime1 的条目 id 是站内路径（`/9434719.html`、`/watch?v=…`），
    // 早先被 `directAddress` 判成本地文件 → 起播打开一个不存在的 file://，
    // AVPlayer 报「未知错误 -17913」且日志里地址域名是空的。
    source.items = const <SourceItem>[
      SourceItem(id: 'https://hanime1.me/watch?v=123', title: '樣片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'https://hanime1.me/watch?v=123', title: '播放'),
    ];
    source.contentUrl = 'https://hanime1.me/download/123.mp4';
    source.contentHeaders = const <String, String>{
      'User-Agent': 'src-ua',
      'Referer': 'https://hanime1.me/watch?v=123',
    };
    await pumpBoard(tester);

    await tapWithDetailPlay(tester, find.text('樣片'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(source.chapterCalls, isNotEmpty, reason: '站内路径要先问剧集');
    expect(source.contentCalls, isNotEmpty, reason: '再取这一集的播放地址');
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .uri
          .toString(),
      'https://hanime1.me/download/123.mp4',
    );
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .uri
          .scheme,
      'https',
    );
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media!
          .headers?['Referer'],
      'https://hanime1.me/watch?v=123',
      reason: '图源给的防盗链头必须一起交给内核',
    );
  });

  testWidgets('只有一集时不弹选择面板', (tester) async {
    source.items = const <SourceItem>[SourceItem(id: 'movie-1', title: '示例影片')];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/movie-1-e1.mp4';
    await pumpBoard(tester);

    await tapWithDetailPlay(tester, find.text('示例影片'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(find.text('选择剧集'), findsNothing);
    expect(
      tester
          .widget<VideoPlayerPage>(find.byType(VideoPlayerPage))
          .media
          ?.uri
          .toString(),
      'https://example.com/movie-1-e1.mp4',
    );
  });

  testWidgets('脚本没实现剧集：如实提示缺哪个函数，不静默失败', (tester) async {
    source.items = const <SourceItem>[SourceItem(id: 'movie-1', title: '示例影片')];
    source.chaptersFailure = const SourceException(
      SourceErrorKind.callFailed,
      '源脚本没有实现 chapters 方法：请定义顶层函数 getChapters',
    );
    final created = await pumpBoard(tester);

    await tapWithDetailPlay(tester, find.text('示例影片'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();

    expect(created, isEmpty, reason: '没有可播放地址就不该起播');
    expect(find.byType(VideoPlayerPage), findsNothing, reason: '不往下走，也不唤起播放器页');
    expect(
      find.textContaining('没有实现 chapters 方法'),
      findsWidgets,
      reason: '提示要能指出脚本缺什么',
    );
  });

  testWidgets('板块内没有可用图源：首页给导入引导', (tester) async {
    manager = FakeSourceManager();
    await pumpBoard(tester);

    expect(find.text('暂无源'), findsOneWidget);
    expect(find.text('源管理'), findsOneWidget, reason: '给一个去导入的按钮');
    // 顶部**没有页签条**了（用户口径：删掉「浏览」，内容直接顶上去，对齐猫源板块）。
    expect(find.byType(Tab), findsNothing);
    expect(find.widgetWithText(Tab, '播放'), findsNothing);
    expect(find.text('视频地址或本地路径'), findsNothing, reason: '地址栏在播放器页里');
  });
}

/// 视频图源替身：列表 / 剧集 / 内容都按用例配置，不碰沙箱与网络。
class _VideoSource implements DataSource {
  @override
  final Section section = Section.video;

  @override
  String get id => 'demo-video';

  @override
  String get name => '公开样片测试源';

  List<SourceItem> items = const <SourceItem>[];
  List<SourceChapter> chapterList = const <SourceChapter>[];

  /// 非空时 chapters() 抛它（模拟脚本没实现剧集）。
  SourceException? chaptersFailure;

  String contentUrl = 'https://example.com/chapter.mp4';

  /// 图源给的播放请求头（防盗链）；默认空。
  Map<String, String> contentHeaders = const <String, String>{};

  final List<String> chapterCalls = <String>[];
  final List<(String, String)> contentCalls = <(String, String)>[];

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => SourceList(items: items, hasMore: false);

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    chapterCalls.add(itemId);
    final failure = chaptersFailure;
    if (failure != null) throw failure;
    return chapterList;
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    contentCalls.add((itemId, chapterId));
    return VideoContent(url: Uri.parse(contentUrl), headers: contentHeaders);
  }
}

/// 内核可用性目录替身：只让 AVPlayer 可用。
class _FakeCatalog implements PlayerKernelCatalog {
  const _FakeCatalog(this.available);

  final Set<PlayerKernel> available;

  @override
  bool isAvailable(PlayerKernel kernel) => available.contains(kernel);

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}

/// 播放器替身：只记录「加载了什么」，渲染面用一行文字代替。
class _FakePlayer extends AbstractPlayer {
  _FakePlayer(this.kernel);

  final PlayerKernel kernel;

  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(),
  );

  PlayerMedia? media;

  PlayerSettings? applied;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  final _stats = ValueNotifier<PlayerStats>(
    const PlayerStats(width: 1920, height: 1080),
  );
  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {
    this.media = media;
    _snapshot.value = const PlayerSnapshot(duration: Duration(minutes: 2));
  }

  @override
  Future<void> play() async {
    _snapshot.value = PlayerSnapshot(
      duration: _snapshot.value.duration,
      playing: true,
    );
  }

  @override
  Future<void> pause() async {
    _snapshot.value = PlayerSnapshot(
      position: _snapshot.value.position,
      duration: _snapshot.value.duration,
    );
  }

  @override
  Future<void> seek(Duration position) async {
    _snapshot.value = PlayerSnapshot(
      position: position,
      duration: _snapshot.value.duration,
    );
  }

  @override
  Future<void> stop() async {
    _snapshot.value = const PlayerSnapshot();
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {
    applied = settings;
  }

  @override
  Widget buildView() => Text('player:${kernel.id}');

  @override
  Future<void> dispose() async {
    _snapshot.dispose();
    _stats.dispose();
  }
}

/// Existing engine regression scenarios now perform the explicit detail/play step.
Future<void> tapWithDetailPlay(
  WidgetTester tester,
  Finder finder, {
  bool warnIfMissed = true,
}) async {
  if (finder.evaluate().isEmpty && finder.toString().contains('全屏')) return;
  bool episode(Widget widget) =>
      widget.key is ValueKey<String> &&
      RegExp(r'^video-detail-episode-\d+$')
          .hasMatch((widget.key as ValueKey<String>).value);
  final chapter = find
      .ancestor(of: finder, matching: find.byWidgetPredicate(episode))
      .evaluate()
      .isNotEmpty;
  final history = find
      .ancestor(of: finder, matching: find.byType(HistoryEntryTile))
      .evaluate()
      .isNotEmpty;
  await tester.tap(finder, warnIfMissed: warnIfMissed);
  // Prelaunch waits for endOfFrame while source/settings I/O uses the real clock.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
  }
  await tester.pumpAndSettle();
  if (find.byType(VideoDetailPage).evaluate().isNotEmpty) {
    final chips = find.descendant(
      of: find.byType(VideoDetailPage),
      matching: find.byWidgetPredicate(episode),
    );
    if (chapter || history || chips.evaluate().length <= 1) {
      final play = find.byKey(const Key('video-detail-play'));
      if (play.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(play).onPressed != null) {
        await tester.ensureVisible(play);
        await tester.tap(play);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
        }
        await tester.pumpAndSettle();
      }
    }
  }
}

Future<void> backToBrowse(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  await tester.pumpAndSettle();
  if (find.byType(VideoDetailPage).evaluate().isNotEmpty) {
    await tester.pageBack();
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }
}
