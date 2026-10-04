import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_home_page.dart';

import 'support/fake_source_manager.dart';

/// 板块业务页（小说 / 漫画）的功能验证：用替身管理器 + 模拟数据源驱动**真实页面**，
/// 走通「当前图源 → 分类 → 列表 → 搜索 → 详情 → 章节提示」以及图源切换与管理入口。
///
/// 替身只存在于测试里，生产代码不带任何 Mock 或 Debug 入口；正式实现由
/// `LumeSources.manager(section)` 提供。因此没有图源运行时的 Windows 上，
/// 这套页面粘合逻辑依然可以被完整验证。
void main() {
  const novel = Section.novel;

  Future<void> pumpHome(
    WidgetTester tester,
    SourceManager manager, {
    Section section = novel,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceHomePage(section: section, manager: manager),
      ),
    );
    await tester.pumpAndSettle();
  }

  FakeSourceManager managerWithNovelSource({
    List<SourceDescriptor> extra = const <SourceDescriptor>[],
    Map<String, DataSource>? opened,
  }) =>
      FakeSourceManager(
        sources: <SourceDescriptor>[
          const SourceDescriptor(
            id: 'novel-1',
            name: '小说示例源',
            version: '2.0.0',
            enabled: true,
          ),
          ...extra,
        ],
        opened: opened ??
            <String, DataSource>{
              'novel-1': const MockDataSource(section: novel),
            },
      );

  /// 与模拟源区分得开的第二图源，用于验证切换后页面确实换了数据源。
  const backup = _NamedSource(
    id: 'novel-2',
    name: '备用图源',
    section: novel,
    itemTitle: '备用条目',
  );

  testWidgets('当前图源 + 分类 + 列表：全部经数据源接口取得', (tester) async {
    final manager = managerWithNovelSource();
    await pumpHome(tester, manager);

    // 图源条显示板块内当前图源。
    expect(find.text('小说示例源'), findsOneWidget);

    // 分类与列表来自图源。
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('最新 · 模拟条目 1'), findsOneWidget);
    expect(manager.openedIds, <String>['novel-1']);
  });

  testWidgets('分类切换与搜索都走同一个列表入口', (tester) async {
    await pumpHome(tester, managerWithNovelSource());

    await tester.tap(find.text('玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('玄幻 · 模拟条目 1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('搜索 测试 · 模拟条目 1'), findsOneWidget);
  });

  testWidgets('详情与章节列表照旧，阅读器仍未实现', (tester) async {
    await pumpHome(tester, managerWithNovelSource());

    await tester.tap(find.text('最新 · 模拟条目 1'));
    await tester.pumpAndSettle();
    expect(find.text('章节（5）'), findsOneWidget);

    await tester.tap(find.text('第 1 章'));
    await tester.pumpAndSettle();
    expect(find.text('阅读器尚未实现'), findsOneWidget);
  });

  testWidgets('切换图源：面板只列本板块已启用的图源，切换后页面换源', (tester) async {
    final manager = managerWithNovelSource(
      extra: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'novel-2',
          name: '备用图源',
          version: '1.0.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'novel-9',
          name: '停用图源',
          version: '1.0.0',
          enabled: false,
        ),
      ],
      opened: <String, DataSource>{
        'novel-1': const MockDataSource(section: novel),
        'novel-2': backup,
      },
    );
    await pumpHome(tester, manager);

    await tester.tap(find.text('小说示例源'));
    await tester.pumpAndSettle();
    expect(find.text('切换图源'), findsOneWidget);
    expect(find.text('备用图源'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget, reason: '面板里带版本号');
    expect(find.text('停用图源'), findsNothing, reason: '停用的图源不应出现在切换候选里');

    await tester.tap(find.text('备用图源'));
    await tester.pumpAndSettle();

    expect(manager.selectedIds, <String>['novel-2']);
    expect(find.text('备用条目'), findsOneWidget);
    expect(find.text('备用图源'), findsOneWidget, reason: '图源条应显示新的当前图源');
    expect(find.text('最新 · 模拟条目 1'), findsNothing);
  });

  testWidgets('跨板块数据源：一律拒绝渲染', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(id: 'alien', name: '外来图源', version: '', enabled: true),
      ],
      // 小说明面上是小说板块的图源，实际交出漫画板块的数据源。
      opened: <String, DataSource>{
        'alien': const MockDataSource(section: Section.comic),
      },
    );
    await pumpHome(tester, manager);

    expect(find.text('图源板块不符，已拒绝加载'), findsOneWidget);
    expect(find.text('全部'), findsNothing, reason: '跨板块数据源不应渲染出任何列表');
  });

  testWidgets('图源禁用：图源全被停用时单独呈现，不与空数据混淆', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'novel-1',
          name: '停用图源',
          version: '',
          enabled: false,
        ),
      ],
    );
    await pumpHome(tester, manager);

    expect(find.text('图源已停用'), findsOneWidget);
    expect(find.text('板块内的图源都被停用，去图源管理里启用'), findsOneWidget);
    expect(find.text('图源管理'), findsOneWidget);
    expect(find.text('暂无图源'), findsNothing, reason: '有图源只是被停用，不算空数据');
    expect(manager.openedIds, isEmpty, reason: '没有可用图源时不应打开数据源');
  });

  testWidgets('空数据：板块内一个图源都没有时引导导入', (tester) async {
    await pumpHome(tester, FakeSourceManager());

    expect(find.text('暂无图源'), findsOneWidget);
    expect(find.text('进入图源管理导入并启用图源'), findsOneWidget);
    expect(find.text('图源已停用'), findsNothing);
  });

  testWidgets('脚本报错：当前图源打不开时给出重试与管理入口', (tester) async {
    final manager = managerWithNovelSource(opened: <String, DataSource>{});
    await pumpHome(tester, manager);

    expect(find.text('图源脚本报错'), findsOneWidget);
    expect(find.text('当前图源打不开（脚本载入失败或图源不可用）'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('图源管理'), findsOneWidget);
  });

  testWidgets('网络异常：浏览面单独呈现，重试后恢复', (tester) async {
    final manager = managerWithNovelSource(
      opened: <String, DataSource>{
        'novel-1': _FailingSource(
          section: novel,
          failure: const SourceException(
            SourceErrorKind.network,
            '网络请求失败：连接被拒绝',
          ),
          failures: 2,
        ),
      },
    );
    await pumpHome(tester, manager);

    expect(find.text('网络异常'), findsOneWidget);
    expect(find.text('网络请求失败：连接被拒绝'), findsOneWidget);
    expect(find.text('图源脚本报错'), findsNothing, reason: '网络异常不能被算作脚本报错');

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('恢复后的条目'), findsOneWidget);
  });

  testWidgets('脚本报错：浏览面呈现脚本错误原因，且不冒充网络异常', (tester) async {
    final manager = managerWithNovelSource(
      opened: <String, DataSource>{
        'novel-1': _FailingSource(
          section: novel,
          failure: const SourceException(
            SourceErrorKind.callFailed,
            'TypeError: x is not a function',
          ),
          failures: 2,
        ),
      },
    );
    await pumpHome(tester, manager);

    expect(find.text('图源脚本报错'), findsOneWidget);
    expect(find.text('TypeError: x is not a function'), findsOneWidget);
    expect(find.text('网络异常'), findsNothing);
  });

  testWidgets('管理入口：进入图源管理，停用当前图源后返回自动换源', (tester) async {
    final manager = managerWithNovelSource(
      extra: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'novel-2',
          name: '备用图源',
          version: '1.0.0',
          enabled: true,
        ),
      ],
      opened: <String, DataSource>{
        'novel-1': const MockDataSource(section: novel),
        'novel-2': backup,
      },
    );
    await pumpHome(tester, manager);
    expect(find.text('最新 · 模拟条目 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget, reason: '应进入图源管理页');

    // 在图源管理里停用当前图源。
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(manager.toggled.single, ('novel-1', false));

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 业务页自动回退到板块内下一个启用图源。
    expect(find.text('备用条目'), findsOneWidget);
    expect(find.text('备用图源'), findsOneWidget);
  });

  testWidgets('运行时不可用：只显示骨架，无管理入口', (tester) async {
    final manager = FakeSourceManager(runtimeAvailable: false);
    await pumpHome(tester, manager);

    expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsNothing);
    expect(manager.openedIds, isEmpty);
  });

  testWidgets('页面退出：释放板块资源', (tester) async {
    final manager = managerWithNovelSource();
    await pumpHome(tester, manager);
    expect(manager.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(manager.closed, isTrue);
  });
}

/// 最小数据源实现：只有一条条目、一个分类，用来区分不同图源的数据。
class _NamedSource implements DataSource {
  const _NamedSource({
    required this.id,
    required this.name,
    required this.section,
    required this.itemTitle,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final Section section;

  final String itemTitle;

  @override
  Future<List<SourceCategory>> categories() async =>
      const <SourceCategory>[SourceCategory(id: 'c1', title: '分类一')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async =>
      SourceList(items: <SourceItem>[SourceItem(id: 'i1', title: itemTitle)]);

  @override
  Future<SourceDetail?> detail(String itemId) async =>
      SourceDetail(id: itemId, title: itemTitle);

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

/// 先失败若干次、随后恢复的图源：用于验证异常状态与重试恢复。
class _FailingSource implements DataSource {
  _FailingSource({
    required this.section,
    required this.failure,
    this.failures = 1,
  });

  @override
  final Section section;

  final SourceException failure;

  /// 前多少次调用抛错（分类 + 列表各算一次）。
  final int failures;

  int _calls = 0;

  static const SourceItem _recovered = SourceItem(id: 'i1', title: '恢复后的条目');

  Future<void> _tick() async {
    _calls += 1;
    if (_calls <= failures) throw failure;
  }

  @override
  String get id => 'lume.test.failing';

  @override
  String get name => '故障图源';

  @override
  Future<List<SourceCategory>> categories() async {
    await _tick();
    return const <SourceCategory>[SourceCategory(id: 'c1', title: '分类一')];
  }

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async {
    await _tick();
    return const SourceList(items: <SourceItem>[_recovered]);
  }

  @override
  Future<SourceDetail?> detail(String itemId) async {
    await _tick();
    return null;
  }

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    await _tick();
    return const <SourceChapter>[];
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    await _tick();
    return null;
  }
}
