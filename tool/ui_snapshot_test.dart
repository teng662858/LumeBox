/// 界面快照工具（开发期用，不参与常规测试）。
///
/// 为什么要有它：全局浅色主题这一轮改的是「看起来对不对」，`flutter analyze` 与
/// 单测都答不了这个问题——它们答得了「代码编得过、行为不变」，答不了「字会不会
/// 白底白字、卡片有没有分层、玻璃栏透不透」。所以把关键页面渲染成 PNG，人眼过一遍。
///
/// 运行：`flutter test tool/ui_snapshot_test.dart`
/// 产物：`build/ui_snapshot/*.png`
///
/// 两个让截图贴近真机的处理：
/// 1. **加载真字体**（Roboto + MaterialIcons）——测试环境默认用测试字体，
///    文字与图标都会画成方块，那样的截图看不出任何版面问题；
/// 2. **注入平台可用性**（`runtimeAvailable: true`）+ 替身图源——Android / Windows
///    上正式入口只会渲染骨架页，改由测试替身把真实页面拉起来。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import '../test/support/fake_reading_source.dart';
import '../test/support/fake_source_manager.dart';

const String _fontRoot = r'C:\flutter\bin\cache\artifacts\material_fonts';

/// 中文字形：Flutter 自带的 Roboto 没有汉字，不补这一份，截图里全是方块。
const String _cjkFont = r'C:\Windows\Fonts\Deng.ttf';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final path = '$_fontRoot\\$file';
      if (!File(path).existsSync()) continue;
      loader.addFont(
        File(path).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
      );
    }
    await loader.load();
  }

  await load('Roboto', <String>[
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]);
  await load('MaterialIcons', <String>['materialicons-regular.otf']);
  // 中文字形单独一个族：测试环境的字体管理器不会在族内按字形回退，
  // 因此把中文族名显式挂到主题的文字样式上（见 _snapshotTheme）。
  final cjk = FontLoader('CJK');
  if (File(_cjkFont).existsSync()) {
    cjk.addFont(
      File(_cjkFont).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
    );
  }
  await cjk.load();
}

/// 截图用的主题：在正式主题之上，把文字族换成带中文字形的族。
ThemeData _snapshotTheme() {
  final base = LumeTheme.build();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'CJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'CJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle:
          base.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'CJK'),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: LumeTheme.accent,
      unselectedLabelColor: LumeTheme.textSecondary,
      labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      dividerColor: Colors.transparent,
      indicatorColor: LumeTheme.accent,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory output;
  late ReadingLibrary comicLibrary;
  late ReadingLibrary novelLibrary;

  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_snapshot');
    output = Directory('build/ui_snapshot')..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    comicLibrary = await ReadingLibrary.open(Section.comic);
    novelLibrary = await ReadingLibrary.open(Section.novel);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  FakeSourceManager managerFor(Section section, {int chapterCount = 24}) =>
      FakeSourceManager(
        sources: <SourceDescriptor>[
          SourceDescriptor(
            id: 'a',
            name: '${section.label}示例源',
            version: '1.0',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{
          'a': FakeReadingDataSource(
            section: section,
            chapterCount: chapterCount,
            imageCount: 8,
          ),
        },
      );

  /// 渲染当前页面到 PNG。
  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final renderView = tester.binding.renderViews.first;
      final layer = renderView.debugLayer! as OffsetLayer;
      final image = await layer.toImage(renderView.paintBounds);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('${output.path}/$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(414, 896));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _snapshotTheme(),
        home: child,
      ),
    );
    // 不用 pumpAndSettle：个别页面（设置页的内核区间）有常驻动画/定时器，
    // 等「彻底静止」会一直等下去；固定推几帧足够把首屏数据与入场动画走完。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('诊断：模糊是否真的画出来了（条纹底上的磨砂条）', (tester) async {
    await pump(
      tester,
      Scaffold(
        body: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                for (var i = 0; i < 40; i++)
                  Container(
                    height: 22,
                    color: i.isEven
                        ? const Color(0xFFD32F2F)
                        : const Color(0xFF1565C0),
                  ),
              ],
            ),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 90,
                child: GlassPanel(
                  blur: 24,
                  color: Color(0x80FFFFFF),
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await capture(tester, '00_blur_diagnostic');
  });

  testWidgets('导航壳：底部玻璃 Dock（书架页）', (tester) async {
    comicLibrary.shelve(
      sourceId: 'a',
      itemId: 'item-1',
      title: '长夜将尽',
      subtitle: '作者 · 连载中',
      chapterCount: 40,
    );
    comicLibrary.shelve(
      sourceId: 'a',
      itemId: 'item-2',
      title: '山与海之间',
      subtitle: '作者 · 已完结',
      chapterCount: 12,
    );
    comicLibrary.saveProgress(
      ComicProgress(
        section: Section.comic,
        itemId: 'item-1',
        chapterIndex: 7,
        chapterId: 'c8',
        chapterTitle: '第 8 话',
        updatedAt: DateTime.now(),
        page: 3,
      ),
    );

    await pump(tester, const AppShell(desktopRail: false));
    await capture(tester, '01_shell_dock');
  });

  testWidgets('漫画详情页：模糊封面头 + 章节列表 + 批量下载入口', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: const ReadingTarget(
          sourceId: 'a',
          itemId: 'item-1',
          title: '长夜将尽',
        ),
        runtimeAvailable: true,
      ),
    );
    await capture(tester, '02_comic_detail');

    // 滚一段，看磨砂顶栏是否透出下方内容。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -260));
    await tester.pumpAndSettle();
    await capture(tester, '03_comic_detail_scrolled');
  });

  testWidgets('漫画详情页：下载范围面板', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: const ReadingTarget(
          sourceId: 'a',
          itemId: 'item-1',
          title: '长夜将尽',
        ),
        runtimeAvailable: true,
      ),
    );
    await tester.tap(find.byIcon(Icons.download_for_offline_outlined));
    await tester.pumpAndSettle();
    await capture(tester, '04_comic_download_sheet');
  });

  testWidgets('漫画阅读器：工具栏浮层', (tester) async {
    await pump(
      tester,
      ComicReaderPage(
        library: comicLibrary,
        dataSource: FakeReadingDataSource(
          section: Section.comic,
          chapterCount: 3,
          imageCount: 4,
        ),
        target: const ReadingTarget(
          sourceId: 'a',
          itemId: 'item-1',
          title: '长夜将尽',
        ),
        chapters: const <SourceChapter>[
          SourceChapter(id: 'c1', title: '第 1 话'),
          SourceChapter(id: 'c2', title: '第 2 话'),
          SourceChapter(id: 'c3', title: '第 3 话'),
        ],
        initialChapterIndex: 0,
        runtimeAvailable: true,
      ),
    );
    await tester.tapAt(const Offset(207, 500));
    await tester.pumpAndSettle();
    await capture(tester, '05_comic_reader_toolbar');
  });

  testWidgets('小说阅读页：自带阅读主题（浅色）', (tester) async {
    await pump(
      tester,
      NovelReaderPage(
        library: novelLibrary,
        dataSource: FakeReadingDataSource(
          section: Section.novel,
          chapterCount: 3,
          paragraphs: 40,
        ),
        target: const ReadingTarget(
          sourceId: 'a',
          itemId: 'item-1',
          title: '夜航船',
        ),
        chapters: const <SourceChapter>[
          SourceChapter(id: 'c1', title: '第一章'),
          SourceChapter(id: 'c2', title: '第二章'),
          SourceChapter(id: 'c3', title: '第三章'),
        ],
        initialChapterIndex: 0,
      ),
    );
    await tester.tapAt(const Offset(207, 500));
    await tester.pumpAndSettle();
    await capture(tester, '06_novel_reader');
  });

  testWidgets('视频板块：浏览页签', (tester) async {
    await pump(
      tester,
      VideoPage(sourceManager: managerFor(Section.video, chapterCount: 12)),
    );
    await capture(tester, '07_video_board');
  });

  testWidgets('漫画板块：书架 + 滚动后的玻璃顶栏', (tester) async {
    for (var index = 1; index <= 12; index++) {
      comicLibrary.shelve(
        sourceId: 'a',
        itemId: 'shelf-$index',
        title: '书架作品 $index',
        subtitle: '作者 · 连载中',
        chapterCount: 30,
      );
    }
    await pump(
      tester,
      ComicPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        runtimeAvailable: true,
      ),
    );
    await capture(tester, '11_comic_board_shelf');
    await tester.drag(find.byType(GridView), const Offset(0, -220));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await capture(tester, '12_comic_board_scrolled');
  });

  testWidgets('猫源板块', (tester) async {
    await pump(
      tester,
      const CatPage(),
    );
    await capture(tester, '08_cat_board');
  });

  testWidgets('设置页', (tester) async {
    await pump(
      tester,
      const SettingsPage(runtimeAvailable: true),
    );
    await capture(tester, '09_settings');
  });

  testWidgets('漫画详情页：批量下载结果卡', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic, chapterCount: 3),
        target: const ReadingTarget(
          sourceId: 'a',
          itemId: 'item-1',
          title: '长夜将尽',
        ),
        runtimeAvailable: true,
      ),
    );
    await tester.tap(find.byIcon(Icons.download_for_offline_outlined));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.tap(find.text('仅当前章'));
    // 测试环境的网络请求全被拦下：这张图看的是「结果卡长什么样」，不是下载成功。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      if (find.textContaining('下载完成').evaluate().isNotEmpty ||
          find.textContaining('下载结束').evaluate().isNotEmpty) {
        break;
      }
    }
    await capture(tester, '13_comic_download_card');
  });

  testWidgets('设置页：滚动后（看顶栏磨砂）', (tester) async {
    await pump(tester, const SettingsPage(runtimeAvailable: true));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await capture(tester, '10_settings_scrolled');
  });
}
