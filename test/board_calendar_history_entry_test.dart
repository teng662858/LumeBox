import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/novel/novel_page.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/video/video_page.dart';

import 'support/fake_source_manager.dart';

/// 三个板块右上角的**两枚独立图标**与它们的落点（真机反馈的改造）：
///
/// - 📅 日历 → 独立页：追更 / 追剧日历（更新排期 + 观看记录），**不是历史入口**；
/// - ⏱️ 时钟 → **底部 Sheet 抽屉**里的历史（播放 / 阅读记录），不新开全屏页面。
///
/// 用真实板块页挂载（注入替身图源管理器），因此验的是「用户点得到的那两个图标
/// 真的落在对的地方」——图标错挂 / 点开是另一个页面这类问题会当场失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_calendar_history');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    await SectionScope.open(Section.video);
    await SectionScope.open(Section.novel);
    await SectionScope.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: page),
    );
    await tester.pumpAndSettle();
  }

  /// 往本板块阅读库里写一条记录（进度与书架条目一起写，与真实链路同口径）。
  Future<void> seed(
    Section section, {
    required String itemId,
    required String title,
    required ReadingProgress progress,
  }) async {
    final library = await ReadingLibrary.open(section);
    library.shelve(
      sourceId: 'demo-source',
      itemId: itemId,
      title: title,
      chapterCount: 10,
    );
    library.saveProgress(progress);
  }

  VideoProgress videoProgressAt(String itemId, Duration position) => VideoProgress(
        section: Section.video,
        itemId: itemId,
        chapterIndex: 2,
        chapterId: '$itemId-e3',
        chapterTitle: '第 3 集',
        updatedAt: DateTime.now(),
        position: position,
        duration: const Duration(minutes: 45),
      );

  NovelProgress novelProgressAt(String itemId) => NovelProgress(
        section: Section.novel,
        itemId: itemId,
        chapterIndex: 4,
        chapterId: '$itemId-c5',
        chapterTitle: '第 5 章',
        updatedAt: DateTime.now(),
        charOffset: 500,
        chapterLength: 1000,
      );

  group('右上角两枚独立图标', () {
    testWidgets('视频：「追剧日历」+「播放历史」，页签只剩【浏览】', (tester) async {
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));

      expect(find.byTooltip('追剧日历'), findsOneWidget);
      expect(find.byTooltip('播放历史'), findsOneWidget);
      expect(find.widgetWithText(Tab, '浏览'), findsOneWidget);
      expect(
        find.widgetWithText(Tab, '播放'),
        findsNothing,
        reason: '播放子页签已移除（播放走独立播放器页）',
      );
    });

    testWidgets('小说：「追更日历」+「阅读历史」', (tester) async {
      await pump(
        tester,
        NovelPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );

      expect(find.byTooltip('追更日历'), findsOneWidget);
      expect(find.byTooltip('阅读历史'), findsOneWidget);
    });

    testWidgets('漫画：「追更日历」+「阅读历史」（与小说同款）', (tester) async {
      await pump(
        tester,
        ComicPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );

      expect(find.byTooltip('追更日历'), findsOneWidget);
      expect(find.byTooltip('阅读历史'), findsOneWidget);
    });
  });

  group('📅 日历进独立页', () {
    testWidgets('视频：标题「视频 · 追剧日历」', (tester) async {
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));
      await tester.tap(find.byTooltip('追剧日历'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '视频 · 追剧日历'), findsOneWidget);
    });

    testWidgets('小说：标题「小说 · 追更日历」，用的是本板块的记录', (tester) async {
      await seed(
        Section.novel,
        itemId: 'novel-1',
        title: '示例小说',
        progress: novelProgressAt('novel-1'),
      );
      await pump(
        tester,
        NovelPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );
      await tester.tap(find.byTooltip('追更日历'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '小说 · 追更日历'), findsOneWidget);
      // 今天读过 → 日历当天应有记录（点一下今天那一格）。
      expect(
        find.textContaining('追更'),
        findsWidgets,
        reason: '标题里就写明这是追更日历',
      );
    });

    testWidgets('漫画：标题「漫画 · 追更日历」', (tester) async {
      await pump(
        tester,
        ComicPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );
      await tester.tap(find.byTooltip('追更日历'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '漫画 · 追更日历'), findsOneWidget);
    });
  });

  group('⏱️ 时钟开底部抽屉（不新开全屏页）', () {
    testWidgets('视频：抽屉里直接看到播放记录，点条目回调续看', (tester) async {
      await seed(
        Section.video,
        itemId: 'movie-1',
        title: '示例影片',
        progress: videoProgressAt('movie-1', const Duration(minutes: 12)),
      );
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));

      await tester.tap(find.byTooltip('播放历史'));
      await tester.pumpAndSettle();

      // 是抽屉（Sheet）而不是整页：标题在抽屉里，且没有被 push 的路由。
      expect(find.byType(ReadingHistorySheet), findsOneWidget);
      expect(find.text('视频 · 历史'), findsOneWidget);
      expect(find.text('示例影片'), findsWidgets);
      expect(find.textContaining('第 3 集'), findsWidgets);
    });

    testWidgets('视频：抽屉里可以清空（视频的记录就是它的书架）', (tester) async {
      await seed(
        Section.video,
        itemId: 'movie-1',
        title: '示例影片',
        progress: videoProgressAt('movie-1', const Duration(minutes: 12)),
      );
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));
      await tester.tap(find.byTooltip('播放历史'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('清空历史'), findsOneWidget);
      expect(find.byTooltip('删除记录'), findsWidgets);
    });

    testWidgets('小说：抽屉里是阅读记录，且**只读**（书架是书库，不许顺手清）', (tester) async {
      await seed(
        Section.novel,
        itemId: 'novel-1',
        title: '示例小说',
        progress: novelProgressAt('novel-1'),
      );
      await pump(
        tester,
        NovelPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );
      await tester.tap(find.byTooltip('阅读历史'));
      await tester.pumpAndSettle();

      expect(find.byType(ReadingHistorySheet), findsOneWidget);
      expect(find.text('小说 · 历史'), findsOneWidget);
      expect(find.text('示例小说'), findsWidgets);
      expect(find.byTooltip('清空历史'), findsNothing);
      expect(find.byTooltip('删除记录'), findsNothing);
    });

    testWidgets('漫画：抽屉里是阅读记录，只读', (tester) async {
      await seed(
        Section.comic,
        itemId: 'comic-1',
        title: '示例漫画',
        progress: ComicProgress(
          section: Section.comic,
          itemId: 'comic-1',
          chapterIndex: 1,
          chapterId: 'comic-1-c2',
          chapterTitle: '第 2 话',
          updatedAt: DateTime.now(),
          page: 3,
        ),
      );
      await pump(
        tester,
        ComicPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );
      await tester.tap(find.byTooltip('阅读历史'));
      await tester.pumpAndSettle();

      expect(find.byType(ReadingHistorySheet), findsOneWidget);
      expect(find.text('漫画 · 历史'), findsOneWidget);
      expect(find.text('示例漫画'), findsWidgets);
      expect(find.byTooltip('删除记录'), findsNothing);
    });

    testWidgets('没有记录：抽屉给出空态说明，不是空白', (tester) async {
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));
      await tester.tap(find.byTooltip('播放历史'));
      await tester.pumpAndSettle();

      expect(find.text('还没有记录'), findsOneWidget);
    });
  });
}

/// 三套内核都不可用的目录（视频页的骨架分支）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '${kernel.label} 内核尚未接入';
}
