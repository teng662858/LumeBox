import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_download_center.dart';
import 'package:lume_box/features/comic/download_center_page.dart';
import 'package:lume_box/features/download/download_selection.dart';
import 'package:lume_box/features/video/video_download_center.dart';
import 'package:lume_box/features/video/video_player_page.dart';

void main() {
  testWidgets('下载中心报告读取失败，恢复后可以在原页面重试', (tester) async {
    final root = Directory.systemTemp.createTempSync('download-retry-');
    addTearDown(() => root.deleteSync(recursive: true));
    var available = false;
    final videos = VideoDownloadCenter(directory: () async {
      if (!available) throw const FileSystemException('unavailable');
      return root;
    });
    final comics = ComicDownloadCenter(directory: () async => root);
    await tester.runAsync(comics.boot);
    await tester.pumpWidget(MaterialApp(home: DownloadCenterPage(center: comics, videoCenter: videos)));
    await tester.pump();
    expect(find.text('下载任务记录读取失败，已下载文件仍保留'), findsOneWidget);
    expect(find.textContaining('暂无下载任务'), findsNothing);
    available = true;
    await tester.runAsync(() async {
      await tester.tap(find.text('重新读取视频下载'));
      await videos.boot();
    });
    await tester.pumpAndSettle();
    expect(find.text('重新读取视频下载'), findsNothing);
    expect(find.textContaining('暂无下载任务'), findsOneWidget);
  });

  testWidgets('退出下载中心的动画期间离线地址就绪不会再打开播放器', (tester) async {
    final root = Directory.systemTemp.createTempSync('offline-back-');
    final videos = _DelayedVideoCenter(root);
    final comics = ComicDownloadCenter(directory: () async => root);
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      videos.dispose();
      comics.dispose();
      root.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await videos.boot();
      await comics.boot();
      await ReadingLibrary.open(Section.video);
    });
    videos.tasks.add(VideoDownloadTask(
      id: 'fixture', sourceId: 's', itemId: 'i', chapterId: 'c',
      title: '影片', chapterTitle: '正片', state: 'done', fileName: 'media.mp4',
    ));
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Scaffold(body: Text('首页'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) =>
        DownloadCenterPage(center: comics, videoCenter: videos)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离线播放'));
    expect(videos.started.isCompleted, true);
    nav.currentState!.pop();
    final local = _TrackedPlayback();
    videos.pending.complete(local);
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.text('首页'), findsOneWidget);
    expect(local.closed, true);
  });
  testWidgets('manual selection returns only chosen episodes in order', (
    tester,
  ) async {
    List<int>? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await selectDownloadChapters(context, const [
                    SourceChapter(id: '1', title: '第1集'),
                    SourceChapter(id: '2', title: '第2集'),
                    SourceChapter(id: '3', title: '第3集'),
                  ], initial: 1);
                },
                child: const Text('选择'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('第3集'));
    await tester.tap(find.text('第1集'));
    await tester.pump();
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(chosen, [0, 2]);
  });

  testWidgets('下载中心点猫源离线播放使用猫源进度库和站点管理器', (tester) async {
    final root = Directory.systemTemp.createTempSync('cat-offline-page-');
    final videos = VideoDownloadCenter(directory: () async => root);
    final comics = ComicDownloadCenter(directory: () async => root);
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      videos.dispose();
      comics.dispose();
      root.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await videos.boot();
      await comics.boot();
      await ReadingLibrary.open(Section.cat);
    });
    final task = VideoDownloadTask(
      section: Section.cat,
      id: VideoDownloadCenter.identity('sub|video|site', 'item', 'ep', section: Section.cat),
      sourceId: 'sub|video|site', itemId: 'item', chapterId: 'ep', title: '猫源离线',
      chapterTitle: '第2集', state: 'done', fileName: 'media.mp4',
    );
    videos.tasks.add(task);
    Directory(videos.folder(task)).createSync(recursive: true);
    videos.localFile(task).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(MaterialApp(home: DownloadCenterPage(center: comics, videoCenter: videos)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('离线播放'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final page = tester.widget<VideoPlayerPage>(find.byType(VideoPlayerPage));
    expect(page.media?.uri, videos.localFile(task).uri);
    expect(page.library?.section, Section.cat);
    expect(page.sourceManager, isA<CatAggregateSourceManager>());
    expect(page.target?.sourceId, task.sourceId);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'completed downloads expose play and export, and cancelling deletion retains the local file on small screens',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('download-page-');
      final videos = VideoDownloadCenter(directory: () async => root);
      final comics = ComicDownloadCenter(directory: () async => root);
      await tester.runAsync(() async {
        await videos.boot();
        await comics.boot();
      });
      final task = VideoDownloadTask(
        id: VideoDownloadCenter.identity('source', 'item', 'chapter'),
        sourceId: 'source',
        itemId: 'item',
        chapterId: 'chapter',
        title: '离线测试',
        chapterTitle: '第1集',
        state: 'done',
        fileName: 'video.mp4',
      );
      videos.tasks.add(task);
      Directory(videos.folder(task)).createSync(recursive: true);
      videos.localFile(task).writeAsBytesSync([1, 2, 3]);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadCenterPage(center: comics, videoCenter: videos),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('离线播放'), findsOneWidget);
      expect(find.text('保存到本地文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('删除下载'));
      await tester.tap(find.text('删除下载'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(videos.localFile(task).existsSync(), true);
      expect(videos.tasks, contains(task));
      task.fileName = 'index.m3u8';
      videos.notifyListeners();
      await tester.pump();
      expect(find.text('合并为 MP4'), findsOneWidget);
      task.state = 'merging';
      videos.notifyListeners();
      await tester.pump();
      expect(find.textContaining('正在合并 MP4'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('保存到本地文件'), findsNothing);
      task.state = 'merge_failed';
      videos.notifyListeners();
      await tester.pump();
      expect(find.text('重试合并'), findsOneWidget);
      expect(find.text('离线播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      videos.dispose();
      comics.dispose();
      root.deleteSync(recursive: true);
    },
  );
}

class _DelayedVideoCenter extends VideoDownloadCenter {
  _DelayedVideoCenter(Directory root) : super(directory: () async => root);
  final started = Completer<void>();
  final pending = Completer<DownloadedVideoPlayback?>();

  @override
  Future<DownloadedVideoPlayback?> completedPlayback(String sourceId, String itemId, String chapterId,
      {Section section = Section.video}) {
    started.complete();
    return pending.future;
  }
}

class _TrackedPlayback extends DownloadedVideoPlayback {
  _TrackedPlayback() : super(Uri.file('/fixture/media.mp4'));
  bool closed = false;
  @override
  Future<void> close() async { closed = true; }
}
