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
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/novel/novel_page.dart';
import 'package:lume_box/features/video/video_page.dart';

import 'support/fake_source_manager.dart';

/// 板块页右上角入口的回归：**「图源管理」必须打开本板块专属的图源管理页**。
///
/// 背景（用户反馈的 UI 路由 Bug）：视频页右上角原来放的是「播放器设置」，
/// 点进去看不到任何图源——导入成功的源因此没有任何入口可用。现在四个板块
/// 统一为「图源管理」+「+」；播放器设置搬到播放器控制栏的齿轮与全局设置页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_board_entry');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    await SectionScope.open(Section.novel);
    await SectionScope.open(Section.comic);
    await SectionScope.open(Section.video);
    // 阅读库在真实时钟里先打开：testWidgets 的 fake-async 里等不到真实异步。
    await ReadingLibrary.open(Section.novel);
    await ReadingLibrary.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpBoard(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: page),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('小说板块：右上角「图源管理」打开本板块管理页', (tester) async {
    await pumpBoard(
      tester,
      NovelPage(runtimeAvailable: true, manager: FakeSourceManager()),
    );

    expect(find.byTooltip('源管理'), findsOneWidget);
    await tester.tap(find.byTooltip('源管理'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '小说 · 源管理'), findsOneWidget);
    expect(find.text('暂无源'), findsOneWidget, reason: '展示的是本板块源列表');
  });

  testWidgets('漫画板块：右上角「图源管理」，原有入口照旧', (tester) async {
    await pumpBoard(
      tester,
      ComicPage(runtimeAvailable: true, manager: FakeSourceManager()),
    );

    expect(find.byTooltip('源管理'), findsOneWidget);
    expect(find.byTooltip('扩展仓库'), findsOneWidget);
    // 「图片缓存」入口已按用户要求移除（缓存本体的管理在设置 → 缓存管理）。
    expect(find.byTooltip('图片缓存'), findsNothing);

    await tester.tap(find.byTooltip('源管理'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '漫画 · 源管理'), findsOneWidget);
  });

  testWidgets('视频板块：右上角是「图源管理」，不再是播放器设置', (tester) async {
    await pumpBoard(tester, const VideoPage(catalog: _NoKernelCatalog()));

    // 关键回归：右上角不再有「播放器设置」。
    expect(find.byTooltip('源管理'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('播放器设置'),
      ),
      findsNothing,
      reason: '播放器设置不该再占着板块页右上角',
    );
    if (Platform.isIOS) {
      // 「+」导入按平台边界只在有图源运行时的平台出现。
      expect(find.byTooltip('添加源'), findsOneWidget);
    }

    await tester.tap(find.byTooltip('源管理'));
    await tester.pumpAndSettle();

    // 视频板块管理页（本平台无图源运行时，页面按骨架展示，标题口径一致）。
    expect(find.widgetWithText(AppBar, '视频 · 源管理'), findsOneWidget);
  });

  testWidgets('猫源板块：页面本身就是本板块图源管理页', (tester) async {
    await pumpBoard(tester, const CatPage());

    // 猫源没有独立的业务页：板块页即图源管理页，标题与其他板块同一口径。
    expect(find.widgetWithText(AppBar, '猫源 · 源管理'), findsOneWidget);
  });

  testWidgets('图源管理页：导入的源可见、可启停，操作收进「更多」', (tester) async {
    final manager = FakeSourceManager(
      sources: const <SourceDescriptor>[
        SourceDescriptor(
          id: 'demo',
          name: '公开样片测试源',
          version: '1.0.0',
          enabled: false,
        ),
      ],
    );
    await pumpBoard(
      tester,
      NovelPage(runtimeAvailable: true, manager: manager),
    );
    await tester.tap(find.byTooltip('源管理'));
    await tester.pumpAndSettle();

    expect(find.text('公开样片测试源'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    // 启用开关：写回本板块的管理器。
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(manager.toggled.single, ('demo', true));

    // 重命名 / 导出 / 删除 / 浏览都在「更多」里。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    for (final action in <String>['浏览', '重命名', '导出脚本', '删除']) {
      expect(find.text(action), findsOneWidget, reason: '缺少操作：$action');
    }
  });
}

/// 没有可用内核的目录（视频板块只渲染骨架；本用例只关心路由）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '本平台仅保留骨架';
}
