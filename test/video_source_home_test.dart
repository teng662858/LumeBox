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
import 'package:lume_box/features/reading/section_image.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_player_page.dart';

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
    await ReadingLibrary.open(video);
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

  testWidgets('首页就是图源展示页：列表直接可见，播放器不占首页', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'https://example.com/demo.mp4', title: '测试视频'),
    ];
    await pumpBoard(tester);

    // 首页（第一个页签）显示当前图源与条目。
    expect(find.text('公开样片测试源'), findsOneWidget);
    expect(find.text('测试视频'), findsOneWidget);
    expect(find.text('视频地址或本地路径'), findsNothing, reason: '播放器的地址栏不该占着首页');
    expect(find.byTooltip('播放器设置'), findsNothing);

    // 图源管理入口只有右上角一个（图源条不再重复一个同名入口）。
    expect(find.byTooltip('源管理'), findsOneWidget);
  });

  testWidgets('列表条目展示封面 / 标题 / 简介：只有带封面的条目占图位', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(
        id: 'movie-1',
        title: '示例影片',
        subtitle: '科幻 · 2026',
        cover: 'https://example.com/poster.jpg',
      ),
      SourceItem(id: 'movie-2', title: '无封面影片'),
    ];
    await pumpBoard(tester);

    // 标题与简介照常展示。
    expect(find.text('示例影片'), findsOneWidget);
    expect(find.text('科幻 · 2026'), findsOneWidget);

    // 封面走本板块的图片管线（与小说 / 漫画列表同一套纪律）；测试环境取不到
    // 图时显示主题占位，图位本身照常在，不影响断言。
    final covers = tester
        .widgetList<SectionImage>(find.byType(SectionImage))
        .toList(growable: false);
    expect(
      covers,
      hasLength(2),
      reason: '浏览列表与小说 / 漫画同一套卡片：每条都占封面位'
          '（没封面的显示主题占位，与小说明 / 漫画列表一致）',
    );
    expect(
      covers.first.url,
      'https://example.com/poster.jpg',
      reason: '有封面的条目按图源给的地址取图',
    );
    expect(
      covers.last.url.isEmpty,
      isTrue,
      reason: '没封面的条目走主题占位（图位仍在，不留空位之外的空缺）',
    );
  });

  testWidgets('导入源后首页自动刷新出列表（不必手动重试或切页签）', (tester) async {
    // 空板块起步：首页显示空态与导入引导。
    manager = FakeSourceManager(
      // 导入后的新图源（FakeSourceManager 固定用 lume.new / 新图源）可打开。
      opened: <String, DataSource>{'lume.new': source},
    );
    source.items = const <SourceItem>[
      SourceItem(id: 'https://example.com/after-import.mp4', title: '导入后的条目'),
    ];
    await pumpBoard(tester);

    expect(find.text('暂无源'), findsOneWidget, reason: '起步是空板块');

    // 走右上角「+」导入（与真实导入同一条路径：校验 → 落库 → onImported）。
    await tester.tap(find.byTooltip('添加源'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '// LumeSource: {"id":"lume.new","name":"新图源","version":"1.0.0"}',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(manager.imported, hasLength(1));
    // 自动刷新：空态消失，图源条换成新图源，列表直接出现（无需点「重试」）。
    expect(find.text('暂无源'), findsNothing, reason: '导入完成即重挂浏览面');
    expect(find.text('新图源'), findsOneWidget, reason: '源条切到新导入的源');
    expect(find.text('导入后的条目'), findsOneWidget, reason: '列表自动刷出');
    // 刷新必须是**原地重解析**：管理器不能被拆（拆了会连带拆掉板块共享的
    // 图源注册表，页面随后就报「图源存储不可用」——真机自测抓到的竞态）。
    expect(manager.closed, isFalse, reason: '刷新不能释放管理器');
  });

  testWidgets('点条目直接起播：条目自带地址时不再要详情 / 章节', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'https://example.com/demo.mp4', title: '测试视频'),
    ];
    final created = await pumpBoard(tester);
    expect(created, isEmpty, reason: '浏览页自己不建播放器（起播才建）');

    await tester.tap(find.text('测试视频'));
    await tester.pumpAndSettle();

    // 起播：唤起独立播放器页，媒体交给播放器。
    expect(find.byType(VideoPlayerPage), findsOneWidget, reason: '点条目唤起播放器页');
    expect(created, hasLength(1));
    expect(created.single.media?.uri.toString(), 'https://example.com/demo.mp4');
    expect(created.single.media?.title, '测试视频');
    expect(source.chapterCalls, isEmpty, reason: '自带地址不必再去问剧集');
    expect(find.byTooltip('播放器设置'), findsWidgets, reason: '播放器页带设置入口');
    // 地址不再铺在控制栏上（用户要求）：从「播放源」弹窗里能看到它。
    expect(
      find.text('https://example.com/demo.mp4'),
      findsNothing,
      reason: '控制栏不直接展示长链接',
    );
    await tester.tap(find.byTooltip('播放源'));
    await tester.pumpAndSettle();
    expect(find.text('https://example.com/demo.mp4'), findsWidgets);
  });

  testWidgets('条目没有地址：走剧集链路，选一集后起播取到的视频地址', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
      SourceChapter(id: 'movie-1-e2', title: '第 2 集'),
    ];
    source.contentUrl = 'https://example.com/movie-1-e2.mp4';
    final created = await pumpBoard(tester);

    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();

    // 多集先让用户选。
    expect(find.text('选择剧集'), findsOneWidget);
    await tester.tap(find.text('第 2 集'));
    await tester.pumpAndSettle();

    expect(
      created.single.media?.uri.toString(),
      'https://example.com/movie-1-e2.mp4',
    );
    expect(source.contentCalls.single, ('movie-1', 'movie-1-e2'));
  });

  testWidgets('只有一集时不弹选择面板', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chapterList = const <SourceChapter>[
      SourceChapter(id: 'movie-1-e1', title: '第 1 集'),
    ];
    source.contentUrl = 'https://example.com/movie-1-e1.mp4';
    final created = await pumpBoard(tester);

    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();

    expect(find.text('选择剧集'), findsNothing);
    expect(
      created.single.media?.uri.toString(),
      'https://example.com/movie-1-e1.mp4',
    );
  });

  testWidgets('脚本没实现剧集：如实提示缺哪个函数，不静默失败', (tester) async {
    source.items = const <SourceItem>[
      SourceItem(id: 'movie-1', title: '示例影片'),
    ];
    source.chaptersFailure = const SourceException(
      SourceErrorKind.callFailed,
      '源脚本没有实现 chapters 方法：请定义顶层函数 getChapters',
    );
    final created = await pumpBoard(tester);

    await tester.tap(find.text('示例影片'));
    await tester.pumpAndSettle();

    expect(created, isEmpty, reason: '没有可播放地址就不该起播');
    expect(find.byType(VideoPlayerPage), findsNothing, reason: '不往下走，也不唤起播放器页');
    expect(
      find.textContaining('没有实现 chapters 方法'),
      findsOneWidget,
      reason: '提示要能指出脚本缺什么',
    );
  });

  testWidgets('板块内没有可用图源：首页给导入引导', (tester) async {
    manager = FakeSourceManager();
    await pumpBoard(tester);

    expect(find.text('暂无源'), findsOneWidget);
    expect(find.text('源管理'), findsOneWidget, reason: '给一个去导入的按钮');
    // 页签只剩【浏览】：播放已搬到独立播放器页（真机反馈的改造）。
    expect(find.widgetWithText(Tab, '浏览'), findsOneWidget);
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
  }) async =>
      SourceList(items: items, hasMore: false);

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
    return VideoContent(url: Uri.parse(contentUrl));
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

  final ValueNotifier<PlayerSnapshot> _snapshot =
      ValueNotifier<PlayerSnapshot>(const PlayerSnapshot());

  PlayerMedia? media;

  PlayerSettings? applied;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats =>
      ValueNotifier<PlayerStats>(const PlayerStats());

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
  }
}
