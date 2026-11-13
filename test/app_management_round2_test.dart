import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/media/media_library.dart';

import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/net/network_activity.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_duplicates.dart';
import 'package:lume_box/core/source/source_capability_history.dart';
import 'package:lume_box/core/source/source_health.dart';
import 'package:lume_box/features/reading/continue_activity_page.dart';
import 'package:lume_box/features/reading/history_privacy.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/reading/search_results_page.dart';
import 'package:lume_box/features/video/video_detail_page.dart';
import 'package:lume_box/features/video/video_download_center.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/shared/widgets/network_waiting_view.dart';

import 'support/pump_io.dart';
import 'support/fake_source_manager.dart';
import 'support/fake_reading_source.dart';

class _DelayedSelectionManager extends FakeSourceManager {
  _DelayedSelectionManager(this.source) : super(sources: [
    SourceDescriptor(id: source.id, name: source.name, version: '', enabled: true),
  ]);
  final DataSource source;
  final pending = <Completer<DataSource?>>[];
  bool delaySelection = false;

  @override
  Future<DataSource?> open(String sourceId) async {
    if (sourceId != source.id) return null;
    if (!delaySelection) return source;
    final request = Completer<DataSource?>();
    pending.add(request);
    return request.future;
  }
}

class _ResumeCatService extends CatService {
  _ResumeCatService() : super.testing();

  @override
  Future<void> boot() async {}

  @override
  Future<Map<String, dynamic>> call(CatSite site, String operation, [
    Map<String, dynamic> body = const {},
  ]) async => operation == 'play'
      ? {'url': 'https://example.test/${body['id']}.mp4'}
      : {
          'list': [
            {'vod_id': 'movie', 'vod_name': '猫源续播', 'vod_play_from': 'A',
             'vod_play_url': r'第1集$one#第2集$two'},
          ],
        };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('management-round2');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
    await MediaLibrary.instance.boot();
    await AudioBookSettings.instance.load();
    await VideoDownloadCenter.instance.boot();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    NetworkActivity.finish('demo');
    await root.delete(recursive: true);
  });

  test('同域名只提示疑似重复，完全相同脚本单独报告', () {
    const a = SourceDescriptor(
      id: 'a',
      name: '甲',
      version: '1',
      enabled: true,
      siteUrl: 'https://www.example.test',
    );
    const b = SourceDescriptor(
      id: 'b',
      name: '乙',
      version: '2',
      enabled: false,
      siteUrl: 'https://example.test/path',
    );
    final groups = findSourceDuplicates([a, b], {'a': 'script', 'b': 'script'});
    expect(groups, hasLength(2));
    expect(groups.first.reason, '脚本内容完全相同');
    expect(groups.last.reason, contains('不一定重复'));
    expect(a.enabled, isTrue);
    expect(b.enabled, isFalse);
  });

  test('分项历史保留版本与检测时间，不把地址解析当实际播放', () {
    final library = ReadingLibrary.find(Section.video)!;
    SourceCapabilityHistory.save(library, 'source', '2', [
      const SourceHealthStep('运行环境与依赖', 'ok'),
      const SourceHealthStep('详情解析', 'ok'),
      const SourceHealthStep('正文／播放地址解析', 'ok'),
    ]);
    final summary = SourceCapabilityHistory.summary(library, 'source', '3');
    expect(summary, contains('旧版本检测'));
    expect(summary, contains('搜索：未测'));
    expect(summary, contains('地址解析：通过'));
    expect(summary, contains('检测时间：'));
    expect(library.setting('source.playback.last.source'), isNull);
  });

  testWidgets('等待提示可以查看来源、主机和等待时长，并取消单个请求', (tester) async {
    var cancelled = 0;
    NetworkActivity.register(
      'demo',
      WaitingNetworkRequest(
        label: '封面：演示源',
        host: 'images.example.test',
        method: 'GET',
        cancel: () => cancelled++,
      ),
    );
    NetworkActivity.setWaiting('demo', true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NetworkWaitingView(child: Center(child: Text('原页面'))),
        ),
      ),
    );
    await tester.tap(find.text('有请求正在等待网络连接，恢复后继续…'));
    await tester.pumpAndSettle();
    expect(find.text('封面：演示源'), findsOneWidget);
    expect(find.textContaining('GET images.example.test'), findsOneWidget);
    expect(find.textContaining('已等待'), findsOneWidget);
    await tester.tap(find.text('取消请求'));
    await tester.pump();
    expect(cancelled, 1);
    expect(find.text('没有等待中的请求'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收藏更新频率可以改为手动，不再随打开自动检查', (tester) async {
    final library = ReadingLibrary.find(Section.video)!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingHistorySheet(
            section: Section.video,
            library: library,
            initialTab: HistoryDrawerTab.favorites,
            onResume: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收藏更新频率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅手动检查'));
    await tester.pumpAndSettle();
    expect(library.setting('favorites.autoCheckMinutes'), '0');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('原来源无法打开时保留记录，并提供搜索其他来源', (tester) async {
    final library = ReadingLibrary.find(Section.video)!;
    library.recordHistoryItem(
      sourceId: 'missing',
      itemId: 'v',
      title: '仍然保留的视频',
    );
    library.saveProgress(
      VideoProgress(
        sourceId: 'missing',
        section: Section.video,
        itemId: 'v',
        chapterIndex: 1,
        chapterId: '2',
        chapterTitle: '第2集',
        updatedAt: DateTime.now(),
        position: const Duration(seconds: 75),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ContinueActivityPage(
          managers: {Section.video: FakeSourceManager()},
        ),
      ),
    );
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('仍然保留的视频'));
    await pumpIoAndSettle(tester);
    expect(find.text('原来源暂不可用，记录已保留'), findsOneWidget);
    expect(find.text('搜索其他来源'), findsOneWidget);
    expect(library.progress('v', sourceId: 'missing')!.chapterIndex, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('离开继续观看后，刚打开的片源不会盖住新页面', (tester) async {
    final source = FakeReadingDataSource(section: Section.video);
    final manager = _DelayedSelectionManager(source)..delaySelection = true;
    final library = ReadingLibrary.find(Section.video)!;
    library.recordHistoryItem(sourceId: source.id, itemId: 'item-1', title: '等待中的剧集');
    library.saveProgress(VideoProgress(
      sourceId: source.id, section: Section.video, itemId: 'item-1',
      chapterId: 'one', chapterIndex: 0, chapterTitle: '第一集',
      position: const Duration(seconds: 12), updatedAt: DateTime.now(),
    ));
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav,
      home: ContinueActivityPage(managers: {Section.video: manager}),
    ));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('等待中的剧集'));
    for (var i = 0; i < 50 && manager.pending.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(manager.pending, hasLength(1));
    nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('另一页面')),
    ));
    await tester.pump();
    manager.pending.single.complete(source);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(VideoDetailPage, skipOffstage: false), findsNothing);
    expect(find.text('另一页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  Future<_DelayedSelectionManager> openReplacementSearch(WidgetTester tester) async {
    final manager = _DelayedSelectionManager(FakeReadingDataSource(section: Section.video));
    final library = ReadingLibrary.find(Section.video)!;
    library.recordHistoryItem(sourceId: 'missing', itemId: 'v', title: '测试作品');
    library.saveProgress(VideoProgress(
      sourceId: 'missing', section: Section.video, itemId: 'v', chapterIndex: 0,
      chapterId: 'old', chapterTitle: '第1集', updatedAt: DateTime.now(),
      position: const Duration(seconds: 9),
    ));
    await tester.pumpWidget(MaterialApp(home: ContinueActivityPage(managers: {Section.video: manager})));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('测试作品'));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('搜索其他来源'));
    await pumpIoAndSettle(tester);
    await tester.tap(find.byKey(ValueKey('search-filter-${manager.source.id}')));
    await tester.pumpAndSettle();
    manager.delaySelection = true;
    return manager;
  }

  testWidgets('换源结果仍在打开时返回，不再弹出详情', (tester) async {
    final manager = await openReplacementSearch(tester);
    await tester.tap(find.byKey(ValueKey('search-hit-${manager.source.id}-item-1')));
    await tester.pump();
    expect(manager.pending, hasLength(1));
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    manager.pending.single.complete(manager.source);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(VideoDetailPage, skipOffstage: false), findsNothing);
    expect(find.byType(ContinueActivityPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('连续点击两个换源结果，只打开最后选择的作品', (tester) async {
    final manager = await openReplacementSearch(tester);
    for (final item in ['item-1', 'item-2']) {
      await tester.tap(find.byKey(ValueKey('search-hit-${manager.source.id}-$item')));
      await tester.pump();
    }
    expect(manager.pending, hasLength(2));
    manager.pending.first.complete(manager.source);
    await tester.pump();
    expect(find.byType(VideoDetailPage, skipOffstage: false), findsNothing);
    manager.pending.last.complete(manager.source);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final page = tester.widget<VideoDetailPage>(find.byType(VideoDetailPage, skipOffstage: false));
    expect(page.item.id, 'item-2');
    await tester.pumpWidget(const SizedBox());
  });

  const catSite = CatSite(
    subscriptionId: 'sub', kind: 'video', key: 'no-search', name: '已知站点',
    api: '/source', searchable: false,
  );
  const chapterId = '{"flag":"A","id":"two"}';
  void saveCatProgress(String sourceId) {
    final library = ReadingLibrary.find(Section.cat)!;
    final itemId = jsonEncode([sourceId, 'movie']);
    library.recordHistoryItem(sourceId: sourceId, itemId: itemId, title: '猫源续播');
    library.saveProgress(VideoProgress(
      sourceId: sourceId, section: Section.cat, itemId: itemId,
      chapterIndex: 1, chapterId: chapterId, chapterTitle: '第2集',
      updatedAt: DateTime.now(), position: const Duration(seconds: 75),
    ));
  }

  testWidgets('统一续看从不支持搜索的猫源站点恢复原集与进度', (tester) async {
    final service = _ResumeCatService();
    addTearDown(service.dispose);
    service.subscriptions.add(CatSubscription(id: 'sub', name: '订阅', url: '', sites: [catSite]));
    saveCatProgress(catSite.id);
    await tester.pumpWidget(MaterialApp(home: ContinueActivityPage(
      managers: {Section.cat: CatAggregateSourceManager(service)},
    )));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('猫源续播'));
    await pumpIoAndSettle(tester);
    final finder = find.byType(VideoDetailPage);
    expect(finder, findsOneWidget);
    final page = tester.widget<VideoDetailPage>(finder);
    expect(page.source?.id, catSite.id);
    expect(page.library.section, Section.cat);
    final dynamic state = tester.state(finder);
    expect(state.chapters[state.selected].id, chapterId);
    expect(state.episodeProgress(state.selected).position, const Duration(seconds: 75));
    final play = find.byKey(const Key('video-detail-play'));
    await Scrollable.ensureVisible(tester.element(play), alignment: 0.5);
    await tester.tap(play);
    await pumpIoAndSettle(tester);
    final player = tester.widget<VideoPlayerPage>(find.byType(VideoPlayerPage));
    expect(player.target?.chapterId, chapterId);
    expect(player.target?.resumePosition, const Duration(seconds: 75));
    expect(player.media?.uri.toString(), 'https://example.test/two.mp4');
    expect(player.library?.section, Section.cat);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('猫源原站不存在时，换源入口从磁盘读取猫源订阅', (tester) async {
    final service = CatService.instance;
    addTearDown(service.subscriptions.clear);
    final file = File('${root.path}/sections/cat/node/subscriptions.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'startupRecoveryVersion': 1,
      'subscriptions': [CatSubscription(id: 'sub', name: '订阅', url: '', sites: [catSite]).toJson()],
    }));
    saveCatProgress('missing|video|old');
    await tester.pumpWidget(const MaterialApp(home: ContinueActivityPage()));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('猫源续播'));
    await pumpIoAndSettle(tester);
    await tester.tap(find.text('搜索其他来源'));
    await pumpIoAndSettle(tester);
    final manager = tester.widget<SearchResultsPage>(find.byType(SearchResultsPage)).manager;
    expect(manager, isA<CatAggregateSourceManager>());
    expect((await manager!.open(catSite.id))?.id, catSite.id);
    expect(await manager.list(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('统一继续记录按时间汇总，不泄露已锁定板块标题', (tester) async {
    final video = ReadingLibrary.find(Section.video)!,
        comic = ReadingLibrary.find(Section.comic)!;
    video.recordHistoryItem(
      sourceId: 'video-source',
      itemId: 'v',
      title: '公开视频',
    );
    video.saveProgress(
      VideoProgress(
        sourceId: 'video-source',
        section: Section.video,
        itemId: 'v',
        chapterIndex: 1,
        chapterId: '2',
        chapterTitle: '第2集',
        updatedAt: DateTime.now(),
        position: const Duration(seconds: 75),
      ),
    );
    comic.recordHistoryItem(
      sourceId: 'comic-source',
      itemId: 'c',
      title: '私密漫画',
    );
    comic.saveProgress(
      ComicProgress(
        sourceId: 'comic-source',
        section: Section.comic,
        itemId: 'c',
        chapterIndex: 0,
        chapterId: '1',
        chapterTitle: '第一话',
        updatedAt: DateTime.now(),
        page: 3,
      ),
    );
    comic.setSetting(
      HistoryPrivacy.lockKey,
      'salt:${HistoryPrivacy.digest('salt', '123456')}',
    );
    await tester.pumpWidget(const MaterialApp(home: ContinueActivityPage()));
    await pumpIoAndSettle(tester);
    expect(find.text('公开视频'), findsOneWidget);
    expect(find.text('私密漫画'), findsNothing);
    expect(find.text('漫画记录已锁定'), findsOneWidget);
    expect(find.textContaining('第 2 集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
