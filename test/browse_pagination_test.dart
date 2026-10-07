import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/source/browse_page.dart';

import 'support/fake_source_manager.dart';

/// 浏览列表的分页与刷新（真机反馈：只能看到第 1 页，滑到底不再加载）。
///
/// 三个板块共用同一套契约，这里用两个真实组件覆盖：
/// - 视频板块首页列表 = [BrowseView]；
/// - 小说 / 漫画首页列表 = [ExploreView]（两个板块各跑一遍，因为图源按板块隔离）。
///
/// 钉住四件事（用户点名的四条）：
/// 1. 上拉触底**持续**加载下一页（多页）；
/// 2. 同一页不会被并发请求两次（触底通知一帧来好几次）；
/// 3. 下拉刷新重置页码 / hasMore / 列表；
/// 4. 换图源清空旧分页，重新从第 1 页开始。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_paging');
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
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SectionImagePipeline> openPipeline(Section section) async {
    final library = await ReadingLibrary.open(section);
    return SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    );
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: Scaffold(body: child)),
    );
    await tester.pumpAndSettle();
  }

  /// 往下滑到底（触发触底加载）。
  Future<void> scrollDown(WidgetTester tester, {int times = 1}) async {
    for (var index = 0; index < times; index++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -900));
      await tester.pumpAndSettle();
    }
  }

  group('视频板块首页列表（BrowseView）', () {
    testWidgets('触底持续加载：第 1 页 → 第 2 页 → 第 3 页', (tester) async {
      final source = _PagedSource(section: Section.video, totalPages: 3);
      await pump(
        tester,
        BrowseView(dataSource: source, onItemTap: (_) {}),
      );

      expect(find.text('条目 source-a-1-1'), findsOneWidget);
      expect(source.requests, <int>[1]);

      await scrollDown(tester);
      expect(find.text('条目 source-a-2-1'), findsOneWidget, reason: '触底加载第 2 页');
      expect(source.requests, contains(2));

      await scrollDown(tester);
      expect(find.text('条目 source-a-3-1'), findsOneWidget, reason: '继续触底加载第 3 页');
      expect(source.requests, contains(3));

      // 到底了：不再请求第 4 页，尾部给出「没有更多了」。
      await scrollDown(tester);
      expect(source.requests, isNot(contains(4)));
      expect(find.text('没有更多了'), findsOneWidget);
    });

    testWidgets('同一页不会被并发请求两次（触底通知密集）', (tester) async {
      final source = _PagedSource(
        section: Section.video,
        totalPages: 5,
        delay: const Duration(milliseconds: 50),
      );
      await pump(
        tester,
        BrowseView(dataSource: source, onItemTap: (_) {}),
      );

      // 连续猛滑：同一页只应发一次请求。
      for (var index = 0; index < 6; index++) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();

      final duplicated = source.requests
          .where((page) => source.requests.where((p) => p == page).length > 1)
          .toSet();
      expect(duplicated, isEmpty, reason: '请求序号：${source.requests}');
    });

    testWidgets('下拉刷新：重置页码与列表，刷新后还能继续加载', (tester) async {
      final source = _PagedSource(section: Section.video, totalPages: 3);
      await pump(
        tester,
        BrowseView(dataSource: source, onItemTap: (_) {}),
      );
      await scrollDown(tester);
      expect(find.text('条目 source-a-2-1'), findsOneWidget);

      // 下拉刷新。
      await tester.drag(find.byType(Scrollable).last, const Offset(0, 600));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(source.requests.last, 1, reason: '刷新回到第 1 页');
      expect(find.text('条目 source-a-1-1'), findsOneWidget);
      expect(find.text('条目 source-a-2-1'), findsNothing, reason: '旧列表已清空');

      // 刷新之后还能继续翻页。
      await scrollDown(tester);
      expect(find.text('条目 source-a-2-1'), findsOneWidget, reason: '刷新后可继续加载');
    });

    testWidgets('加载下一页失败：不清「还有更多」，可点击重试', (tester) async {
      final source = _PagedSource(section: Section.video, totalPages: 3)
        ..failPages.add(2);
      await pump(
        tester,
        BrowseView(dataSource: source, onItemTap: (_) {}),
      );

      await scrollDown(tester);
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      expect(
        find.text('没有更多了'),
        findsNothing,
        reason: '失败不等于没有更多——清掉 hasMore 就再也拉不动了',
      );

      source.failPages.clear();
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(find.text('条目 source-a-2-1'), findsOneWidget, reason: '重试真的取到了第 2 页');
    });
  });

  group('小说 / 漫画首页列表（ExploreView）', () {
    for (final section in <Section>[Section.novel, Section.comic]) {
      testWidgets('${section.label}：触底加载多页 + 换图源重置分页', (tester) async {
        final pipeline = await openPipeline(section);
        addTearDown(pipeline.dispose);
        final first = _PagedSource(section: section, totalPages: 4);
        final second = _PagedSource(
          section: section,
          totalPages: 2,
          id: 'source-b',
          name: '第二个源',
        );
        final manager = FakeSourceManager(
          sources: <SourceDescriptor>[
            const SourceDescriptor(
              id: 'source-a',
              name: '第一个源',
              version: '1',
              enabled: true,
            ),
            const SourceDescriptor(
              id: 'source-b',
              name: '第二个源',
              version: '1',
              enabled: true,
            ),
          ],
          opened: <String, DataSource>{'source-a': first, 'source-b': second},
        );

        await pump(
          tester,
          ExploreView(
            section: section,
            pipeline: pipeline,
            manager: manager,
            layout: ExploreLayout.list,
            onOpenItem: (_) {},
          ),
        );

        expect(find.text('条目 source-a-1-1'), findsOneWidget);
        await scrollDown(tester);
        expect(find.text('条目 source-a-2-1'), findsOneWidget, reason: '${section.label} 触底加载第 2 页');

        // 换图源：旧分页数据清空，从第 1 页重新开始。
        //
        // 先记下切换瞬间旧源的请求序列：滑到底时的连续预加载（1→2→3→4）发生在
        // 切换**之前**，因此判据是「切换之后旧源不再被请求」，而不是「旧源只请求过 1、2」。
        final firstRequestsBefore = List<int>.of(first.requests);
        await tester.tap(find.text('第一个源'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第二个源').last);
        await tester.pumpAndSettle();

        expect(
          find.text('条目 source-a-2-1'),
          findsNothing,
          reason: '换源后旧分页数据必须清空',
        );
        expect(second.requests.first, 1, reason: '新源从第 1 页开始');
        expect(
          first.requests,
          firstRequestsBefore,
          reason: '换源之后旧源不再被请求（每个源各维护自己的分页状态）',
        );
      });
    }

    testWidgets('下拉刷新：重置分页并回到第 1 页', (tester) async {
      final pipeline = await openPipeline(Section.novel);
      addTearDown(pipeline.dispose);
      final source = _PagedSource(section: Section.novel, totalPages: 3);
      await pump(
        tester,
        ExploreView(
          section: Section.novel,
          pipeline: pipeline,
          manager: FakeSourceManager(
            sources: const <SourceDescriptor>[
              SourceDescriptor(
                id: 'source-a',
                name: '第一个源',
                version: '1',
                enabled: true,
              ),
            ],
            opened: <String, DataSource>{'source-a': source},
          ),
          layout: ExploreLayout.list,
          onOpenItem: (_) {},
        ),
      );

      await scrollDown(tester);
      expect(find.text('条目 source-a-2-1'), findsOneWidget);

      await tester.drag(find.byType(Scrollable).last, const Offset(0, 700));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(source.requests.last, 1);
      expect(
        find.text('条目 source-a-2-1'),
        findsNothing,
        reason: '刷新后列表回到第 1 页',
      );
    });
  });
}

/// 分页图源替身：每页 N 条，页码从 1 开始，`hasMore = page < totalPages`。
class _PagedSource implements DataSource {
  _PagedSource({
    required this.section,
    this.totalPages = 3,
    this.id = 'source-a',
    this.name = '分页源',
    this.delay,
    this.perPage = 8,
  });

  @override
  final Section section;

  @override
  final String id;

  @override
  final String name;

  final int totalPages;
  final int perPage;

  /// 人为的响应延迟（验并发保护用）。
  final Duration? delay;

  /// 发过的页码序列（顺序即真实请求顺序）。
  final List<int> requests = <int>[];

  /// 这些页会失败（验「失败不清 hasMore」）。
  final Set<int> failPages = <int>{};

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async {
    requests.add(page);
    if (delay != null) await Future<void>.delayed(delay!);
    if (failPages.contains(page)) {
      throw const SourceException(SourceErrorKind.network, '这一页取不到');
    }
    return SourceList(
      items: <SourceItem>[
        for (var index = 0; index < perPage; index++)
          SourceItem(
            id: '$id-item-$page-$index',
            title: '条目 $id-$page-${index + 1}',
          ),
      ],
      hasMore: page < totalPages,
    );
  }

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async =>
      null;
}
