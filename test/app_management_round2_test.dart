import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/media/media_library.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:lume_box/shared/widgets/network_waiting_view.dart';

import 'support/pump_io.dart';
import 'support/fake_source_manager.dart';

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
