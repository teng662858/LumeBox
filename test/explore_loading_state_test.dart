import 'dart:async';
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
import 'package:lume_box/features/shell/app_shell.dart';

import 'support/fake_source_manager.dart';

/// 进板块时的「首屏加载态」（真机反馈）：以前列表还没回来就先渲染空态，
/// 表现为「每次打开这几个模块都先显示『暂无内容 / 换个分类或关键词试试』，
/// 两秒后内容才自己冒出来」。
///
/// 钉住三件事：
/// 1. 首屏请求在飞期间显示加载态，**绝不**显示空态；
/// 2. 请求真的返回空列表时，空态照旧要出现（别把真空态一起藏掉）；
/// 3. 首页探针不阻塞列表加载（探针慢 = 列表不能跟着慢）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_loading');
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

  Future<void> pump(
    WidgetTester tester, {
    required DataSource source,
    SectionImagePipeline? pipeline,
    bool kazumi = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: ExploreView(
            section: Section.comic,
            pipeline: pipeline,
            manager: FakeSourceManager(
              sources: <SourceDescriptor>[
                SourceDescriptor(
                  id: kazumi ? 'kazumi_example' : 'source-a',
                  name: '示例源',
                  version: '1',
                  enabled: true,
                ),
              ],
              opened: <String, DataSource>{
                kazumi ? 'kazumi_example' : 'source-a': source,
              },
            ),
            // 列表形态：条目标题是纯文本，断言不受封面加载影响。
            layout: ExploreLayout.list,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('源初始化超时后给出可重试提示，重试可恢复', (tester) async {
    final manager = _HangingManager();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreView(
            section: Section.comic,
            manager: manager,
            layout: ExploreLayout.list,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.textContaining('源启动超时'), findsOneWidget);
    manager.pending.complete([]);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无源'), findsWidgets);
  });

  testWidgets('打开源超时时保留已选源名称', (tester) async {
    final manager = _HangingOpenManager();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreView(
            section: Section.comic,
            manager: manager,
            layout: ExploreLayout.list,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.textContaining('源启动超时'), findsOneWidget);
    expect(find.text('示例源'), findsOneWidget);
    expect(find.text('未选择源'), findsNothing);
    manager.pending.complete(null);
  });

  testWidgets('切换到设置时保留正在加载的真实浏览页，回来无需重新请求', (tester) async {
    final source = _GatedSource(section: Section.comic);
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'source-a',
          name: '示例源',
          version: '1',
          enabled: true,
        ),
      ],
      opened: {'source-a': source},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          desktopRail: false,
          pageBuilder: (id) => id == 'comic'
              ? ExploreView(
                  section: Section.comic,
                  manager: manager,
                  layout: ExploreLayout.list,
                  onOpenItem: (_) {},
                )
              : Text('page-$id'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在加载…'), findsOneWidget);
    expect(source.calls, 1);
    await tester.tap(
      find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text('设置'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    source.release();
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text('漫画'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('条目 1'), findsOneWidget);
    expect(source.calls, 1);
    expect(manager.openedIds, ['source-a']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Kazumi 无首页时提供明确搜索入口，不显示普通空列表重试提示', (tester) async {
    final source = _EmptySource(section: Section.comic);
    final pipeline = await openPipeline(Section.comic);
    addTearDown(pipeline.dispose);
    await pump(tester, source: source, pipeline: pipeline, kazumi: true);
    await tester.pumpAndSettle();
    expect(find.text('搜索这站的动漫'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '搜索动漫'), findsOneWidget);
    expect(find.text('换个分类或关键词试试'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '搜索动漫'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('当前源搜索'), findsOneWidget);
  });

  testWidgets('首屏请求在飞：显示加载态，不显示「暂无内容」', (tester) async {
    final source = _GatedSource(section: Section.comic);
    await pump(tester, source: source);

    // 请求还没回来：这里必须停在加载态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在加载…'), findsOneWidget, reason: '首屏该有加载态');
    expect(find.text('暂无内容'), findsNothing, reason: '请求在飞时不能闪假空态');
    expect(find.text('换个分类或关键词试试'), findsNothing, reason: '同上');

    source.release();
    await tester.pumpAndSettle();
    expect(find.text('条目 1'), findsOneWidget, reason: '回来之后要真的出内容');
    expect(find.text('暂无内容'), findsNothing);
  });

  testWidgets('首屏请求超时后显示重试而不是一直加载', (tester) async {
    final source = _GatedSource(section: Section.comic);
    await pump(tester, source: source);
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.textContaining('列表请求超时'), findsOneWidget);
    expect(find.text('正在加载…'), findsNothing);
    source.release();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('条目 1'), findsOneWidget);
  });

  testWidgets('请求真的返回空列表：空态照旧出现（别把真空态也藏了）', (tester) async {
    final source = _EmptySource(section: Section.comic);
    final pipeline = await openPipeline(Section.comic);
    addTearDown(pipeline.dispose);
    await pump(tester, source: source, pipeline: pipeline);
    await tester.pumpAndSettle();

    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('换个分类或关键词试试'), findsOneWidget);
  });

  testWidgets('首页探针慢不阻塞列表（探针串行会把列表推后两秒）', (tester) async {
    final source = _SlowProbeSource(section: Section.comic);
    await pump(tester, source: source);
    await tester.pumpAndSettle();

    expect(
      find.text('条目 1'),
      findsOneWidget,
      reason: '探针还没回来，列表就该已经出内容（用户报的 2 秒假空态根因）',
    );
    expect(find.text('暂无内容'), findsNothing);
  });
}

class _HangingManager extends FakeSourceManager {
  final pending = Completer<List<SourceDescriptor>>();
  @override
  Future<List<SourceDescriptor>> list() => pending.future;
}

class _HangingOpenManager extends FakeSourceManager {
  _HangingOpenManager()
    : super(
        sources: const [
          SourceDescriptor(
            id: 'source-a',
            name: '示例源',
            version: '1',
            enabled: true,
          ),
        ],
      );
  final pending = Completer<DataSource?>();
  @override
  Future<DataSource?> open(String sourceId) => pending.future;
}

/// 首屏请求可以手动放行：用来停在「请求在飞」的那一瞬间。
class _GatedSource implements DataSource {
  _GatedSource({required this.section});

  @override
  final Section section;

  final Completer<void> _gate = Completer<void>();
  int calls = 0;

  void release() => _gate.complete();

  @override
  String get id => 'lume.gated.${section.id}';

  @override
  String get name => '放行源';

  @override
  Future<List<SourceCategory>> categories() async => <SourceCategory>[
    const SourceCategory(id: 'c1', title: '分类一'),
  ];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    calls++;
    await _gate.future;
    return const SourceList(
      items: <SourceItem>[SourceItem(id: 'a1', title: '条目 1')],
      hasMore: false,
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
  }) async => null;
}

/// 列表回来是空的（真空态）。
class _EmptySource implements DataSource {
  _EmptySource({required this.section});

  @override
  final Section section;

  @override
  String get id => 'lume.empty.${section.id}';

  @override
  String get name => '空源';

  @override
  Future<List<SourceCategory>> categories() async => <SourceCategory>[
    const SourceCategory(id: 'c1', title: '分类一'),
  ];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(items: <SourceItem>[], hasMore: false);

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

/// 首页探针很慢（一直不返回），但列表很快。
class _SlowProbeSource implements DataSource, HomeCapable {
  _SlowProbeSource({required this.section});

  @override
  final Section section;

  @override
  String get id => 'lume.slowprobe.${section.id}';

  @override
  String get name => '慢探针源';

  @override
  Future<bool> supportsHome() => Completer<bool>().future; // 永挂：模拟慢探针

  @override
  Future<SourceHome> home() async =>
      const SourceHome(boards: <SourceHomeBoard>[]);

  @override
  Future<List<SourceCategory>> categories() async => <SourceCategory>[
    const SourceCategory(id: 'c1', title: '分类一'),
  ];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(
    items: <SourceItem>[SourceItem(id: 'a1', title: '条目 1')],
    hasMore: false,
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
