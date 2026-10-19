import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/comic_image_tools.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/speech/speech_channel.dart';
import 'package:lume_box/core/speech/speech_session.dart';
import 'package:lume_box/core/speech/speech_settings.dart';
import 'package:lume_box/features/comic/comic_speech_text.dart';
import 'package:lume_box/features/comic/comic_bookmarks.dart';
import 'package:lume_box/features/comic/comic_page_composition.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_page_filters.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/comic/comic_reader_glyphs.dart';
import 'package:lume_box/features/comic/comic_reader_preferences.dart';
import 'package:lume_box/features/comic/comic_settings.dart';

import 'support/fake_reading_source.dart';

class _TranslationTools extends ComicImageTools {
  final pending = Completer<List<ComicTextRegion>>();
  @override
  Future<List<ComicTextRegion>> translate(Uint8List bytes) => pending.future;
}

class _CountingTranslationTools extends ComicImageTools {
  int calls = 0;
  @override
  Future<List<ComicTextRegion>> translate(Uint8List bytes) async {
    calls++;
    return const [
      ComicTextRegion(
        text: 'Text',
        translation: '译文',
        x: .1,
        y: .2,
        width: .5,
        height: .08,
      ),
    ];
  }
}

class _EmptyTranslationTools extends ComicImageTools {
  @override
  Future<List<ComicTextRegion>> translate(Uint8List bytes) async => [];
}

class _SpeechProbe extends MethodChannelSpeechBackend {
  final controller = StreamController<SpeechEvent>.broadcast();
  final spoken = <({String text, double rate, String voice})>[];
  SpeechSettings applied = const SpeechSettings();
  int stops = 0;
  @override
  void applySettings(SpeechSettings settings) {
    applied = settings;
  }

  @override
  Future<bool> isSupported() async => true;
  @override
  Stream<SpeechEvent> get events => controller.stream;
  void emit(SpeechEvent event) {
    if (!controller.isClosed) controller.add(event);
  }

  @override
  Future<void> speak(String text) async {
    spoken.add((text: text, rate: applied.rate, voice: applied.narratorVoice));
    emit(const SpeechEvent(SpeechEventKind.started));
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(const SpeechEvent(SpeechEventKind.stopped));
  }

  @override
  Future<void> pause() async => emit(const SpeechEvent(SpeechEventKind.paused));
  @override
  Future<void> resume() async =>
      emit(const SpeechEvent(SpeechEventKind.resumed));
}

class _SpeechTools extends ComicImageTools {
  Completer<List<ComicTextRegion>>? pending;
  static const regions = [
    ComicTextRegion(
      text: '第一句文字',
      translation: '',
      x: .1,
      y: .2,
      width: .5,
      height: .08,
    ),
    ComicTextRegion(
      text: '第二句文字',
      translation: '',
      x: .1,
      y: .5,
      width: .5,
      height: .08,
    ),
  ];
  @override
  Future<List<ComicTextRegion>> recognizeRegions(Uint8List bytes) async =>
      pending == null ? regions : pending!.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late Uint8List page;
  const captureKey = Key('reader.capture');

  setUpAll(() async {
    if (const bool.fromEnvironment('READER_PREVIEW')) {
      final cupertino = FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        );
      await cupertino.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File(
                'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        );
      await icons.load();
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('ReaderPreview')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_reader_experience');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    library = await ReadingLibrary.open(Section.comic);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/battery'),
          (_) async => 73,
        );
    // A neutral, original illustration exercises the actual decoded-image path.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(420, 880);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF8F4ED), Color(0xFF9BBCC7), Color(0xFF527E75)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      const Offset(300, 240),
      65,
      Paint()..color = const Color(0xFFF1C884),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 620)
        ..lineTo(120, 420)
        ..lineTo(250, 620)
        ..lineTo(350, 470)
        ..lineTo(420, 590)
        ..lineTo(420, 880)
        ..lineTo(0, 880)
        ..close(),
      Paint()..color = const Color(0xFF375F60),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(36, 140, 240, 100),
        const Radius.circular(4),
      ),
      Paint()..color = Colors.white,
    );
    final text = TextPainter(
      text: const TextSpan(
        text: 'A quiet afternoon.\nA new chapter begins.',
        style: TextStyle(
          color: Color(0xFF223B3C),
          fontSize: 18,
          fontFamily: bool.fromEnvironment('READER_PREVIEW')
              ? 'ReaderPreview'
              : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 220);
    text.paint(canvas, const Offset(50, 164));
    final picture = recorder.endRecording();
    final image = await picture.toImage(420, 880);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    page = data!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 35)),
      );
    }
    await tester.pump();
  }

  Future<void> pumpReader(
    WidgetTester tester, {
    Size size = const Size(420, 880),
    ComicImageTools? tools,
    SpeechBackend? speech,
    bool dark = false,
    String title = '山间来信',
    String chapterTitle = '第一章 · 午后的风',
    double textScale = 1,
    EdgeInsets safeInsets = EdgeInsets.zero,
    bool runtimeAvailable = true,
    int imageCount = 8,
    List<SourceChapter>? chapterList,
    int initialChapterIndex = 0,
    Future<bool> Function(Uint8List, String)? exporter,
    Future<Uint8List?> Function(String)? pageLoader,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: size,
              devicePixelRatio: 1,
              textScaler: TextScaler.linear(textScale),
              padding: safeInsets,
              viewPadding: safeInsets,
            ),
            child: child!,
          ),
          theme: ThemeData(
            useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: const bool.fromEnvironment('READER_PREVIEW')
                ? 'ReaderPreview'
                : null,
          ),
          home: ComicReaderPage(
            library: library,
            dataSource: FakeReadingDataSource(
              section: Section.comic,
              imageCount: imageCount,
            ),
            target: ReadingTarget(
              sourceId: 'fake-src',
              itemId: 'item-1',
              title: title,
            ),
            chapters:
                chapterList ??
                [
                  SourceChapter(id: 'item-1-c1', title: chapterTitle),
                  const SourceChapter(id: 'item-1-c2', title: '第二章 · 远方的信'),
                ],
            initialChapterIndex: initialChapterIndex,
            runtimeAvailable: runtimeAvailable,
            pageBytes: pageLoader ?? (_) async => page,
            imageExporter: exporter,
            imageTools: tools,
            speechBackend: speech,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('更多'));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text(item),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text(item));
    await settle(tester);
  }

  Finder activeMenu() => find
      .ancestor(
        of: find.byKey(const ValueKey('comic.menu.active')),
        matching: find.byType(Column),
      )
      .first;

  Finder activeText(String text) =>
      find.descendant(of: activeMenu(), matching: find.text(text));

  Future<void> selectMenuItem(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      activeText(text),
      130,
      scrollable: find.descendant(
        of: activeMenu(),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(activeText(text));
    await settle(tester);
  }

  Future<void> startSpeech(
    WidgetTester tester,
    _SpeechProbe speech,
    _SpeechTools tools, {
    Size size = const Size(420, 880),
  }) async {
    await pumpReader(tester, speech: speech, tools: tools, size: size);
    await menu(tester, '朗读');
    await tester.scrollUntilVisible(
      find.text('朗读本页'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await settle(tester);
    await tester.tap(find.text('朗读本页'));
    await settle(tester);
    Navigator.of(tester.element(find.byType(BottomSheet).last)).pop();
    await settle(tester);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('READER_PREVIEW')) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/reader-previews')
        ..createSync(recursive: true);
      File('${directory.path}/$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('进入阅读隐藏系统栏，后台恢复重申全屏，退出恢复系统栏', (tester) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpReader(tester);
    List<Object?> uiModes() => calls
        .where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
        .map((call) => call.arguments)
        .toList();
    expect(uiModes(), ['SystemUiMode.immersiveSticky']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(uiModes().last, 'SystemUiMode.immersiveSticky');
    expect(uiModes().length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(uiModes().last, 'SystemUiMode.edgeToEdge');
    calls.clear();
    await pumpReader(tester, runtimeAvailable: false);
    expect(uiModes(), isEmpty);
  });

  for (final spec in [
    (
      size: const Size(390, 844),
      safe: const EdgeInsets.only(top: 59, bottom: 34),
      scale: 1.0,
    ),
    (
      size: const Size(320, 640),
      safe: const EdgeInsets.only(top: 20),
      scale: 1.4,
    ),
    (
      size: const Size(844, 390),
      safe: const EdgeInsets.fromLTRB(59, 0, 59, 21),
      scale: 1.0,
    ),
  ]) {
    testWidgets('顶部状态区不重复留白且标题收紧 ${spec.size} ${spec.scale}', (tester) async {
      await pumpReader(
        tester,
        size: spec.size,
        safeInsets: spec.safe,
        textScale: spec.scale,
        title: '与乡村表妹间的恋爱喜剧～',
        chapterTitle: '01卷番外',
      );
      final time = tester.getRect(find.byKey(const Key('comic.status.time')));
      final battery = tester.getRect(
        find.byKey(const Key('comic.status.battery')),
      );
      final controls = tester.getRect(
        find.byKey(const Key('comic.top.controls')),
      );
      final title = tester.getRect(find.byKey(const Key('comic.top.title')));
      final exit = tester.getRect(find.byTooltip('退出阅读'));
      final direction = tester.getRect(find.byTooltip('阅读方向'));
      final more = tester.getRect(find.byTooltip('更多'));
      final statusHeight = spec.safe.top > 44 ? spec.safe.top : 44.0;
      expect(time.bottom, lessThanOrEqualTo(statusHeight));
      expect(battery.bottom, lessThanOrEqualTo(statusHeight));
      expect(controls.top, statusHeight + 6);
      expect(title.width, lessThanOrEqualTo(180));
      expect(title.height, greaterThanOrEqualTo(44));
      expect(exit.right, lessThan(title.left));
      expect(title.right, lessThan(direction.left));
      expect(more.right, lessThanOrEqualTo(spec.size.width - spec.safe.right));
      expect(find.byType(ComicReaderVerticalFlowGlyph), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(
        tester,
        spec.size.width == 390
            ? 'reader-notched-fixed'
            : spec.size.width == 320
            ? 'reader-narrow-fixed'
            : 'reader-landscape-fixed',
      );
      await tester.tap(find.byTooltip('阅读方向'));
      await settle(tester);
      expect(activeText('从右到左（日漫）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('阅读方向保留页位置并持久化，纵向连续滚动不吸附整页', (tester) async {
    await pumpReader(tester);
    await tester.drag(
      find.byKey(const Key('comic.pageSlider')),
      const Offset(60, 0),
    );
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 900));
    final before = library.comicProgress('item-1')!.page;
    expect(before, greaterThan(0));
    await tester.tap(find.byTooltip('阅读方向'));
    await settle(tester);
    await tester.tap(find.text('垂直滚动'));
    await settle(tester);
    expect(
      tester.widget<PageView>(find.byType(PageView)).scrollDirection,
      Axis.vertical,
    );
    expect(library.comicProgress('item-1')!.page, before);
    expect(ComicReaderPreferences.load(library).flow, 'vertical');
    final view = tester.widget<PageView>(find.byType(PageView));
    expect(view.pageSnapping, isFalse);
    // A slow partial gesture must retain its fractional offset on release.
    final start = view.controller!.page!;
    final gesture = await tester.startGesture(const Offset(200, 460));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 90));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await settle(tester);
    final end = view.controller!.page!;
    expect(end, greaterThan(start + .05));
    expect((end - end.round()).abs(), greaterThan(.05));
  });

  testWidgets('锁定缩放保留倍率及位置，解锁后仍保留并可双击还原', (tester) async {
    const ComicReaderSettings(doubleTapZoom: true).save(library);
    await pumpReader(tester, imageCount: 1);
    final viewer = find.byType(InteractiveViewer).first;
    final transform = tester
        .widget<InteractiveViewer>(viewer)
        .transformationController!;
    await tester.tapAt(const Offset(180, 410));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(180, 410));
    await settle(tester);
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2, .01));
    final matrix = transform.value.clone();
    await menu(tester, '缩放');
    await selectMenuItem(tester, '锁定缩放');
    Navigator.of(
      tester.element(find.byKey(const ValueKey('comic.menu.active'))),
    ).pop();
    await settle(tester);
    expect(transform.value, matrix);
    expect(tester.widget<InteractiveViewer>(viewer).scaleEnabled, isFalse);
    expect(tester.widget<InteractiveViewer>(viewer).panEnabled, isFalse);
    await menu(tester, '缩放');
    await selectMenuItem(tester, '锁定缩放');
    Navigator.of(
      tester.element(find.byKey(const ValueKey('comic.menu.active'))),
    ).pop();
    await settle(tester);
    expect(transform.value, matrix);
    expect(tester.widget<InteractiveViewer>(viewer).scaleEnabled, isTrue);
    await tester.tapAt(const Offset(180, 410));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(180, 410));
    await settle(tester);
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('纵向自动阅读连续移动，并可暂停及退出释放', (tester) async {
    const ComicReaderSettings(mode: ComicReadingMode.single).save(library);
    (ComicReaderPreferences()
          ..flow = 'vertical'
          ..autoSpeed = 120)
        .save(library);
    await pumpReader(tester);
    final controller = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    expect(controller.offset, 0);
    await tester.tap(find.byTooltip('自动滚动'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(controller.offset, greaterThan(50));
    expect(controller.offset, lessThan(200));
    final position = controller.offset;
    await tester.tap(find.byTooltip('自动滚动'));
    await tester.pump(const Duration(seconds: 2));
    expect(controller.offset, closeTo(position, .01));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('本系列翻译跨退出保存，关闭后不再自动启动', (tester) async {
    final tools = _CountingTranslationTools();
    await pumpReader(tester, tools: tools, imageCount: 2);
    await menu(tester, '翻译');
    await selectMenuItem(tester, '本系列');
    expect(tools.calls, 2);
    final annotations = jsonDecode(
      library.setting('comic.annotations.fake-src.item-1')!,
    );
    expect(annotations['translation.scope'], 'series');
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    final reopened = _CountingTranslationTools();
    await pumpReader(tester, tools: reopened, imageCount: 2);
    expect(reopened.calls, 2);
    await menu(tester, '翻译');
    await selectMenuItem(tester, '关闭');
    expect(
      jsonDecode(
        library.setting('comic.annotations.fake-src.item-1')!,
      )['translation.scope'],
      'off',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    final disabled = _CountingTranslationTools();
    await pumpReader(tester, tools: disabled, imageCount: 2);
    expect(disabled.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空 OCR 结果仍保留唯一翻译范围选中状态，当前页与本章独立', (tester) async {
    await pumpReader(tester, tools: _EmptyTranslationTools(), imageCount: 1);
    Future<void> check(String expected) async {
      await menu(tester, '翻译');
      for (final label in ['关闭', '当前页', '本章', '本系列']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: activeText(label), matching: find.byType(ListTile)),
        );
        expect(
          (tile.trailing is Icon ? (tile.trailing as Icon).icon : null) ==
              Icons.check,
          label == expected,
          reason: label,
        );
      }
    }

    await menu(tester, '翻译');
    await selectMenuItem(tester, '本系列');
    await check('本系列');
    await selectMenuItem(tester, '当前页');
    await check('当前页');
    await selectMenuItem(tester, '本章');
    await check('本章');
    await selectMenuItem(tester, '关闭');
    for (final label in ['当前页', '本章', '本系列']) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: activeText(label), matching: find.byType(ListTile)),
      );
      expect(tile.trailing, isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('长目录打开即定位当前章，倒序后仍定位且可跳章', (tester) async {
    final chapters = [
      for (var i = 0; i < 240; i++)
        SourceChapter(id: 'item-1-c${i + 1}', title: '第 ${i + 1} 章 · 山间来信'),
    ];
    await pumpReader(
      tester,
      chapterList: chapters,
      initialChapterIndex: 199,
      imageCount: 1,
    );
    await tester.tap(find.text(chapters[199].title).first);
    await settle(tester);
    final current = find.byKey(const ValueKey('comic.chapter.item-1-c200'));
    final list = tester.getRect(find.byKey(const Key('comic.chapters.list')));
    expect(current.hitTestable(), findsOneWidget);
    expect(
      tester.getCenter(current).dy,
      inInclusiveRange(list.top, list.bottom),
    );
    await tester.tap(find.byTooltip('章节顺序'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-chapter-manual-order')));
    await settle(tester);
    await tester.tap(find.text('倒序').last);
    await settle(tester);
    expect(current.hitTestable(), findsOneWidget);
    await capture(tester, 'chapters-current-position');
    await tester.tap(current);
    await settle(tester);
    expect(find.byKey(const Key('comic.chapters.list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画面调整落库且重置恢复所有滤镜', (tester) async {
    await pumpReader(tester);
    await menu(tester, '画面调整');
    expect(find.text('重置为默认').hitTestable(), findsOneWidget);
    await tester.drag(find.byType(Slider).at(1), const Offset(-90, 0));
    await settle(tester);
    expect(ComicReaderPreferences.load(library).brightness, lessThan(1));
    await tester.scrollUntilVisible(
      find.text('灰度'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.widgetWithText(SwitchListTile, '灰度'));
    await settle(tester);
    expect(ComicReaderPreferences.load(library).grayscale, isTrue);
    await tester.scrollUntilVisible(
      find.text('重置为默认'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('重置为默认'));
    await settle(tester);
    final preferences = ComicReaderPreferences.load(library);
    expect(preferences.grayscale, isFalse);
    expect(preferences.brightness, 1);
    expect(preferences.gamma, 1);
  });

  testWidgets('隐藏缩略图后滑块保留，恢复按钮立即生效', (tester) async {
    await pumpReader(tester);
    await menu(tester, '自定义工具栏…');
    await tester.tap(find.byKey(const Key('comic.toolbar.edit')));
    await settle(tester);
    final tile = find
        .ancestor(of: find.text('页面缩略图'), matching: find.byType(ListTile))
        .first;
    await tester.tap(find.descendant(of: tile, matching: find.byTooltip('隐藏')));
    await settle(tester);
    expect(
      ComicReaderPreferences.load(library).toolbar,
      isNot(contains('thumbnails')),
    );
    expect(ComicReaderPreferences.load(library).toolbar, contains('slider'));
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(find.byTooltip('页面缩略图'), findsNothing);
    expect(find.byKey(const Key('comic.pageSlider')), findsOneWidget);
  });

  testWidgets('睡眠定时到时停止自动阅读，卸载后不残留计时器', (tester) async {
    await pumpReader(tester);
    await menu(tester, '睡眠定时器');
    await tester.tap(find.text('5 分钟'));
    await settle(tester);
    await tester.tap(find.byTooltip('自动滚动'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(minutes: 5));
    await settle(tester);
    if (find.byTooltip('自动滚动').evaluate().isEmpty) {
      await tester.tapAt(const Offset(210, 300));
      await tester.pump(const Duration(milliseconds: 320));
      await settle(tester);
    }
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('自动滚动'),
        matching: find.byType(IconButton),
      ),
    );
    expect((button.icon as Icon).icon, Icons.play_arrow);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩略图点选跳到指定页', (tester) async {
    await pumpReader(tester);
    await tester.tap(find.byTooltip('页面缩略图'));
    await settle(tester);
    await tester.tap(find.text('3'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.comicProgress('item-1')!.page, 2);
  });

  testWidgets('换章后忽略旧章的异步翻译结果', (tester) async {
    final tools = _TranslationTools();
    await pumpReader(tester, tools: tools);
    await menu(tester, '翻译');
    await tester.tap(find.text('当前页'));
    await settle(tester);
    await tester.tap(find.byTooltip('下一章'));
    await settle(tester);
    tools.pending.complete(const [
      ComicTextRegion(
        text: 'old',
        translation: '旧章翻译',
        x: .1,
        y: .1,
        width: .3,
        height: .1,
      ),
    ]);
    await settle(tester);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .any(
            (widget) =>
                widget.painter is ComicTranslationPainter &&
                (widget.painter as ComicTranslationPainter).regions.any(
                  (region) => region.translation == '旧章翻译',
                ),
          ),
      isFalse,
    );
  });

  testWidgets('320 像素窄屏含全部工具按钮仍可操作', (tester) async {
    (ComicReaderPreferences()
          ..toolbar = ['auto', 'slider', 'thumbnails', 'chapters'])
        .save(library);
    await pumpReader(tester, size: const Size(320, 640));
    await menu(tester, '阅读模式');
    expect(tester.takeException(), isNull);
  });

  testWidgets('伽马滤镜改变实际像素，重置不污染原图', (tester) async {
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(page, targetWidth: 20);
      final original = (await codec.getNextFrame()).image;
      codec.dispose();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 20,
            height: 40,
            child: ComicPageFilters(
              image: original,
              gamma: 2,
              builder: (image) => RawImage(image: image),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      final filtered = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(identical(filtered, original), isFalse);
      final oldPixels = await original.toByteData();
      final newPixels = await filtered.toByteData();
      expect(newPixels!.getUint8(0), greaterThan(oldPixels!.getUint8(0)));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      original.dispose();
    });
  });

  testWidgets('宽图拆为两屏，翻半页时仍保存原图页号', (tester) async {
    const ComicReaderSettings(mode: ComicReadingMode.single).save(library);
    (ComicReaderPreferences()
          ..flow = 'ltr'
          ..splitWide = true)
        .save(library);
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 800, 400),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(800, 400);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      page = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    });
    await pumpReader(tester);
    final view = tester.widget<PageView>(find.byType(PageView));
    expect(view.childrenDelegate.estimatedChildCount, greaterThan(8));
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.comicProgress('item-1')!.page, 0, reason: '两个半页都属于原图第一页');
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.comicProgress('item-1')!.page, 1);
  });

  test('坏配置回退且工具栏滑块不可丢失', () {
    library.setSetting(
      ComicReaderPreferences.key,
      '{"brightness":-1,"gamma":999,"toolbar":["unknown","auto","auto"],"customZones":[9]}',
    );
    final settings = ComicReaderPreferences.load(library);
    expect(settings.brightness, .15);
    expect(settings.gamma, 2);
    expect(settings.toolbar, ['auto', 'slider']);
    expect(settings.customZones.length, 9);
    settings.save(library);
    expect(ComicReaderPreferences.load(library).gamma, 2);
  });

  testWidgets('工具栏左滑隐藏与恢复，滑块禁止滑走', (tester) async {
    await pumpReader(tester);
    await menu(tester, '自定义工具栏…');
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('comic.toolbar.thumbnails')),
      const Offset(-340, 0),
    );
    await settle(tester);
    expect(
      ComicReaderPreferences.load(library).toolbar,
      isNot(contains('thumbnails')),
    );
    await tester.drag(
      find.byKey(const ValueKey('comic.toolbar.slider')),
      const Offset(-340, 0),
    );
    await settle(tester);
    expect(ComicReaderPreferences.load(library).toolbar, contains('slider'));
    await tester.tap(
      find.byKey(const ValueKey('comic.toolbar.restore.thumbnails')),
    );
    await settle(tester);
    expect(
      ComicReaderPreferences.load(library).toolbar,
      contains('thumbnails'),
    );
    await tester.tap(find.byKey(const Key('comic.toolbar.edit')));
    await settle(tester);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    await capture(tester, 'toolbar-edit');
    await tester.timedDrag(
      find.descendant(
        of: find.byKey(const ValueKey('comic.toolbar.thumbnails')),
        matching: find.byIcon(Icons.drag_handle),
      ),
      const Offset(0, -160),
      const Duration(milliseconds: 800),
    );
    await settle(tester);
    expect(ComicReaderPreferences.load(library).toolbar.first, 'thumbnails');
    await tester.tap(find.byKey(const Key('comic.toolbar.edit')));
    await settle(tester);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
  });

  testWidgets('倍速真实下发且暂停切速不自行起播', (tester) async {
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    await startSpeech(tester, speech, _SpeechTools());
    expect(speech.spoken.single.rate, .5);
    await tester.tap(find.byKey(const Key('comic.speech.speed')));
    await settle(tester);
    await capture(tester, 'speech-speed');
    await tester.tap(find.text('1.5×'));
    await settle(tester);
    expect(speech.spoken.last.rate, .75);
    expect(
      SpeechSettings.decode(library.setting(SpeechSettings.settingKey)).rate,
      .75,
    );
    await tester.tap(find.byTooltip('暂停朗读'));
    await settle(tester);
    final count = speech.spoken.length;
    await tester.tap(find.byKey(const Key('comic.speech.speed')));
    await settle(tester);
    await tester.tap(find.text('0.75×'));
    await settle(tester);
    expect(speech.spoken.length, count);
    expect(speech.applied.rate, .375);
    await tester.tap(find.byTooltip('继续朗读'));
    await settle(tester);
    expect(speech.spoken.last.rate, .375);
    await tester.tap(find.byTooltip('停止朗读'));
    await settle(tester);
  });

  testWidgets('隐藏朗读栏保留语音，恢复后仍可暂停停止', (tester) async {
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    await startSpeech(tester, speech, _SpeechTools());
    final stops = speech.stops;
    await tester.tap(find.byTooltip('隐藏朗读栏'));
    await settle(tester);
    expect(speech.stops, stops);
    expect(find.byTooltip('暂停朗读'), findsNothing);
    await tester.tap(find.byTooltip('显示朗读栏'));
    await settle(tester);
    expect(find.byTooltip('暂停朗读'), findsOneWidget);
    await tester.tap(find.byTooltip('停止朗读'));
    await settle(tester);
    expect(speech.stops, greaterThan(stops));
    expect(find.byTooltip('显示朗读栏'), findsNothing);
    expect(find.byKey(const Key('comic.speech.highlight')), findsNothing);
  });

  testWidgets('语音进度同时更新文字与图片区域高亮，停止清除', (tester) async {
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    await startSpeech(tester, speech, _SpeechTools());
    speech.emit(const SpeechEvent(SpeechEventKind.progress, charOffset: 2));
    await settle(tester);
    TextSpan currentSpan() =>
        (tester
                        .widget<Text>(
                          find.byKey(const Key('comic.speech.highlight')),
                        )
                        .textSpan
                    as TextSpan)
                .children![1]
            as TextSpan;
    expect(currentSpan().text, '句');
    await capture(tester, 'speech-highlight');
    final before = tester.getRect(
      find.byKey(const ValueKey('comic.speech.region.0')),
    );
    speech.emit(const SpeechEvent(SpeechEventKind.progress, charOffset: 7));
    await settle(tester);
    expect(currentSpan().text, '二');
    expect(
      tester.getRect(find.byKey(const ValueKey('comic.speech.region.0'))).top,
      greaterThan(before.top),
    );
    await tester.tap(find.byTooltip('停止朗读'));
    await settle(tester);
    expect(find.byKey(const ValueKey('comic.speech.region.0')), findsNothing);
  });

  testWidgets('音色快捷选择枚举系统声音并保存下发', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          (call) async => call.method == 'speechVoices'
              ? [
                  {'id': 'voice-a', 'name': 'Tingting', 'language': 'zh-CN'},
                ]
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/speech'),
            null,
          ),
    );
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    await startSpeech(tester, speech, _SpeechTools());
    final voiceButton = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '声音与朗读设置',
      ),
    );
    await tester.tap(find.byTooltip('声音与朗读设置'));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('comic.menu.scroll.voices')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('layer.voices'))).bottom,
      closeTo(voiceButton.top - 8, 1),
    );
    await capture(tester, 'speech-voices');
    expect(find.text('Tingting · zh-CN'), findsNothing);
    await tester.tap(find.text('婷婷 · 普通话'));
    await settle(tester);
    expect(speech.spoken.last.voice, 'voice-a');
    expect(
      SpeechSettings.decode(library.setting(SpeechSettings.settingKey))
          .narratorVoice,
      'voice-a',
    );
    await tester.tap(find.byTooltip('声音与朗读设置'));
    await settle(tester);
    await tester.tap(find.text('自动'));
    await settle(tester);
    expect(speech.applied.narratorVoice, '');
    await tester.tap(find.byTooltip('停止朗读'));
    await settle(tester);
  });

  testWidgets('开始阅读区域提示自动消失且不改常驻开关', (tester) async {
    (ComicReaderPreferences()
          ..tapZones = 'horizontal'
          ..showZonesOnStart = true)
        .save(library);
    await pumpReader(tester);
    expect(find.byKey(const Key('comic.tapZonesOverlay')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(find.byKey(const Key('comic.tapZonesOverlay')), findsNothing);
    expect(ComicReaderPreferences.load(library).showZones, isFalse);
    await tester.tap(find.byTooltip('下一章'));
    await settle(tester);
    expect(find.byKey(const Key('comic.tapZonesOverlay')), findsNothing);
  });

  testWidgets('常驻区域预览不被启动提示计时器关闭', (tester) async {
    (ComicReaderPreferences()
          ..tapZones = 'horizontal'
          ..showZonesOnStart = true
          ..showZones = true)
        .save(library);
    await pumpReader(tester);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(find.byKey(const Key('comic.tapZonesOverlay')), findsOneWidget);
  });

  testWidgets('睡眠到时丢弃仍在进行的 OCR，不会迟到起播', (tester) async {
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    final tools = _SpeechTools()..pending = Completer<List<ComicTextRegion>>();
    await startSpeech(tester, speech, tools);
    await menu(tester, '睡眠定时器');
    await tester.tap(find.text('5 分钟'));
    await settle(tester);
    await tester.pump(const Duration(minutes: 5));
    await settle(tester);
    tools.pending!.complete(_SpeechTools.regions);
    await settle(tester);
    expect(speech.spoken, isEmpty);
    expect(find.byKey(const Key('comic.speech.highlight')), findsNothing);
  });

  test('OCR 偏移映射保留行边界及 UTF-16 表情字符', () {
    final page = ComicSpeechText(const [
      ComicTextRegion(
        text: ' 甲😀乙 ',
        translation: '',
        x: 0,
        y: 0,
        width: 1,
        height: .1,
      ),
      ComicTextRegion(
        text: '丙',
        translation: '',
        x: 0,
        y: .5,
        width: 1,
        height: .1,
      ),
    ]);
    expect(page.text, '甲😀乙\n丙');
    final cursor = ComicSpeechCursor('url', page, 2);
    expect(cursor.text.substring(cursor.start, cursor.end), '😀');
    expect(ComicSpeechCursor('url', page, 5).line!.region.text, '丙');
  });

  testWidgets('叠层菜单逐级返回，父层不可操作并保留滚动位置', (tester) async {
    await pumpReader(tester);
    await tester.tap(find.byTooltip('更多'));
    await settle(tester);
    await tester.drag(
      find.byKey(const ValueKey('comic.menu.scroll.main')),
      const Offset(0, -240),
    );
    await settle(tester);
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('comic.menu.scroll.main')),
        )
        .controller!;
    await selectMenuItem(tester, '翻译');
    final previousOffset = scroll.offset;
    expect(previousOffset, greaterThan(0));
    final parent = find.byKey(const ValueKey('comic.menu.parent.main'));
    expect(parent, findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: parent, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );
    await capture(tester, 'menu-translation-stack');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(parent, findsNothing);
    expect(scroll.offset, closeTo(previousOffset, 1));
    await selectMenuItem(tester, '阅读模式');
    await selectMenuItem(tester, '背景');
    expect(
      find.byKey(const ValueKey('comic.menu.parent.reading')),
      findsOneWidget,
    );
    await selectMenuItem(tester, 'OLED 纯黑');
    expect(
      ComicReaderSettings.load(library).background,
      ComicReaderBackground.black,
    );
    await capture(tester, 'menu-background-stack');
    await tester.tap(
      find.descendant(of: activeMenu(), matching: find.byTooltip('返回')),
    );
    await settle(tester);
    expect(activeText('阅读模式'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byKey(const ValueKey('comic.menu.active')), findsOneWidget);
    await tester.tapAt(const Offset(8, 250));
    await settle(tester);
    expect(find.byKey(const ValueKey('comic.menu.active')), findsNothing);
  });

  testWidgets('横屏叠层菜单保持边界，长菜单可滚动', (tester) async {
    await pumpReader(tester, size: const Size(740, 340));
    await menu(tester, '阅读模式');
    await selectMenuItem(tester, '阅读方向');
    final rect = tester.getRect(activeMenu());
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(340));
    await capture(tester, 'menu-landscape');
    await selectMenuItem(tester, '双页跨页');
    expect(ComicReaderPreferences.load(library).flow, 'spread');
    expect(find.byKey(const ValueKey('comic.menu.active')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字与深色阅读背景的浮层保持可读可用', (tester) async {
    const ComicReaderSettings(background: ComicReaderBackground.black)
        .save(library);
    await pumpReader(
      tester,
      size: const Size(320, 640),
      dark: true,
      textScale: 1.4,
      title: '一部有非常非常长的作品名称用来检查标题截断',
      chapterTitle: '第一千零一章 · 山间来信与一场尚未结束的漫长旅行',
    );
    await capture(tester, 'reader-small-dark');
    await menu(tester, '标记');
    await selectMenuItem(tester, '红色');
    final labelContext = tester.element(activeText('红色'));
    expect(Theme.of(labelContext).brightness, Brightness.light);
    await capture(tester, 'menu-small-dark');
    await tester.tapAt(const Offset(8, 300));
    await settle(tester);
    await tester.tap(find.text('第一千零一章 · 山间来信与一场尚未结束的漫长旅行'));
    await settle(tester);
    await capture(tester, 'chapters-small-dark');
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空图片章节的工具菜单禁用分享，关闭后可退出', (tester) async {
    await pumpReader(tester, imageCount: 0);
    expect(find.byKey(const Key('comic.pageSlider')), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await settle(tester);
    final share = find.ancestor(
      of: activeText('分享页面'),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(share).onTap, isNull);
    await capture(tester, 'reader-empty-menu');
    await tester.tapAt(const Offset(8, 250));
    await settle(tester);
    expect(find.byKey(const ValueKey('comic.menu.active')), findsNothing);
    expect(find.byTooltip('退出阅读'), findsOneWidget);
  });

  testWidgets('书签列表展示备注并跨章编辑，取消及清空不误写当前位置', (tester) async {
    final bookmark = ComicBookmark(
      chapterIndex: 1,
      chapterId: 'item-1-c2',
      chapterTitle: '第二章 · 远方的信',
      page: 2,
      createdAt: DateTime.now(),
    );
    library.setSetting(
      ComicBookmarks.keyFor('item-1'),
      ComicBookmarks.encode([bookmark]),
    );
    const key = 'comic.annotations.fake-src.item-1';
    library.setSetting(
      key,
      jsonEncode({
        'page-note:item-1-c2:2': '远章备注',
        'page-note:item-1-c1:0': '当前页内容',
        'flag:item-1-c1': 'red',
      }),
    );
    await pumpReader(tester);
    await menu(tester, '书签');
    await selectMenuItem(tester, '所有书签');
    expect(find.text('远章备注'), findsOneWidget);
    await capture(tester, 'bookmark-notes');
    await tester.tap(find.byTooltip('编辑书签备注'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '修改后的远章备注');
    final concurrent =
        jsonDecode(library.setting(key)!) as Map<String, dynamic>;
    concurrent['flag:item-1-c1'] = 'blue';
    library.setSetting(key, jsonEncode(concurrent));
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('修改后的远章备注'), findsOneWidget);
    var notes = jsonDecode(library.setting(key)!);
    expect(notes['page-note:item-1-c2:2'], '修改后的远章备注');
    expect(notes['page-note:item-1-c1:0'], '当前页内容');
    expect(notes['flag:item-1-c1'], 'blue');
    await tester.tap(find.byTooltip('编辑书签备注'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '取消的内容');
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('修改后的远章备注'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑书签备注'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('修改后的远章备注'), findsNothing);
    expect(
      ComicBookmarks.decode(library.setting(ComicBookmarks.keyFor('item-1'))),
      hasLength(1),
    );
    await tester.tap(find.text(bookmark.describe()));
    await settle(tester);
    expect(library.comicProgress('item-1')!.chapterIndex, 1);
    expect(library.comicProgress('item-1')!.page, 2);
    await tester.tapAt(const Offset(210, 300));
    await settle(tester);
    await menu(tester, '书签');
    await selectMenuItem(tester, '所有书签');
    expect(find.text(bookmark.describe()), findsOneWidget);
    await tester.tap(find.byTooltip('删除书签'));
    await settle(tester);
    expect(
      ComicBookmarks.decode(library.setting(ComicBookmarks.keyFor('item-1'))),
      isEmpty,
    );
  });

  testWidgets('分享页面发送合成 PNG；异步期间换页仍分享点击时的页及设置', (tester) async {
    (ComicReaderPreferences()
          ..flow = 'ltr'
          ..brightness = .55
          ..inverted = true
          ..cropRatio = .1)
        .save(library);
    const ComicReaderSettings(mode: ComicReadingMode.single).save(library);
    Uint8List? exported;
    String? name;
    var gate = false, calls = 0;
    final pending = Completer<Uint8List?>();
    await pumpReader(
      tester,
      pageLoader: (_) => gate ? pending.future : Future.value(page),
      exporter: (bytes, filename) async {
        calls++;
        exported = bytes;
        name = filename;
        return true;
      },
    );
    gate = true;
    await menu(tester, '分享页面');
    expect(calls, 0);
    tester.widget<Slider>(find.byKey(const Key('comic.pageSlider'))).onChanged!(
      3,
    );
    await tester.pump();
    pending.complete(page);
    await settle(tester);
    expect(calls, 1);
    expect(name, '1.png');
    expect(exported, isNotNull);
    expect(exported!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(exported!);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      expect(image.width, 336);
      expect(image.height, 704);
      expect(exported, isNot(orderedEquals(page)));
      if (const bool.fromEnvironment('READER_PREVIEW')) {
        File('build/reader-previews/share-current-page.png')
            .writeAsBytesSync(exported!);
      }
      image.dispose();
    });
    expect(
      tester.widget<Slider>(find.byKey(const Key('comic.pageSlider'))).value,
      3,
    );
  });

  testWidgets('当前页译文进入分享图片，导出失败后可以重试', (tester) async {
    final tools = _TranslationTools();
    Uint8List? exported;
    var fail = true;
    await pumpReader(
      tester,
      tools: tools,
      exporter: (bytes, name) async {
        if (fail) throw StateError('测试导出失败');
        exported = bytes;
        return true;
      },
    );
    await menu(tester, '翻译');
    await selectMenuItem(tester, '当前页');
    tools.pending.complete(const [
      ComicTextRegion(
        text: 'test',
        translation: 'HELLO',
        x: .6,
        y: .7,
        width: .3,
        height: .12,
      ),
    ]);
    await settle(tester);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .any(
            (widget) =>
                widget.painter is ComicTranslationPainter &&
                (widget.painter as ComicTranslationPainter).regions.any(
                  (r) => r.translation == 'HELLO',
                ),
          ),
      isTrue,
    );
    await menu(tester, '分享页面');
    expect(find.textContaining('测试导出失败'), findsOneWidget);
    fail = false;
    await menu(tester, '分享页面');
    expect(exported, isNotNull);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(exported!);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      final pixels = (await image.toByteData())!.buffer.asUint8List();
      final offset =
          ((image.height * .7).round() + 4) * image.width * 4 +
          ((image.width * .6).round() + 4) * 4;
      expect(pixels[offset], greaterThan(240));
      expect(pixels[offset + 1], greaterThan(240));
      expect(pixels[offset + 2], greaterThan(240));
      if (const bool.fromEnvironment('READER_PREVIEW')) {
        File('build/reader-previews/share-translated-page.png')
            .writeAsBytesSync(exported!);
      }
      image.dispose();
    });
  });

  testWidgets('分享进行中退出不会弹出系统分享或在已销毁页面更新状态', (tester) async {
    var gate = false, exports = 0;
    final pending = Completer<Uint8List?>();
    await pumpReader(
      tester,
      pageLoader: (_) => gate ? pending.future : Future.value(page),
      exporter: (bytes, name) async {
        exports++;
        return true;
      },
    );
    gate = true;
    await menu(tester, '分享页面');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(page);
    await settle(tester);
    expect(exports, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('音色查询空列表可恢复自动且继续朗读', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          (call) async => call.method == 'speechVoices' ? [] : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/speech'),
            null,
          ),
    );
    library.setSetting(
      SpeechSettings.settingKey,
      const SpeechSettings(narratorVoice: 'missing-voice').encode(),
    );
    final speech = _SpeechProbe();
    addTearDown(speech.controller.close);
    await startSpeech(tester, speech, _SpeechTools());
    await tester.tap(find.byTooltip('声音与朗读设置'));
    await settle(tester);
    expect(find.textContaining('暂不可用'), findsOneWidget);
    await tester.tap(find.text('自动'));
    await settle(tester);
    expect(speech.applied.narratorVoice, '');
    expect(speech.spoken.last.voice, '');
    expect(find.byTooltip('暂停朗读'), findsOneWidget);
    expect(find.byKey(const Key('comic.status.time')), findsOneWidget);
    await tester.tap(find.byTooltip('停止朗读'));
    await settle(tester);
  });

  testWidgets('长音色浮层贴近声音按钮，横屏和窄屏可滚动选末项', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          (call) async => call.method == 'speechVoices'
              ? [
                  for (var i = 0; i < 40; i++)
                    {'id': 'voice-$i', 'name': '设备声音 $i', 'language': 'zh-CN'},
                ]
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/speech'),
            null,
          ),
    );
    for (final size in [const Size(760, 320), const Size(320, 620)]) {
      final speech = _SpeechProbe();
      addTearDown(speech.controller.close);
      await startSpeech(tester, speech, _SpeechTools(), size: size);
      expect(speech.spoken, isNotEmpty);
      final button = tester.getRect(find.byTooltip('声音与朗读设置'));
      await tester.tap(find.byTooltip('声音与朗读设置'));
      await settle(tester);
      final panel = tester.getRect(find.byKey(const ValueKey('layer.voices')));
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.bottom, lessThanOrEqualTo(button.top - 7));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(size.width));
      await tester.scrollUntilVisible(
        find.text('设备声音 39 · 普通话'),
        100,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('comic.menu.scroll.voices')),
          matching: find.byType(Scrollable),
        ),
      );
      await settle(tester);
      await capture(
        tester,
        size.width > size.height ? 'voices-landscape' : 'voices-small',
      );
      await tester.tap(find.text('设备声音 39 · 普通话'));
      await settle(tester);
      expect(speech.applied.narratorVoice, 'voice-39');
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('真实图片阅读器与菜单预览', (tester) async {
    await pumpReader(tester);
    expect(find.byType(RawImage), findsWidgets);
    await capture(tester, 'reader');
    await tester.tap(find.byTooltip('更多'));
    await settle(tester);
    await capture(tester, 'menu');
    await tester.tap(find.text('画面调整'));
    await settle(tester);
    await capture(tester, 'adjustments');
    Navigator.of(tester.element(find.byType(BottomSheet).last)).pop();
    await settle(tester);
    await tester.tap(find.text('第一章 · 午后的风'));
    await settle(tester);
    await capture(tester, 'chapters');
    expect(tester.takeException(), isNull);
  });
}
