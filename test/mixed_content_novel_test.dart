import 'dart:io';
import 'dart:async';

import 'package:lume_box/core/speech/speech.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_content_type.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';
import 'package:lume_box/features/novel/novel_detail_page.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/features/video/video_detail_page.dart';

import 'support/fake_reading_source.dart';

class FakeNovelSpeech implements SpeechBackend {
  final controller = StreamController<SpeechEvent>.broadcast();
  final spoken = <String>[];
  int pauses = 0, resumes = 0, stops = 0;
  @override
  Stream<SpeechEvent> get events => controller.stream;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

class MixedSource extends FakeReadingDataSource {
  MixedSource() : super(section: Section.video);
  int reads = 0;
  bool failBody = false;
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    reads++;
    if (failBody) {
      throw const SourceException(SourceErrorKind.network, '正文暂时不可用');
    }
    return switch (itemId) {
      'comic' => const ImageContent(['https://fixture.invalid/1.jpg']),
      'novel' => TextContent(
        List.generate(
          80,
          (i) => '第 $i 段。清晨的风吹过山岗，远处的旅人沿着小路走来。这是用于检验排版与续读的正文。',
        ).join('\n\n'),
      ),
      _ => VideoContent(url: Uri.parse('https://fixture.invalid/episode.mp4')),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume-mixed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
    await MediaLibrary.instance.boot();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });

  test('文本契约保留段落、去除网页脚本，不把简介当正文', () {
    final text = ChapterContent.parse({
      'kind': 'html',
      'html': '<style>bad</style><p>甲&amp;乙</p><p>第二段<br>下一行</p><script>bad()</script>',
    }) as TextContent;
    expect(text.text, contains('甲&乙\n\n第二段\n下一行'));
    expect(text.text, isNot(contains('bad')));
    expect(
      () => ChapterContent.parse({'kind': 'text', 'description': '只是简介'}),
      throwsFormatException,
    );
    expect(
      SourceItem.parse({'id': 'a', 'title': 'b', 'contentType': 'novel'})!
          .mediaType,
      'novel',
    );
  });
  test('同一综合源逐作品识别三种载荷，探测结果只复用一次', () async {
    final source = MixedSource();
    for (final type in SourceContentType.values) {
      final result = await detectSourceContent(
        source: source,
        itemId: type.name,
        detail: null,
        chapters: const [SourceChapter(id: 'c1', title: '一')],
      );
      expect(result, type);
      final before = source.reads;
      await SourceContentRead.read(source, itemId: type.name, chapterId: 'c1');
      expect(source.reads, before);
      await SourceContentRead.read(source, itemId: type.name, chapterId: 'c1');
      expect(source.reads, before + 1);
    }
  });
  test('明确类型不提前解析，识别失败向页面报告', () async {
    final source = MixedSource()..failBody = true;
    expect(
      await detectSourceContent(
        source: source,
        itemId: 'novel',
        hint: 'text',
        detail: null,
        chapters: const [SourceChapter(id: 'c1', title: '一')],
      ),
      SourceContentType.novel,
    );
    expect(source.reads, 0);
    expect(
      detectSourceContent(
        source: source,
        itemId: 'unknown',
        detail: null,
        chapters: const [SourceChapter(id: 'c1', title: '一')],
      ),
      throwsA(isA<SourceException>()),
    );
  });
  test('压缩段落留白不改正文字符，排版高度确实减少', () {
    const text = '第一段原文🌸。\n\n第二段原文。\n \n第三段原文。';
    const style = TextStyle(fontSize: 20, height: 1.5);
    final span = novelBodySpan(text, style);
    expect(span.toPlainText(), text);
    final compact = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: 380);
    final original = TextPainter(
      text: const TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 380);
    expect(compact.height, lessThan(original.height));
    compact.dispose();
    original.dispose();
  });

  test('分页完整覆盖正文，支持大字体和表情，不切开代理对', () {
    final text = List.filled(150, '春风🌸吹过山岗。\n第二行还有文字。\n\n').join();
    for (final width in [220.0, 380.0]) {
      final starts = novelPageStarts(
        text,
        const TextStyle(fontSize: 22, height: 1.8),
        Size(width, 500),
        TextScaler.linear(1.4),
        TextDirection.ltr,
      );
      expect(starts.length, greaterThan(2));
      final pages = [
        for (var i = 0; i < starts.length; i++)
          text.substring(
            starts[i],
            i + 1 < starts.length ? starts[i + 1] : text.length,
          ),
      ];
      expect(pages.join(), text);
      for (final start in starts) {
        expect(
          text.codeUnitAt(start) >= 0xDC00 && text.codeUnitAt(start) <= 0xDFFF,
          isFalse,
        );
      }
    }
  });
  test('综合源的视频库重开后还原小说和漫画各自的进度形状', () async {
    library.recordHistoryItem(sourceId: 'mixed', itemId: 'book', title: '小说');
    library.saveProgress(
      NovelProgress(
        sourceId: 'mixed',
        section: Section.video,
        itemId: 'book',
        chapterIndex: 1,
        chapterId: 'c2',
        chapterTitle: '第二章',
        updatedAt: DateTime.now(),
        offset: 321,
        textLength: 900,
      ),
    );
    library.recordHistoryItem(sourceId: 'mixed', itemId: 'comic', title: '漫画');
    library.saveProgress(
      ComicProgress(
        sourceId: 'mixed',
        section: Section.video,
        itemId: 'comic',
        chapterIndex: 0,
        chapterId: 'c1',
        chapterTitle: '第一话',
        updatedAt: DateTime.now(),
        page: 3,
      ),
    );
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    library = await ReadingLibrary.open(Section.video);
    expect(
      (library.progress('book', sourceId: 'mixed') as NovelProgress).offset,
      321,
    );
    expect(
      (library.progress('comic', sourceId: 'mixed') as ComicProgress).page,
      3,
    );
    expect(library.progress('book', sourceId: 'other'), isNull);
  });
  for (final itemId in ['novel', 'comic']) {
    testWidgets('视频浏览入口自动打开 $itemId 的详情页', (tester) async {
      final source = MixedSource();
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            source: source,
            item: SourceItem(id: itemId, title: '综合作品'),
            library: library,
            onPlay: (_, _, _, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(itemId == 'novel' ? NovelDetailPage : ComicDetailPage),
        findsOneWidget,
      );
      expect(source.reads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('小说可朗读、暂停、继续并在切章时停止', (tester) async {
    final source = MixedSource();
    final backend = FakeNovelSpeech();
    final chapters = await source.chapters('novel');
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderPage(
          source: source,
          library: library,
          chapters: chapters,
          speechBackend: backend,
          target: const ReadingTarget(
            sourceId: 'fake.video',
            itemId: 'novel',
            title: '小说',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('朗读'));
    await tester.pump();
    expect(backend.spoken, isNotEmpty);
    await tester.tap(find.byTooltip('暂停朗读'));
    await tester.pump();
    expect(backend.pauses, 1);
    await tester.tap(find.byTooltip('朗读'));
    await tester.pump();
    expect(backend.resumes, 1);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(backend.stops, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    await backend.controller.close();
  });

  testWidgets('小说翻页记忆字符位置，换章、字号、重进均可用', (tester) async {
    final source = MixedSource();
    final chapters = await source.chapters('novel');
    const target = ReadingTarget(
      sourceId: 'fake.video',
      itemId: 'novel',
      title: '小说',
    );
    library.recordHistoryItem(
      sourceId: source.id,
      itemId: 'novel',
      title: '小说',
    );
    Widget reader() => MaterialApp(
      home: NovelReaderPage(
        source: source,
        library: library,
        target: target,
        chapters: chapters,
      ),
    );
    await tester.pumpWidget(reader());
    await tester.pumpAndSettle();
    expect(find.textContaining('第 0 段'), findsWidgets);
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    final checkpoint =
        library.progress('novel', sourceId: source.id) as NovelProgress;
    expect(
      checkpoint.offset,
      greaterThan(0),
      reason:
          'page=${tester.widget<PageView>(find.byType(PageView)).controller!.page}; count=${tester.widget<PageView>(find.byType(PageView)).childrenDelegate.estimatedChildCount}',
    );
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('护眼'));
    await tester.pumpAndSettle();
    expect(library.setting('novel.theme'), '1');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(reader());
    await tester.pumpAndSettle();
    expect(
      (library.progress('novel', sourceId: source.id) as NovelProgress).offset,
      checkpoint.offset,
    );
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(
      (library.progress(
        'novel',
        sourceId: source.id,
      ) as NovelProgress).chapterIndex,
      1,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
