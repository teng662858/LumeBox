import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/module_ui_scale.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_module_settings.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/reading/section_image.dart';
import 'package:lume_box/features/video/video_player_page.dart';

import 'support/fake_source_manager.dart';

/// 本轮真机反馈的界面口径回归：
/// - 点封面（哪怕封面没加载出来）也要能打开条目，不能只有点标题才行；
/// - 全屏/竖屏控制栏：统一左右内边距、按钮大小统一、底部按钮均匀分布、
///   播放内核做进控制栏、音轨从播放页拿掉；
/// - 设置里的「控件尺寸」要真的作用到界面（此前只写库、无人读）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_ui_consistency');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
    BrowseLayoutSettings.instance.resetForTesting();
    ModuleUiScale.instance.resetForTesting();
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    ModuleUiScale.instance.resetForTesting();
    BrowseLayoutSettings.instance.resetForTesting();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('卡片点击：封面点得动', () {
    Future<void> pumpBrowse(
      WidgetTester tester, {
      required void Function(ExploreSelection) onOpen,
    }) async {
      final library = await ReadingLibrary.open(Section.comic);
      final pipeline = SectionImagePipeline(
        cacheDir: library.imageCacheDir,
        diskCache: false,
        requestSender: (_) async => const NetworkResponse(
          statusCode: 404,
          body: <int>[],
          headers: <String, String>{},
        ),
      );
      addTearDown(pipeline.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: ExploreView(
              section: Section.comic,
              pipeline: pipeline,
              manager: FakeSourceManager(
                sources: const <SourceDescriptor>[
                  SourceDescriptor(
                    id: 'demo',
                    name: '示例源',
                    version: '1',
                    enabled: true,
                  ),
                ],
                opened: <String, DataSource>{'demo': _CoverSource()},
              ),
              onOpenItem: onOpen,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('封面加载失败时，点封面照样打开条目（真机：只有点标题才行）', (tester) async {
      ExploreSelection? opened;
      await pumpBrowse(tester, onOpen: (selection) => opened = selection);

      expect(find.byType(SectionImage), findsWidgets);
      // 点封面正中：必须交给卡片（打开条目），而不是被「重试图片」吃掉。
      await tester.tap(find.byType(SectionImage).first);
      await tester.pumpAndSettle();
      expect(opened?.item.title, '封面挂了的作品');
    });
  });

  group('播放页控制栏尺寸统一 / 均匀分布 / 内核入口', () {
    Future<void> pumpPlayer(
      WidgetTester tester, {
      ReadingLibrary? library,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Open real SQLite before entering the fake widget clock.
      library ??= await ReadingLibrary.open(Section.video);
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            fullscreenOnly: false,
            library: library,
            media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
            catalog: const _AllKernelsCatalog(),
            playerFactory: (kernel) => _UiPlayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('竖屏：控制栏两排都在，且都是均匀分布、同一水平线', (tester) async {
      await pumpPlayer(tester);
      for (final finder in <Finder>[
        find.byTooltip('后退 10 秒'),
        find.byTooltip('前进 10 秒'),
        find.byTooltip('播放内核'),
        find.byTooltip('播放器设置'),
      ]) {
        expect(finder, findsOneWidget);
      }
      final transport = tester.widget<Row>(
        find
            .ancestor(of: find.byTooltip('后退 10 秒'), matching: find.byType(Row))
            .first,
      );
      expect(transport.mainAxisAlignment, MainAxisAlignment.spaceEvenly);
      final play = tester.getRect(find.byTooltip('暂停'));
      final back = tester.getRect(find.byTooltip('后退 10 秒'));
      expect(play.center.dy, closeTo(back.center.dy, 1));
    });

    testWidgets('全屏：底栏左右分组，组内固定间距，只有一个选集入口', (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      expect(find.byTooltip('前进 10 秒'), findsNothing);
      expect(find.byTooltip('后退 10 秒'), findsNothing);
      // 「上一集」已在 52db015 从全屏底栏移除（用户口径：只保留下一集）。
      expect(find.byTooltip('上一集'), findsNothing);
      final play = tester.getRect(find.byTooltip('暂停'));
      final next = tester.getRect(find.byTooltip('下一集'));
      final intro = tester.getRect(find.byTooltip('记片头（长按查看标记）'));
      final danmaku = tester.getRect(find.byTooltip('弹幕：开'));
      expect(next.left - play.right, closeTo(4, .1));
      expect(intro.left - next.right, closeTo(4, .1));
      expect(play.center.dy, closeTo(danmaku.center.dy, 1));
      final slider = tester.getRect(find.byType(Slider));
      expect(
        play.top - slider.bottom,
        closeTo(VideoPlayerPage.controlRowGap, 8),
        reason: '两行固定行距',
      );
      // 进度条那一**行**（含两侧时间）的左右边距 = 顶部那一排的内边距。
      final width = tester.getSize(find.byType(Scaffold).first).width;
      final started = tester.getRect(find.text('00:00'));
      final total = tester.getRect(find.text('10:00'));
      expect(
        started.left,
        closeTo(VideoPlayerPage.controlHorizontalPadding, 2),
        reason: '进度条行左边距 = 顶部内边距',
      );
      expect(
        width - total.right,
        closeTo(VideoPlayerPage.controlHorizontalPadding, 2),
      );
      // 音轨入口已从播放页拿掉（设置弹窗里仍可切）。
      expect(find.byTooltip('音轨'), findsNothing);
    });

    testWidgets('设置里的「控件尺寸」真的作用到控制栏（真机：显示模式没生效）', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      addTearDown(
        () => ModuleUiScale.instance.apply(
          Section.video,
          const SectionModuleSettings(),
        ),
      );

      ModuleUiScale.instance.apply(
        Section.video,
        const SectionModuleSettings(),
      );
      await pumpPlayer(tester, library: library);
      final standard = tester.getRect(find.byTooltip('播放内核')).width;

      ModuleUiScale.instance.apply(
        Section.video,
        const SectionModuleSettings(controlScale: 1.1),
      );
      await tester.pumpAndSettle();
      final roomy = tester.getRect(find.byTooltip('播放内核')).width;

      expect(
        roomy,
        greaterThan(standard),
        reason: '「控件尺寸」调到 110% 后按钮盒要跟着变大（此前只写库、界面无反应）',
      );
    });
  });
}

/// 只有一条条目、且**封面一定加载失败**的图源（真机「没封面」的场景）。
class _CoverSource implements DataSource {
  @override
  final Section section = Section.comic;

  @override
  String get id => 'demo';

  @override
  String get name => '示例源';

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(
    items: <SourceItem>[
      SourceItem(
        id: '/book/1',
        title: '封面挂了的作品',
        cover: 'https://images.example/dead.jpg',
      ),
    ],
  );

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => null;
}

/// 三套内核都可用（测试里不接平台目录）。
class _AllKernelsCatalog implements PlayerKernelCatalog {
  const _AllKernelsCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => true;

  @override
  String? unavailableReason(PlayerKernel kernel) => null;
}

class _UiPlayer extends AbstractPlayer {
  _UiPlayer();

  final ValueNotifier<PlayerSnapshot> _snapshot = ValueNotifier<PlayerSnapshot>(
    const PlayerSnapshot(playing: true, duration: Duration(minutes: 10)),
  );
  final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: 'fake'),
  );

  PlayerKernel get kernel => PlayerKernel.avplayer;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => const Text('ui-view');

  @override
  Future<void> dispose() async {}
}
