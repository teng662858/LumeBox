import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/cat/cat_detail_page.dart';

class FixtureCat extends CatDataSource {
  FixtureCat(super.service, super.site, {super.chapterFlag});
  int parses = 0;
  Completer<VideoContent>? pending;
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    parses++;
    if (pending case final gate?) return gate.future;
    throw const SourceException(SourceErrorKind.network, 'fixture播放解析失败');
  }

  @override
  Future<Map<String, dynamic>> rawDetail(String itemId) async => {
    'vod_id': 'movie',
    'vod_name': '测试影片',
    'vod_pic': '',
    'vod_year': '2026',
    'vod_area': '大陆',
    'vod_actor': '演员甲,演员乙',
    'vod_content': '这是一段测试简介。' * 30,
    'vod_play_from': r'夸克原画$$$UC原画',
    'vod_play_url': [
      for (final count in [14, 3])
        [for (var i = 1; i <= count; i++) '第$i集\$https://video.test/$count/$i']
            .join('#'),
    ].join(r'$$$'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CatService service;
  late FixtureCat source;
  late ReadingLibrary library;
  const site = CatSite(
    subscriptionId: 'test',
    key: 'test',
    name: '测试站点',
    api: '/spider/test',
    kind: 'video',
  );
  setUp(() async {
    // This fixture checks source layout without external metadata requests.
    TmdbSettings.instance.enabled = false;
    root = Directory.systemTemp.createTempSync('cat_detail');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    service = CatService.testing();
    source = FixtureCat(service, site);
    library = await ReadingLibrary.open(Section.cat);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    await service.closeForTesting();
    root.deleteSync(recursive: true);
  });
  test('线路分组保持章节身份，播放器只能连续播放所选线路', () async {
    final chapters = await source.chapters('movie');
    final groups = CatDataSource.episodeLines(chapters);
    expect(groups['夸克原画']?.length, 14);
    expect(groups['UC原画']?.length, 3);
    final filtered = await FixtureCat(
      service,
      site,
      chapterFlag: 'UC原画',
    ).chapters('movie');
    expect(filtered.length, 3);
    expect(
      filtered.every((chapter) => CatDataSource.flagOf(chapter) == 'UC原画'),
      true,
    );
    expect(CatDataSource.labelOf(filtered.first), '第1集');
    expect(filtered.first.id, groups['UC原画']!.first.id);
  });
  testWidgets('猫源点击集号直接解析播放，失败停留详情，播放按钮可重试', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final item = source.item(await source.rawDetail('movie'))!;
    await tester.pumpWidget(
      MaterialApp(
        home: CatDetailPage(source: source, item: item, library: library),
      ),
    );
    await tester.pumpAndSettle();
    final episode = find.widgetWithText(OutlinedButton, '第2集');
    await tester.ensureVisible(episode);
    await tester.tap(episode);
    await tester.pumpAndSettle();
    expect(source.parses, 1);
    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.textContaining('fixture播放解析失败'), findsOneWidget);
    final play = find.widgetWithText(FilledButton, '播放 · 第2集');
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(source.parses, 2);
    expect(find.byType(CatDetailPage), findsOneWidget);
    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.textContaining('fixture播放解析失败'), findsOneWidget);
  });

  testWidgets('猫源详情退出时不打开刚解析完成的视频', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final pending = source.pending = Completer<VideoContent>();
    final item = source.item(await source.rawDetail('movie'))!;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav, home: const Scaffold(body: Text('列表')),
    ));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) =>
        CatDetailPage(source: source, item: item, library: library)));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(CatDetailPage));
    state.play(0);
    expect(source.parses, 1);
    nav.currentState!.pop();
    expect(state.mounted, isTrue);
    pending.complete(VideoContent(url: Uri.parse('https://fixture.test/video.mp4')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.text('列表'), findsOneWidget);
  });

  for (final mode in ['earlyExit', 'private', 'switchedLine']) {
    testWidgets('猫源播放返回后按本次观看更新剧集与线路（$mode）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final all = await source.chapters('movie');
      final item = source.item(await source.rawDetail('movie'))!;
      final other = CatDataSource.episodeLines(all)['UC原画']![1];
      void save(SourceChapter chapter, int index) {
        library.saveProgress(VideoProgress(
          section: Section.cat, sourceId: source.id, itemId: item.id,
          chapterId: chapter.id, chapterIndex: index, chapterTitle: chapter.title,
          position: const Duration(seconds: 20), duration: const Duration(minutes: 12),
          updatedAt: DateTime.now(),
        ));
      }
      save(all.first, 0);
      if (mode == 'private') library.setSetting('history.incognito', 'true');
      source.pending = Completer<VideoContent>()
        ..complete(VideoContent(url: Uri.parse('https://fixture.test/video.mp4')));
      await tester.pumpWidget(MaterialApp(
        home: CatDetailPage(source: source, item: item, library: library),
      ));
      await tester.pumpAndSettle();
      final episode = find.widgetWithText(OutlinedButton, '第2集');
      await tester.ensureVisible(episode);
      await tester.tap(episode);
      await tester.pumpAndSettle();
      final player = find.byType(VideoPlayerPage);
      final page = tester.widget<VideoPlayerPage>(player);
      expect(page.target?.chapterId, all[1].id);
      final reopened = await page.sourceManager!.open(source.id) as CatDataSource;
      expect(reopened.chapterFlag, isNull, reason: '播放器需要完整目录才能切换线路');
      if (mode == 'switchedLine') save(other, 1);
      Navigator.of(tester.element(player)).pop();
      await tester.pumpAndSettle();
      final dynamic detail = tester.state(find.byType(CatDetailPage));
      expect(detail.selectedChapterId, mode == 'switchedLine' ? other.id : all[1].id);
      expect(detail.line, mode == 'switchedLine' ? 'UC原画' : '夸克原画');
      expect(find.widgetWithText(FilledButton,
          mode == 'switchedLine' ? '继续播放 · 第2集' : '播放 · 第2集'), findsOneWidget);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('猫源详情$width宽按线路显示与完整选集，简介可收起', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final item = source.item(await source.rawDetail('movie'))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CatDetailPage(source: source, item: item, library: library),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试影片'), findsOneWidget);
      expect(find.text('全部 14 集'), findsOneWidget);
      expect(find.text('剧集与线路（17）'), findsNothing);
      await tester.ensureVisible(find.text('全部 14 集'));
      await tester.tap(find.text('全部 14 集'));
      await tester.pumpAndSettle();
      expect(find.text('选集'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('UC原画').last);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CatEpisodePicker),
          matching: find.text('第1集'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(CatEpisodePicker),
          matching: find.text('第4集'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
