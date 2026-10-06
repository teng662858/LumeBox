import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/novel/novel_page_painter.dart';
import 'package:lume_box/features/novel/novel_pagination.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/features/novel/novel_turn_view.dart';
import 'package:lume_box/features/novel/novel_typesetting.dart';

import 'support/fake_reading_source.dart';

/// 小说阅读器与排版引擎的验证：分页落地、翻页推进字符偏移、模式与主题可切换、
/// 阅读主题独立于 App 主题，以及「分页结果真的能画出字」。
///
/// 阅读库在 [setUp] 打开（`testWidgets` 体内跑在 fake-async 时钟上，
/// 打开库要走真实异步的方法通道，必须放在真实时钟里）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary library;

  const target = ReadingTarget(
    sourceId: 'fake-src',
    itemId: 'item-1',
    title: '测试小说',
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_reader');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    library = await ReadingLibrary.open(Section.novel);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  List<SourceChapter> chapters(int count) => <SourceChapter>[
        for (var index = 1; index <= count; index++)
          SourceChapter(id: 'item-1-c$index', title: '第 $index 章'),
      ];

  Future<void> pumpReader(
    WidgetTester tester, {
    int initialCharOffset = 0,
    int paragraphCount = 60,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderPage(
          library: library,
          dataSource: FakeReadingDataSource(
            section: Section.novel,
            paragraphs: paragraphCount,
          ),
          target: target,
          chapters: chapters(3),
          initialChapterIndex: 0,
          initialCharOffset: initialCharOffset,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点击正文区：中间呼出工具栏，右侧翻下一页。
  Future<void> tapCenter(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
  }

  Future<void> tapNextPage(WidgetTester tester) async {
    await tester.tapAt(const Offset(370, 400));
    await tester.pumpAndSettle();
    // 进度落库有 700ms 去抖，推一格时钟让它写下去。
    await tester.pump(const Duration(milliseconds: 900));
  }

  testWidgets('打开即分页，并按章节 + 字符偏移落下进度', (tester) async {
    await pumpReader(tester);

    expect(find.byType(NovelTurnView), findsOneWidget);
    final progress = library.novelProgress(target.itemId);
    expect(progress, isNotNull);
    expect(progress!.chapterIndex, 0);
    expect(progress.charOffset, 0);
    expect(progress.chapterLength, greaterThan(0));
    // 进阅读器即入架，书架要能看到这本书。
    expect(library.onShelf(target.itemId), isTrue);
    expect(library.item(target.itemId)!.chapterCount, 3);
  });

  testWidgets('翻页推进字符偏移，进度按新位置落库', (tester) async {
    await pumpReader(tester);
    expect(library.novelProgress(target.itemId)!.charOffset, 0);

    await tapNextPage(tester);
    final advanced = library.novelProgress(target.itemId)!;
    expect(advanced.charOffset, greaterThan(0), reason: '第二页应从更靠后的字符开始');
    expect(advanced.chapterIndex, 0);

    await tapNextPage(tester);
    final further = library.novelProgress(target.itemId)!;
    expect(further.charOffset, greaterThan(advanced.charOffset));
  });

  testWidgets('续读：按保存的字符偏移回到当时那一页', (tester) async {
    await pumpReader(tester);
    await tapNextPage(tester);
    final savedOffset = library.novelProgress(target.itemId)!.charOffset;

    // 重新进阅读器（同一章，带偏移）。
    await pumpReader(tester, initialCharOffset: savedOffset);
    final restored = library.novelProgress(target.itemId)!;
    expect(
      restored.charOffset,
      savedOffset,
      reason: '按字符偏移恢复后，进度应落在同一页的起点',
    );
  });

  testWidgets('翻页模式可切换：上下滚动不再走翻页视图', (tester) async {
    await pumpReader(tester);
    await tapCenter(tester);

    await tester.tap(find.text('翻页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上下滚动'));
    await tester.pumpAndSettle();

    expect(
      library.setting(NovelTurnMode.settingKey),
      NovelTurnMode.scroll.id,
      reason: '翻页模式要落库，下次进阅读器仍然生效',
    );
    expect(find.byType(NovelTurnView), findsNothing);
    expect(find.byType(ListView), findsWidgets);
  });

  testWidgets('阅读主题独立于 App 主题：切到夜间深灰后整页换背景', (tester) async {
    await pumpReader(tester);
    await tapCenter(tester);

    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('夜间深灰'));
    await tester.pumpAndSettle();

    expect(NovelReaderTheme.load(library).id, NovelReaderTheme.night.id);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      scaffold.backgroundColor,
      NovelReaderTheme.night.background,
      reason: '阅读页背景应跟着阅读主题走，而不是 App 全局主题',
    );
  });

  testWidgets('排版参数可调：字号变化落库并触发重排', (tester) async {
    await pumpReader(tester);
    final before = NovelTypesetting.decode(
      library.setting(NovelTypesetting.settingKey),
    );

    await tapCenter(tester);
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();
    // 第一根滑杆是字号。
    await tester.drag(find.byType(Slider).first, const Offset(60, 0));
    await tester.pumpAndSettle();

    final after = NovelTypesetting.decode(
      library.setting(NovelTypesetting.settingKey),
    );
    expect(after.fontSize, greaterThan(before.fontSize));
    // 重排完成后仍然停在合法页上，进度照旧能落库。
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.novelProgress(target.itemId), isNotNull);
  });

  test('字号范围是宪法口径 12–36pt，且超范围一律钳位', () {
    // 宪法（文档第 3 部分第 2 节）规定字号 12-36pt。
    expect(NovelTypesetting.minFontSize, 12);
    expect(NovelTypesetting.maxFontSize, 36);

    // 上限放宽后，36 必须真的能设上（不能只是常量改了、钳位没跟上）。
    final atMax = const NovelTypesetting().copyWith(fontSize: 36);
    expect(atMax.fontSize, 36);

    // 超上限钳到 36、超下限钳到 12（不变式：参数永远落在区间内）。
    expect(const NovelTypesetting().copyWith(fontSize: 99).fontSize, 36);
    expect(const NovelTypesetting().copyWith(fontSize: 2).fontSize, 12);
  });

  test('旧库中大于上限的历史字号在读取时被钳回上限（升级口径修正）', () {
    // 模拟升级前的落库值：旧版本上限是 30，这里直接写一个 30 以上的值，
    // 等价于「历史数据里存在超出现行上限的字号」。
    final legacy = '{"fontSize": 48, "lineHeight": 1.8}';
    final decoded = NovelTypesetting.decode(legacy);

    expect(
      decoded.fontSize,
      NovelTypesetting.maxFontSize,
      reason: '超上限的历史值必须钳回上限（见 CHANGELOG：这是有意的口径修正）',
    );
    // 其余字段原样保留，钳位只作用于字号。
    expect(decoded.lineHeight, 1.8);
  });

  test('反序列化能读回上限值本身（36 不被误钳）', () {
    final encoded = const NovelTypesetting().copyWith(fontSize: 36).encode();
    expect(NovelTypesetting.decode(encoded).fontSize, 36);
  });

  testWidgets('分页结果能画出可见正文（CustomPainter + TextPainter）', (tester) async {
    const typesetting = NovelTypesetting();
    const viewport = Size(400, 800);
    const theme = NovelReaderTheme.parchment;
    final text = NovelChapterText.parse(
      FakeReadingDataSource(section: Section.novel, paragraphs: 8)
          .chapterText('item-1', 'item-1-c1'),
    );
    final pagination = const NovelPaginator().paginate(
      chapterId: 'item-1-c1',
      text: text,
      viewport: viewport,
      typesetting: typesetting,
    );
    final content = typesetting.contentSize(viewport);

    final canvas = NovelPageCanvas.build(
      page: pagination.pageAt(0),
      text: pagination.text,
      typesetting: typesetting,
      theme: theme,
      contentWidth: content.width,
    );
    addTearDown(canvas.dispose);

    final recorder = ui.PictureRecorder();
    final painter = Canvas(recorder);
    painter.drawRect(
      Offset.zero & viewport,
      Paint()..color = theme.background,
    );
    canvas.paint(
      painter,
      Offset(
        typesetting.margin,
        typesetting.margin + NovelTypesetting.headerHeight,
      ),
    );
    // 光栅化要真实事件循环：testWidgets 体内是 fake-async 时钟，
    // 直接 await toImage 会永远等不到，必须放进 runAsync。
    final picture = recorder.endRecording();
    final bytes = await tester.runAsync(() async {
      final image = await picture.toImage(
        viewport.width.round(),
        viewport.height.round(),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();
      return data;
    });

    expect(bytes, isNotNull);
    // 统计与背景色不同的像素：正文确实被画出来了，且占可观的面积。
    final data = bytes!.buffer.asUint8List();
    final background = theme.background.toARGB32();
    final bgR = (background >> 16) & 0xFF;
    final bgG = (background >> 8) & 0xFF;
    final bgB = background & 0xFF;
    var inked = 0;
    for (var index = 0; index + 3 < data.length; index += 4) {
      final dr = (data[index] - bgR).abs();
      final dg = (data[index + 1] - bgG).abs();
      final db = (data[index + 2] - bgB).abs();
      if (dr + dg + db > 30) inked++;
    }
    expect(
      inked,
      greaterThan(500),
      reason: '分页结果必须能画出成片的正文像素，而不是空页',
    );
  });
}
