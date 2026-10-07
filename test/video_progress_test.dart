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
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_page.dart';

import 'support/fake_source_manager.dart';

/// 视频播放进度记忆（文档要求「视频记忆到集数 + 播放时间点」）。
///
/// 验证：播到一半退出后再点同一作品，从上次位置继续；换集从头播；播完不自动
/// 跳结尾；首页「继续观看」列出最近播放、显示进度、可续看与移除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _VideoSource source;
  late FakeSourceManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_video_progress');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    await ReadingLibrary.open(Section.video);
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
    await tester.pumpAndSettle();
    return created;
  }

  testWidgets('播到一半退出：进度落库（集数 + 时间点）', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/e1.mp4';
    final created = await pumpBoard(tester);

    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();
    expect(created.single.media, isNotNull);

    // 播一会儿。
    created.single.emit(position: const Duration(minutes: 12), playing: true);
    await tester.pump();
    created.single.emit(position: const Duration(minutes: 12, seconds: 30));
    await tester.pump();

    // 退出页面：dispose 时最后落一次盘。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    final library = await ReadingLibrary.open(Section.video);
    final progress = library.videoProgress('movie-1');
    expect(progress, isNotNull, reason: '退出后必须留下播放记录');
    expect(progress!.chapterIndex, 0);
    expect(progress.chapterTitle, '第 1 集');
    expect(progress.position, const Duration(minutes: 12, seconds: 30));
  });

  testWidgets('再次点开同一集：从上次位置继续', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/e1.mp4';

    // 先播一段并退出。
    final first = await pumpBoard(tester);
    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();
    first.single.emit(position: const Duration(minutes: 20), playing: true);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    // 重新进入板块，再点同一作品（此时「继续观看」也在，取浏览列表那条）。
    final second = await pumpBoard(tester);
    await tester.tap(find.text('示例影片').last);
    await tester.pumpAndSettle();

    expect(
      second.single.seeks,
      contains(const Duration(minutes: 20)),
      reason: '续看必须 seek 回上次的时间点',
    );
    expect(find.textContaining('已从上次位置继续'), findsOneWidget);
  });

  testWidgets('换了另一集：从头播，不 seek 到上一集的位置', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
      SourceChapter(id: 'movie-1-e2', title: '第 2 集'),
    ];
    source.contentUrl = 'https://example.com/e2.mp4';

    final first = await pumpBoard(tester);
    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();
    // 选第 1 集，看一会儿。
    await tester.tap(find.text('第 1 集'));
    await tester.pumpAndSettle();
    first.single.emit(position: const Duration(minutes: 30), playing: true);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    // 重新进入并选第 2 集。
    // 注意：继续观看模块已挪到浏览页**底部**，树序上排在浏览区条目之后，
    // 因此「浏览区那一条」是 .first，「历史卡」是 .last（与从前相反）。
    final second = await pumpBoard(tester);
    await tester.tap(find.text('示例影片').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 集'));
    await tester.pumpAndSettle();

    expect(
      second.single.seeks,
      isEmpty,
      reason: '换了集就不该恢复上一集的时间点',
    );
  });

  testWidgets('已播完的作品：续看不跳结尾（重看从头）', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/e1.mp4';

    final library = await ReadingLibrary.open(Section.video);
    library.shelve(
      sourceId: 'demo-video',
      itemId: 'movie-1',
      title: '示例影片',
    );
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie-1',
        chapterIndex: 0,
        chapterId: 'movie-1-e1',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 44, seconds: 30),
        duration: const Duration(minutes: 45),
      ),
    );

    final created = await pumpBoard(tester);
    await tester.tap(find.text('示例影片').last);
    await tester.pumpAndSettle();

    expect(created.single.seeks, isEmpty, reason: '看完了就从头上，不跳到结尾');
    expect(find.textContaining('已从上次位置继续'), findsNothing);
  });

  testWidgets('首页「继续观看」：显示进度、可续看、可移除', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/e1.mp4';

    final library = await ReadingLibrary.open(Section.video);
    library.shelve(
      sourceId: 'demo-video',
      itemId: 'movie-1',
      title: '示例影片',
    );
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie-1',
        chapterIndex: 0,
        chapterId: 'movie-1-e1',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 45),
      ),
    );

    final created = await pumpBoard(tester);

    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('第 1 集 · 12:00 / 45:00'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsWidgets);

    // 点「继续观看」区块里的那一条（它在浏览列表上方，取 first）。
    await tester.tap(find.text('示例影片').first);
    await tester.pumpAndSettle();
    expect(
      created.single.seeks,
      contains(const Duration(minutes: 12)),
      reason: '点继续观看即从上次位置续播',
    );
  });

  testWidgets('起播：图源给的防盗链请求头原样交给内核（真机 403 慢播的回归）', (tester) async {
    // 真机反馈：同一个源电脑上立刻能播、iPhone 上要等一两分钟。原因是图源给的
    // 地址带防盗链头，而起播点只取了地址、把 VideoContent.headers 丢在了原地——
    // CDN 回 403 后网络队列按退避重试，累积起来正是那个量级。
    // 这条守的是「地址与请求头必须一起交给播放器」。
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.contentUrl = 'https://cdn.example/with-referer.mp4';
    source.contentHeaders = const <String, String>{
      'Referer': 'https://example.com/',
      'User-Agent': 'Mozilla/5.0 (iPhone)',
    };
    // 两章：单章时播放器会跳过选集直接起播，就点不到「第 1 集」了。
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
      SourceChapter(id: 'movie-1-e2', title: '第 2 集'),
    ];

    final players = await pumpBoard(tester);
    await tester.tap(find.text('示例影片').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 集'));
    await tester.pumpAndSettle();

    final media = players.single.media;
    expect(media, isNotNull, reason: '应当已经把媒体交给内核');
    expect(
      media!.headers,
      <String, String>{
        'Referer': 'https://example.com/',
        'User-Agent': 'Mozilla/5.0 (iPhone)',
      },
      reason: '防盗链请求头不能丢：丢了就是 CDN 403 + 退避重试（等一两分钟）',
    );
  });

  testWidgets('继续观看：移除后记录与条目一起消失', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    final library = await ReadingLibrary.open(Section.video);
    library.shelve(
      sourceId: 'demo-video',
      itemId: 'movie-1',
      title: '示例影片',
    );
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie-1',
        chapterIndex: 0,
        chapterId: 'movie-1-e1',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 45),
      ),
    );

    await pumpBoard(tester);
    expect(find.text('继续观看'), findsOneWidget);

    // 长按移除（区块提供的手势）。历史卡在树序末尾，用 .last 取它。
    await tester.longPress(find.text('示例影片').last);
    await tester.pumpAndSettle();

    expect(find.text('继续观看'), findsNothing, reason: '移除后整块隐藏');
    expect(library.videoProgress('movie-1'), isNull);
    expect(library.onShelf('movie-1'), isFalse);
  });

  testWidgets('没有播放记录时：首页不显示「继续观看」', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    await pumpBoard(tester);
    expect(find.text('继续观看'), findsNothing);
  });

  group('进度存储口径', () {
    test('集数 + 时间点往返：同一作品覆盖写', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.shelve(sourceId: 'src', itemId: 'v1', title: '作品');

      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'v1',
          chapterIndex: 2,
          chapterId: 'e3',
          chapterTitle: '第 3 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 40),
        ),
      );
      var saved = library.videoProgress('v1')!;
      expect(saved.chapterIndex, 2);
      expect(saved.chapterId, 'e3');
      expect(saved.position, const Duration(minutes: 5));
      expect(saved.duration, const Duration(minutes: 40));
      expect(saved.describe(), '第 3 集 · 5:00 / 40:00');

      // 同一作品再存一次：覆盖，不新增记录。
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'v1',
          chapterIndex: 2,
          chapterId: 'e3',
          chapterTitle: '第 3 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 18),
          duration: const Duration(minutes: 40),
        ),
      );
      saved = library.videoProgress('v1')!;
      expect(saved.position, const Duration(minutes: 18));
      expect(library.continueWatching().length, 1, reason: '同一作品只有一条记录');
    });

    test('已看完判定与比例', () {
      VideoProgress at(double ratio) => VideoProgress(
            section: Section.video,
            itemId: 'v',
            chapterIndex: 0,
            chapterId: 'c',
            chapterTitle: '第 1 集',
            updatedAt: DateTime.now(),
            position: Duration(seconds: (100 * ratio).round()),
            duration: const Duration(seconds: 100),
          );

      expect(at(0.5).isFinished, isFalse);
      expect(at(0.5).ratio, closeTo(0.5, 0.01));
      expect(at(0.94).isFinished, isFalse);
      expect(at(0.95).isFinished, isTrue, reason: '≥95% 视为看完');
      expect(at(1.0).isFinished, isTrue);
      // 时长未知：不算看完，比例 0（不凭空说人家看完了）。
      final unknown = VideoProgress(
        section: Section.video,
        itemId: 'v',
        chapterIndex: 0,
        chapterId: 'c',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 3),
      );
      expect(unknown.isFinished, isFalse);
      expect(unknown.ratio, 0);
      expect(unknown.describe(), '第 1 集 · 3:00');
    });

    test('切换剧集：时间点归零', () {
      final progress = VideoProgress(
        section: Section.video,
        itemId: 'v',
        chapterIndex: 0,
        chapterId: 'e1',
        chapterTitle: '第 1 集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 45),
      );
      final next = progress.withChapter(
        chapterIndex: 1,
        chapterId: 'e2',
        chapterTitle: '第 2 集',
      );
      expect(next.chapterIndex, 1);
      expect(next.position, Duration.zero);
      expect(next.duration, Duration.zero, reason: '新一集时长未知，等播放器给');
    });

    test('板块隔离：视频进度不出现在其他板块，也不与阅读进度混用', () async {
      final video = await ReadingLibrary.open(Section.video);
      final novel = await ReadingLibrary.open(Section.novel);

      video.shelve(sourceId: 's', itemId: 'shared-id', title: '视频作品');
      video.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'shared-id',
          chapterIndex: 0,
          chapterId: 'e1',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 10),
        ),
      );

      expect(video.videoProgress('shared-id'), isNotNull);
      expect(
        novel.progress('shared-id'),
        isNull,
        reason: '同一个 id 在小说板块不该看到视频的进度',
      );
      expect(novel.continueWatching(), isEmpty);
      // 小说板块查视频进度：形状不符，如实返回 null。
      expect(novel.videoProgress('shared-id'), isNull);
    });

    test('继续观看按最近播放倒序，且只含有进度的作品', () async {
      final library = await ReadingLibrary.open(Section.video);
      library.shelve(sourceId: 's', itemId: 'old', title: '先看的');
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'old',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
          position: const Duration(minutes: 1),
        ),
      );
      library.shelve(sourceId: 's', itemId: 'new', title: '后看的');
      library.saveProgress(
        VideoProgress(
          section: Section.video,
          itemId: 'new',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '第 1 集',
          updatedAt: DateTime.now(),
          position: const Duration(minutes: 2),
        ),
      );
      // 只在书架、没有播放记录的作品不该出现。
      library.shelve(sourceId: 's', itemId: 'never', title: '没看过');

      final list = library.continueWatching();
      expect(list.map((item) => item.itemId), <String>['new', 'old']);
    });
  });
  group('跨集自动连播', () {
    testWidgets('播完自动进下一集', (tester) async {
      source.items = const <SourceItem>[
        SourceItem(id: 'movie-1', title: '示例影片'),
      ];
      source.chapterList = const <SourceChapter>[
        SourceChapter(id: 'e1', title: '第 1 集'),
        SourceChapter(id: 'e2', title: '第 2 集'),
      ];
      source.contentUrl = 'https://example.com/e2.mp4';
      final created = await pumpBoard(tester);

      await tester.tap(find.text('示例影片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 集'));
      await tester.pumpAndSettle();

      // 播到结尾（模拟播放器把位置推到总时长）。
      created.single.emit(
        position: const Duration(minutes: 45),
        duration: const Duration(minutes: 45),
        playing: true,
      );
      await tester.pumpAndSettle();

      expect(
        created.single.media?.uri.toString(),
        'https://example.com/e2.mp4',
        reason: '播完应自动加载下一集',
      );
      expect(find.textContaining('已自动播放'), findsOneWidget);
    });

    testWidgets('最后一集播完：停下，不越界', (tester) async {
      source.items = const <SourceItem>[
        SourceItem(id: 'movie-1', title: '示例影片'),
      ];
      source.chapterList = const <SourceChapter>[
        SourceChapter(id: 'e1', title: '第 1 集'),
      ];
      source.contentUrl = 'https://example.com/e1.mp4';
      final created = await pumpBoard(tester);

      await tester.tap(find.text('示例影片'));
      await tester.pumpAndSettle();

      final mediaBefore = created.single.media?.uri.toString();
      created.single.emit(
        position: const Duration(minutes: 45),
        duration: const Duration(minutes: 45),
        playing: true,
      );
      await tester.pumpAndSettle();

      expect(
        created.single.media?.uri.toString(),
        mediaBefore,
        reason: '没有下一集就不动',
      );
      expect(find.textContaining('已自动播放'), findsNothing);
    });

    testWidgets('关掉自动连播：播完不跳集', (tester) async {
      // 独立的作品 id：避免前序用例留下的播放进度影响本用例。
      source.items = const <SourceItem>[
        SourceItem(id: 'movie-off', title: '关连播测试片'),
      ];
      source.chapterList = const <SourceChapter>[
        SourceChapter(id: 'e1', title: '第 1 集'),
        SourceChapter(id: 'e2', title: '第 2 集'),
      ];
      source.contentUrl = 'https://example.com/e2.mp4';
      final created = await pumpBoard(tester);

      await tester.tap(find.text('关连播测试片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 集'));
      await tester.pumpAndSettle();

      // 控制栏在独立播放器页里（点条目时已经压栈）。
      // 关掉连播开关（按图标点，避免 tooltip 在窄屏上不可见）。
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pumpAndSettle();
      expect(find.byTooltip('自动连播：关'), findsOneWidget);

      created.single.emit(
        position: const Duration(minutes: 45),
        duration: const Duration(minutes: 45),
        playing: true,
      );
      await tester.pumpAndSettle();

      expect(
        created.single.media?.uri.toString(),
        isNot('https://example.com/e2.mp4'),
        reason: '关掉后不该自动跳集',
      );
    });

    testWidgets('时长未知时不连播（宁可不跳，也不半途跳走）', (tester) async {
      source.items = const <SourceItem>[
        SourceItem(id: 'movie-nodur', title: '未知时长测试片'),
      ];
      source.chapterList = const <SourceChapter>[
        SourceChapter(id: 'e1', title: '第 1 集'),
        SourceChapter(id: 'e2', title: '第 2 集'),
      ];
      source.contentUrl = 'https://example.com/e2.mp4';
      final created = await pumpBoard(tester);

      await tester.tap(find.text('未知时长测试片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 集'));
      await tester.pumpAndSettle();

      // 位置在走但时长未知（0）。
      created.single.emit(position: const Duration(minutes: 10), duration: Duration.zero);
      await tester.pumpAndSettle();

      expect(
        created.single.media?.uri.toString(),
        isNot('https://example.com/e2.mp4'),
      );
    });
  });
}

/// 视频图源替身。
class _VideoSource implements DataSource {
  @override
  final Section section = Section.video;

  @override
  String get id => 'demo-video';

  @override
  String get name => '公开样片测试源';

  List<SourceItem> items = const <SourceItem>[];
  List<SourceChapter> chapterList = const <SourceChapter>[];
  String contentUrl = 'https://example.com/chapter.mp4';

  /// 图源给的播放请求头（防盗链）。默认空；用例可设成 Referer 之类。
  Map<String, String> contentHeaders = const <String, String>{};

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async =>
      SourceList(items: items, hasMore: false);

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async => chapterList;

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    // 每一集给各自的地址：contentUrl 是「当前用例关心的那一集」，
    // 其余集按 chapterId 推出来（否则每集同址，测试断言会失去意义）。
    final url = contentUrl.contains(chapterId)
        ? contentUrl
        : 'https://example.com/$chapterId.mp4';
    return VideoContent(url: Uri.parse(url), headers: contentHeaders);
  }
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

/// 播放器替身：记录 seek 与加载的媒体，位置由用例手动推进。
class _FakePlayer extends AbstractPlayer {
  _FakePlayer(this.kernel);

  final PlayerKernel kernel;

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  PlayerMedia? media;
  final List<Duration> seeks = <Duration>[];

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats =>
      ValueNotifier<PlayerStats>(const PlayerStats());

  /// 用例手动推进播放位置 / 播放状态。
  void emit({Duration? position, Duration? duration, bool? playing, String? error}) {
    _snapshot.value = PlayerSnapshot(
      position: position ?? _snapshot.value.position,
      duration: duration ?? const Duration(minutes: 45),
      playing: playing ?? _snapshot.value.playing,
      error: error,
    );
  }

  @override
  Future<void> load(PlayerMedia media) async {
    this.media = media;
    emit(duration: const Duration(minutes: 45));
  }

  @override
  Future<void> play() async => emit(playing: true);

  @override
  Future<void> pause() async => emit(playing: false);

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emit(position: position);
  }

  @override
  Future<void> stop() async => emit(playing: false, position: Duration.zero);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => Text('player:${kernel.id}');

  @override
  Future<void> dispose() async {
    _snapshot.dispose();
  }
}
