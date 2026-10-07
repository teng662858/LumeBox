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
              sources: const <SourceDescriptor>[
                SourceDescriptor(
                  id: 'source-a',
                  name: '示例源',
                  version: '1',
                  enabled: true,
                ),
              ],
              opened: <String, DataSource>{'source-a': source},
            ),
            // 列表形态：条目标题是纯文本，断言不受封面加载影响。
            layout: ExploreLayout.list,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
  }

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

/// 首屏请求可以手动放行：用来停在「请求在飞」的那一瞬间。
class _GatedSource implements DataSource {
  _GatedSource({required this.section});

  @override
  final Section section;

  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  String get id => 'lume.gated.${section.id}';

  @override
  String get name => '放行源';

  @override
  Future<List<SourceCategory>> categories() async =>
      <SourceCategory>[const SourceCategory(id: 'c1', title: '分类一')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
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
  }) async =>
      null;
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
  Future<List<SourceCategory>> categories() async =>
      <SourceCategory>[const SourceCategory(id: 'c1', title: '分类一')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async =>
      const SourceList(items: <SourceItem>[], hasMore: false);

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
  Future<SourceHome> home() async => const SourceHome(boards: <SourceHomeBoard>[]);

  @override
  Future<List<SourceCategory>> categories() async =>
      <SourceCategory>[const SourceCategory(id: 'c1', title: '分类一')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async =>
      const SourceList(
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
  }) async =>
      null;
}
