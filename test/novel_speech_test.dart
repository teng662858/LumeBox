import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/speech/speech.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/features/novel/novel_speech_panel.dart';

import 'support/fake_reading_source.dart';

/// 阅读器听书接线的验证：开始 / 暂停 / 继续 / 停止、跟读翻页、连听下一章、
/// 设置落库，以及「平台不支持时如实显示占位」。
///
/// 语音后端用替身注入（[NovelReaderPage.speechBackend]）——原生合成器挡在
/// [SpeechBackend] 端口后面，因此 Windows 上也能把整条链路验完。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary library;
  late _FakeSpeechBackend backend;

  const target = ReadingTarget(
    sourceId: 'fake-src',
    itemId: 'item-1',
    title: '测试小说',
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_speech');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    library = await ReadingLibrary.open(Section.novel);
    backend = _FakeSpeechBackend();
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
    int paragraphCount = 60,
    int chapterCount = 3,
    SpeechBackend? speechBackend,
    DataSource? dataSource,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderPage(
          library: library,
          dataSource: dataSource ??
              FakeReadingDataSource(
                section: Section.novel,
                paragraphs: paragraphCount,
              ),
          target: target,
          chapters: chapters(chapterCount),
          initialChapterIndex: 0,
          speechBackend: speechBackend ?? backend,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点正文中间呼出工具栏与底部面板。
  Future<void> openToolbar(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
  }

  /// 切到底部面板的「听书」页签。
  Future<void> openSpeechPanel(WidgetTester tester) async {
    await openToolbar(tester);
    await tester.tap(find.text('听书'));
    await tester.pumpAndSettle();
  }

  group('能力探测', () {
    testWidgets('平台不支持：面板显示占位说明，入口按钮提示原因', (tester) async {
      backend.supported = false;
      await pumpReader(tester);
      await openSpeechPanel(tester);

      expect(find.byType(NovelSpeechPanel), findsOneWidget);
      expect(find.textContaining('仅'), findsWidgets, reason: '要说明为什么用不了');
      expect(find.text('开始朗读'), findsNothing, reason: '不支持时不该给可点的开始按钮');
    });

    testWidgets('原生未接入（走真实通道）也会如实降级', (tester) async {
      // 不注入替身：MethodChannelSpeechBackend 在测试环境拿不到原生实现，
      // isSupported 应如实返回 false，而不是抛异常。
      await pumpReader(tester, speechBackend: MethodChannelSpeechBackend());
      await openSpeechPanel(tester);

      expect(find.byType(NovelSpeechPanel), findsOneWidget);
      expect(find.text('开始朗读'), findsNothing);
    });

    testWidgets('支持：面板出现开始按钮与三个滑杆', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);

      expect(find.text('开始朗读'), findsOneWidget);
      expect(find.text('语速'), findsOneWidget);
      expect(find.text('音调'), findsOneWidget);
      expect(find.text('音量'), findsOneWidget);
      expect(find.text('跟读翻页'), findsOneWidget);
    });
  });

  group('朗读控制', () {
    testWidgets('开始朗读：从当前页首字符开始，只下发第一片', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);

      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      expect(backend.spoken, hasLength(1), reason: '一次只下发一片');
      expect(backend.spoken.single, isNotEmpty);
      expect(find.textContaining('朗读中'), findsWidgets);
    });

    testWidgets('暂停 / 继续 / 停止：按钮语义随状态变化', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      expect(find.text('暂停'), findsOneWidget);
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(backend.paused, 1);
      expect(find.text('继续'), findsOneWidget);

      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(backend.resumed, 1);
      expect(find.text('暂停'), findsOneWidget);

      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      expect(backend.stopped, greaterThan(0));
      expect(find.text('开始朗读'), findsOneWidget, reason: '停止后回到可开始状态');
    });

    testWidgets('控制栏的耳机按钮也能一键开始 / 暂停', (tester) async {
      await pumpReader(tester);
      await openToolbar(tester);

      await tester.tap(find.byIcon(Icons.headphones_outlined));
      await tester.pumpAndSettle();
      expect(backend.spoken, hasLength(1));

      await tester.tap(find.byIcon(Icons.pause_circle_outline));
      await tester.pumpAndSettle();
      expect(backend.paused, 1);
    });

    testWidgets('本章无可朗读内容时给出提示而不是静默失败', (tester) async {
      // 段落数 0 → 章节文本为空。
      await pumpReader(tester, paragraphCount: 0);
      await openToolbar(tester);
      await tester.tap(find.byIcon(Icons.headphones_outlined));
      await tester.pumpAndSettle();

      expect(backend.spoken, isEmpty);
      expect(find.textContaining('没有可朗读的内容'), findsOneWidget);
    });

    testWidgets('退出阅读器：会话被释放，朗读停止', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(backend.stopped, greaterThan(0), reason: '退出时必须停掉原生合成器');
    });
  });

  group('跟读翻页', () {
    testWidgets('朗读位置推进时自动翻到对应页', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      // 直接推一个靠后的位置：应翻到后面某页（进度随之变化）。
      final before = library.novelProgress(target.itemId)!.charOffset;
      backend.emit(SpeechEventKind.progress, charOffset: 400);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));

      final after = library.novelProgress(target.itemId)!.charOffset;
      expect(after, greaterThan(before), reason: '跟读应把进度推到朗读位置所在页');
    });

    testWidgets('关掉跟读：位置推进不再翻页', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);

      // 关掉「跟读翻页」开关。
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      final before = library.novelProgress(target.itemId)!.charOffset;
      backend.emit(SpeechEventKind.progress, charOffset: 400);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));

      expect(
        library.novelProgress(target.itemId)!.charOffset,
        before,
        reason: '关掉跟读后翻页不受朗读位置影响',
      );
    });
  });

  group('连续听书', () {
    testWidgets('本章读完自动进下一章接着读', (tester) async {
      await pumpReader(tester);
      await openToolbar(tester);
      await tester.tap(find.byIcon(Icons.headphones_outlined));
      await tester.pumpAndSettle();
      final chapterBefore = library.novelProgress(target.itemId)!.chapterIndex;

      // 把本章所有片段都读完。
      for (var i = 0; i < 60; i++) {
        if (backend.spoken.isEmpty) break;
        backend.emit(SpeechEventKind.finished);
        await tester.pumpAndSettle();
      }

      expect(
        library.novelProgress(target.itemId)!.chapterIndex,
        greaterThan(chapterBefore),
        reason: '连听应推进到下一章',
      );
      expect(backend.spoken, isNotEmpty, reason: '新章要继续朗读');
    });

    testWidgets('连听换章失败：重试后不该自动开始朗读（意图必须已作废）', (tester) async {
      // 复现修复前的缺陷：`_speechResumeAfterLoad` 只在加载**成功**路径上被清掉。
      // 连听换章时那一章加载失败 → 标志一直挂着 true → 用户之后点「重试」
      // （或任何一次章节加载）时，页面会莫名其妙自己开始朗读。
      final flaky = _FlakyReadingDataSource(
        section: Section.novel,
        paragraphs: 60,
      )..failFromChapter = 'item-1-c3';
      await pumpReader(tester, dataSource: flaky, chapterCount: 8);
      await openToolbar(tester);
      await tester.tap(find.byIcon(Icons.headphones_outlined));
      await tester.pumpAndSettle();

      // 一路读到第 3 章：那一章加载失败（连听意图因此没能被消费掉）。
      for (var i = 0; i < 12; i++) {
        if (backend.spoken.isEmpty) break;
        backend.emit(SpeechEventKind.finished);
        await tester.pumpAndSettle();
      }
      // 失败后页面是错误态：先停掉朗读，再点重试。
      if (find.text('停止').evaluate().isNotEmpty) {
        await tester.tap(find.text('停止'));
        await tester.pumpAndSettle();
      }
      final spokenAfterStop = backend.spoken.length;
      expect(find.text('重试'), findsOneWidget, reason: '这一章应处于失败态');

      // 数据源恢复后点重试：章节加载成功，但不该因此开始朗读。
      flaky.failFromChapter = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(
        backend.spoken.length,
        spokenAfterStop,
        reason: '重试成功不该自动开始朗读（失败路径上的连听意图必须已作废）',
      );
    });

    testWidgets('用户停止后不再自动连播', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      final chapterAfterStop = library.novelProgress(target.itemId)!.chapterIndex;
      final spokenAfterStop = backend.spoken.length;

      // 停止后引擎补发 finished 不该触发连播。
      backend.emit(SpeechEventKind.finished);
      await tester.pumpAndSettle();

      expect(library.novelProgress(target.itemId)!.chapterIndex, chapterAfterStop);
      expect(backend.spoken.length, spokenAfterStop);
    });
  });

  group('设置', () {
    testWidgets('语速改动落库并下发给后端', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);

      // 拖动「语速」滑杆（第一根）。
      final sliders = find.byType(Slider);
      expect(sliders, findsWidgets);
      await tester.drag(sliders.first, const Offset(-60, 0));
      await tester.pumpAndSettle();

      final saved = SpeechSettings.decode(
        library.setting(SpeechSettings.settingKey),
      );
      expect(saved.rate, lessThan(0.5), reason: '左拖应降低语速');
    });

    testWidgets('跟读开关落库', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final saved = SpeechSettings.decode(
        library.setting(SpeechSettings.settingKey),
      );
      expect(saved.followAlong, isFalse);
    });

    testWidgets('设置跨会话保留：重进阅读器仍是上次的语速', (tester) async {
      await pumpReader(tester);
      await openSpeechPanel(tester);
      await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
      await tester.pumpAndSettle();
      final saved = SpeechSettings.decode(
        library.setting(SpeechSettings.settingKey),
      );

      // 先退出阅读器（清掉页面状态），再重新进入——否则 pumpWidget 复用同一个
      // State，读到的还是内存里的旧值，验不出「落库后能读回来」。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await pumpReader(tester);
      await openSpeechPanel(tester);
      final reloaded = SpeechSettings.decode(
        library.setting(SpeechSettings.settingKey),
      );
      expect(reloaded.rate, saved.rate);
    });
  });
}

/// 替身语音后端：记录调用、按需推事件。
class _FakeSpeechBackend implements SpeechBackend {
  bool supported = true;

  final List<String> spoken = <String>[];
  int paused = 0;
  int resumed = 0;
  int stopped = 0;

  final StreamController<SpeechEvent> _events =
      StreamController<SpeechEvent>.broadcast();

  void emit(SpeechEventKind kind, {int? charOffset, String? message}) {
    _events.add(SpeechEvent(kind, charOffset: charOffset, message: message));
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopped++;

  @override
  Future<void> pause() async => paused++;

  @override
  Future<void> resume() async => resumed++;

  @override
  Stream<SpeechEvent> get events => _events.stream;
}

/// 可切换失败状态的数据源替身：用来复现「加载失败」这条路径。
///
/// 不能直接用 [FakeReadingDataSource] 的 `fail`——它在构造时就固定了，
/// 而这条用例要的是「先成功后失败、再成功」。
class _FlakyReadingDataSource extends FakeReadingDataSource {
  _FlakyReadingDataSource({required super.section, super.paragraphs});

  /// 章节 id 后缀：从这个后缀起（含）的章节加载都失败；null 表示不失败。
  String? failFromChapter;

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    final from = failFromChapter;
    if (from != null && chapterId.compareTo(from) >= 0) {
      throw const SourceException(SourceErrorKind.callFailed, '测试源暂时失败');
    }
    return super.content(itemId: itemId, chapterId: chapterId);
  }
}
