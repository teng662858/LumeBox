import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_download_center.dart';
import 'package:lume_box/features/comic/download_center_page.dart';
import 'package:lume_box/features/download/download_selection.dart';
import 'package:lume_box/features/video/video_download_center.dart';

void main() {
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
