import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_detail_page.dart';
import 'package:lume_box/features/video/video_download_center.dart';

import 'support/fake_source_manager.dart';
import 'support/pump_io.dart';

/// 三个板块右上角的入口与它们的落点（真机反馈的改造，其后按用户要求删掉了日历）：
///
/// - ⏱️ 时钟 → **底部 Sheet 抽屉**里的历史（播放 / 阅读记录），不新开全屏页面；
/// - 📅 日历（追更 / 追剧日历）→ **已按用户要求整体删除**，本文件同时钉住
///   「三个板块都不再出现日历入口」。
///
/// 用真实板块页挂载（注入替身图源管理器），因此验的是「用户点得到的图标真的落在
/// 对的地方」——图标错挂 / 点开是另一个页面这类问题会当场失败。
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
    await SectionScope.open(Section.video);
    await SectionScope.open(Section.comic);
    await ReadingLibrary.open(Section.cat);
    await ReadingLibrary.open(Section.comic);
    await ReadingLibrary.open(Section.video);
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
    await tester.pumpWidget(MaterialApp(theme: LumeTheme.build(), home: page));
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

  /// 只入库（放进书架），**不写进度**：模拟「收藏了还没读」。
  Future<void> shelveOnly(
    Section section, {
    required String itemId,
    required String title,
  }) async {
    final library = await ReadingLibrary.open(section);
    library.shelve(
      sourceId: 'demo-source',
      itemId: itemId,
      title: title,
      chapterCount: 10,
    );
  }

  VideoProgress videoProgressAt(String itemId, Duration position) =>
      VideoProgress(
        section: Section.video,
        itemId: itemId,
        chapterIndex: 2,
        chapterId: '$itemId-e3',
        chapterTitle: '第 3 集',
        updatedAt: DateTime.now(),
        position: position,
        duration: const Duration(minutes: 45),
      );


  group('右上角两枚独立图标', () {
    testWidgets('视频：「播放历史」在、日历已删，顶部无页签条', (tester) async {
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));

      expect(find.byTooltip('播放历史'), findsOneWidget);
      expect(find.byTooltip('追剧日历'), findsNothing, reason: '日历已按用户要求删除');
      expect(find.byTooltip('追更日历'), findsNothing);
      // 用户口径：连「浏览」这条页签条也删掉，内容直接顶上去（对齐猫源板块）。
      expect(find.byType(Tab), findsNothing, reason: '视频页顶部不再有页签条');
      expect(find.widgetWithText(Tab, '浏览'), findsNothing);
      expect(find.widgetWithText(Tab, '播放'), findsNothing);
    });



    testWidgets('漫画：「阅读历史」在、日历已删（与小说同款）', (tester) async {
      await pump(
        tester,
        ComicPage(runtimeAvailable: true, manager: FakeSourceManager()),
      );

      expect(find.byTooltip('阅读历史'), findsOneWidget);
      expect(find.byTooltip('追更日历'), findsNothing, reason: '日历已按用户要求删除');
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
      expect(
        find.textContaining('12:00'),
        findsWidgets,
        reason: '进度只显示已播 / 总长，不再带集数',
      );
    });

    testWidgets('播放历史在下载目录不可用时仍打开对应影片', (tester) async {
      await seed(Section.video, itemId: 'movie-1', title: '续播影片',
        progress: videoProgressAt('movie-1', const Duration(minutes: 12)));
      final downloads = VideoDownloadCenter(directory: () async {
        throw const FileSystemException('unavailable');
      });
      await pump(tester, VideoPage(catalog: const _NoKernelCatalog(),
        sourceManager: FakeSourceManager(), downloadCenter: downloads));
      await tester.tap(find.byTooltip('播放历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('续播影片').first);
      await pumpIoAndSettle(tester);
      expect(downloads.needsRestore, true);
      final detail = tester.widget<VideoDetailPage>(find.byType(VideoDetailPage));
      expect(detail.sourceId, 'demo-source');
      expect(detail.item.id, 'movie-1');
      await tester.pumpWidget(const SizedBox.shrink());
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

      expect(find.text('清空'), findsOneWidget);
      expect(find.text('多选'), findsOneWidget);
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

      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  for (final section in [
    Section.comic,
    Section.video,
    Section.cat,
  ]) {
    for (final favorites in [false, true]) {
      testWidgets(
        '${section.label} ${favorites ? '收藏' : '历史'}：显示模式记忆、全选删除与取消',
        (tester) async {
          final library = await ReadingLibrary.open(section);
          for (final id in ['one', 'two']) {
            library.shelve(sourceId: 'demo', itemId: id, title: id);
            library.saveProgress(
              VideoProgress(
                section: section,
                itemId: id,
                chapterIndex: 0,
                chapterId: 'ep',
                chapterTitle: '第1集',
                updatedAt: DateTime.now(),
                position: const Duration(seconds: 20),
              ),
            );
          }
          await pump(
            tester,
            Scaffold(
              body: ReadingHistorySheet(
                section: section,
                library: library,
                initialTab: favorites
                    ? HistoryDrawerTab.favorites
                    : HistoryDrawerTab.records,
                onResume: (_, _) {},
              ),
            ),
          );
          expect(find.byType(ChoiceChip), findsNothing);
          await tester.tap(find.byTooltip('显示模式'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('三列网格'));
          await tester.pumpAndSettle();
          expect(find.byType(GridView), findsOneWidget);
          expect(
            library.setting(
              'collection.${favorites ? 'favorites' : 'history'}.layout',
            ),
            'grid3',
          );
          expect(
            library.setting(
              'collection.${favorites ? 'history' : 'favorites'}.layout',
            ),
            isNull,
          );
          await tester.tap(find.text('多选'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('全选'));
          await tester.pumpAndSettle();
          expect(find.text('已选 2'), findsOneWidget);
          await tester.tap(find.text('删除所选'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(library.shelf().length, 2);
          expect(library.continueReading().length, 2);
          await tester.tap(find.text('删除所选'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, '删除'));
          await tester.pumpAndSettle();
          expect(library.shelf().length, favorites ? 0 : 2);
          expect(library.continueReading().length, favorites ? 2 : 0);
          expect(find.text('暂无内容'), findsOneWidget);
        },
      );
    }
  }

  group('历史与收藏独立入口', () {
    for (final section in [Section.comic, Section.video]) {
      testWidgets('${section.label}收藏：未读条目可打开，且没有分栏', (tester) async {
        await shelveOnly(section, itemId: 'unread', title: '收藏未读的书');
        final library = await ReadingLibrary.open(section);
        LibraryItem? opened;
        await pump(
          tester,
          Scaffold(
            body: ReadingHistorySheet(
              section: section,
              library: library,
              initialTab: HistoryDrawerTab.favorites,
              onResume: (_, _) {},
              onOpenItem: (item) => opened = item,
            ),
          ),
        );
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byTooltip('显示模式'), findsOneWidget);
        expect(find.text('收藏未读的书'), findsOneWidget);
        await tester.tap(find.text('收藏未读的书'));
        expect(opened?.itemId, 'unread');
      });
    }
    testWidgets('视频收藏按钮直接展示收藏，不含历史分栏', (tester) async {
      await seed(
        Section.video,
        itemId: 'movie-1',
        title: '示例影片',
        progress: videoProgressAt('movie-1', const Duration(minutes: 12)),
      );
      await pump(tester, const VideoPage(catalog: _NoKernelCatalog()));
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(find.text('视频 · 收藏'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('示例影片'), findsOneWidget);
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
