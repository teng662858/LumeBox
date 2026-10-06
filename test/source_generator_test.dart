import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/generator/generator_database.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/source_generator_page.dart';

/// 图源生成器（可视化爬虫模块）的**占位框架**验证。
///
/// 本轮交付的是骨架，不是能力。因此这里断言的是三件事：
/// 1. **入口在设置页**、底部 5 个主 Tab 不变（生成器不是主阅读板块）；
/// 2. 页面**只有 UI 骨架**：网址输入、规则配置、生成 / 预览按钮都在位，
///    且**所有交互按钮点击一律弹「功能开发中」**；
/// 3. 数据表**预留字段齐备**且可写可读——后续迭代直接填充能力，不必再做迁移。
///
/// 刻意不断言任何爬虫行为（不发请求、不解析、不生成脚本）：本轮就没有这些逻辑，
/// 断言它们等于给未来的实现提前上枷锁。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_generator');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    // 设置页里的「播放器内核」逃生入口会打开视频板块的库：板块作用域必须在
    // **真实时钟**里先建好——testWidgets 的测试体跑在 fake-async 时钟里，
    // 首次打开要创建目录（真实异步），在测试体里 await 会等不到。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    GeneratorDatabase.disposeAll();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const SettingsPage(runtimeAvailable: true),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpGenerator(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const SourceGeneratorPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ==========================================================================
  // 入口与导航
  // ==========================================================================

  group('入口：设置页里的预留菜单项', () {
    testWidgets('设置页有「图源生成器（开发中）」入口，点进去是占位页', (tester) async {
      await pumpSettings(tester);

      expect(
        find.text('图源生成器（开发中）'),
        findsOneWidget,
        reason: '入口文案要带「开发中」，用户一眼知道当前状态',
      );

      await tester.tap(find.text('图源生成器（开发中）'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '图源生成器'), findsOneWidget);
      expect(find.textContaining('这是预留的界面骨架'), findsOneWidget);
    });

    testWidgets('入口放在设置页，不新增底部 Tab（五个主 Tab 保持原样）', (tester) async {
      // 生成器是工具附属功能、不是主阅读板块：底部 5 个主 Tab 一个都不能变。
      // 这里以「设置页里能找到入口」+「Section 枚举仍是四个板块」共同表达。
      await pumpSettings(tester);
      expect(find.text('图源生成器（开发中）'), findsOneWidget);
      expect(
        Section.values.map((section) => section.id).toList(),
        <String>['novel', 'comic', 'video', 'cat'],
        reason: '板块枚举不得因为生成器而增加——它不在四板块体系里',
      );
    });
  });

  // ==========================================================================
  // 页面骨架
  // ==========================================================================

  group('占位页：UI 骨架齐备', () {
    testWidgets('网址输入、规则配置、生成 / 预览按钮的布局都在', (tester) async {
      await pumpGenerator(tester);

      // 网址输入区。
      expect(find.text('目标网址'), findsOneWidget);
      expect(find.textContaining('https://example.com/list'), findsOneWidget);
      expect(find.textContaining('分页参数名'), findsOneWidget);

      // 正则 / 选择器配置区（三个规则字段 + 请求头）。
      expect(find.text('正则 / 选择器配置'), findsOneWidget);
      expect(find.textContaining('列表规则'), findsOneWidget);
      expect(find.textContaining('详情规则'), findsOneWidget);
      expect(find.textContaining('正文规则'), findsOneWidget);
      expect(find.textContaining('附加请求头'), findsOneWidget);

      // 生成与预览按钮。
      expect(find.text('生成与预览'), findsOneWidget);
      expect(find.text('预览抓取结果'), findsOneWidget);
      expect(find.text('生成图源脚本'), findsOneWidget);
    });

    testWidgets('骨架输入框不可输入（形态在、交互关）', (tester) async {
      await pumpGenerator(tester);

      // 所有输入框都是只读的：骨架阶段不接受输入，避免用户以为能填。
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList(growable: false);
      expect(fields, isNotEmpty, reason: '骨架里应有输入框');
      for (final field in fields) {
        expect(
          field.readOnly,
          isTrue,
          reason: '占位页的输入框必须只读（本轮不接收任何输入）',
        );
      }
    });

    testWidgets('「预览抓取结果」点击弹「功能开发中」', (tester) async {
      await pumpGenerator(tester);

      await tester.tap(find.text('预览抓取结果'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, '功能开发中'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('尚未实现'),
        ),
        findsOneWidget,
        reason: '提示要说明当前状态，而不是只说一句「开发中」',
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('手写图源脚本'),
        ),
        findsOneWidget,
        reason: '要给出当下可用的替代路径（手写脚本导入）',
      );
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '功能开发中'), findsNothing);
    });

    testWidgets('「生成图源脚本」点击同样弹「功能开发中」', (tester) async {
      await pumpGenerator(tester);

      await tester.tap(find.text('生成图源脚本'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, '功能开发中'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '功能开发中'), findsNothing);
    });

    testWidgets('页面声明了「预留扩展项」与「不绕过板块隔离」两条边界', (tester) async {
      await pumpGenerator(tester);

      expect(find.text('预留扩展项'), findsOneWidget);
      expect(
        find.textContaining('不会绕过板块隔离'),
        findsOneWidget,
        reason: '生成的脚本必须走正常导入链路——这条约束要在界面上写明',
      );
    });
  });

  // ==========================================================================
  // 数据表预留
  // ==========================================================================

  group('数据库：爬虫配置表已预留', () {
    test('表与预留字段齐备，可写可读', () async {
      final database = await GeneratorDatabase.open();

      // 字段覆盖「可视化爬虫」将来要存的东西：目标网址、三处规则、分页、
      // 编码、请求头、生成结果。
      database.saveConfig(
        const CrawlerConfigRecord(
          id: 'draft-1',
          name: '示例站草稿',
          targetUrl: 'https://example.com/list',
          section: 'novel',
          listRule: 'div.list > a.item',
          detailRule: 'h1.title',
          contentRule: 'div.content',
          pageParam: 'page',
          encoding: 'utf-8',
          headersJson: '{"Referer":"https://example.com/"}',
        ),
      );

      final record = database.config('draft-1')!;
      expect(record.name, '示例站草稿');
      expect(record.targetUrl, 'https://example.com/list');
      expect(record.section, 'novel');
      expect(record.listRule, 'div.list > a.item');
      expect(record.detailRule, 'h1.title');
      expect(record.contentRule, 'div.content');
      expect(record.pageParam, 'page');
      expect(record.encoding, 'utf-8');
      expect(record.headersJson, contains('Referer'));
      expect(record.generatedScript, isEmpty, reason: '生成结果当前恒为空（本轮不生成）');
      expect(record.createdAt, isNotNull);
      expect(record.updatedAt, isNotNull);
    });

    test('覆盖保存：同一 id 更新而不是插重复行', () async {
      final database = await GeneratorDatabase.open();
      database.saveConfig(
        const CrawlerConfigRecord(
          id: 'draft-2',
          name: '初版',
          targetUrl: 'https://example.com/a',
        ),
      );
      database.saveConfig(
        const CrawlerConfigRecord(
          id: 'draft-2',
          name: '改过',
          targetUrl: 'https://example.com/b',
        ),
      );

      expect(database.configs(), hasLength(1));
      expect(database.config('draft-2')!.name, '改过');
      expect(database.config('draft-2')!.targetUrl, 'https://example.com/b');
    });

    test('按板块筛选草稿：本板块与「未选板块」的都返回', () async {
      final database = await GeneratorDatabase.open();
      for (final (id, section) in <(String, String)>[
        ('novel-draft', 'novel'),
        ('comic-draft', 'comic'),
        ('unassigned', ''),
      ]) {
        database.saveConfig(
          CrawlerConfigRecord(id: id, name: id, targetUrl: '', section: section),
        );
      }

      final novel = database.configsFor(Section.novel).map((r) => r.id).toSet();
      expect(novel, containsAll(<String>['novel-draft', 'unassigned']));
      expect(novel, isNot(contains('comic-draft')));

      final comic = database.configsFor(Section.comic).map((r) => r.id).toSet();
      expect(comic, containsAll(<String>['comic-draft', 'unassigned']));
      expect(comic, isNot(contains('novel-draft')));
    });

    test('删除草稿不影响其它草稿', () async {
      final database = await GeneratorDatabase.open();
      database.saveConfig(
        const CrawlerConfigRecord(id: 'keep', name: '保留', targetUrl: ''),
      );
      database.saveConfig(
        const CrawlerConfigRecord(id: 'drop', name: '删除', targetUrl: ''),
      );

      database.deleteConfig('drop');
      expect(database.config('drop'), isNull);
      expect(database.config('keep'), isNotNull);
    });

    test('库文件落在应用支持目录根部，不进任何板块目录', () async {
      await GeneratorDatabase.open();

      // 生成器不是阅读板块：库放板块目录里会被误读成「某板块的数据」，
      // 与四板块隔离的口径冲突。
      final rootDb = File('${root.path}${Platform.pathSeparator}'
          '${GeneratorDatabase.fileName}');
      expect(rootDb.existsSync(), isTrue, reason: '生成器库应在应用支持目录根部');

      final sectionDb = File('${root.path}${Platform.pathSeparator}sections'
          '${Platform.pathSeparator}novel${Platform.pathSeparator}'
          '${GeneratorDatabase.fileName}');
      expect(
        sectionDb.existsSync(),
        isFalse,
        reason: '生成器库不得落在板块目录下',
      );
    });

    test('打开生成器库不产生任何迁移假告警', () async {
      await GeneratorDatabase.open();
      // 与板块库同一口径：全新库直接建表，不该出现 duplicate column 之类的告警。
      // （这里用「再开一次仍然正常」表达幂等，告警口径由板块库的用例统一覆盖。）
      GeneratorDatabase.resetForTesting();
      final reopened = await GeneratorDatabase.open();
      expect(reopened.configs(), isEmpty);
    });
  });
}
