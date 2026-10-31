import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/video/video_detail_page.dart';

import 'comic_detail_compare_preview.dart' as comic;
import 'video_detail_compare_preview.dart' as video;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LumeNet.boot();
  await TmdbSettings.instance.boot();
  final videoLibrary = await ReadingLibrary.open(Section.video);
  final comicLibrary = await ReadingLibrary.open(Section.comic);
  videoLibrary.setSetting('video.detail.originalStyle', 'true');
  final png = await comic.artwork('preview-video');
  final pipeline = SectionImagePipeline(
    cacheDir: videoLibrary.imageCacheDir,
    diskCache: false,
    requestSender: (request) async =>
        Uri.parse(request.url).host == 'preview.invalid'
        ? NetworkResponse(
            statusCode: 200,
            body: png,
            headers: {'content-type': 'image/png'},
          )
        : LumeNet.queue.send(request),
  );
  final images = <String, Uint8List>{};
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('详情与阅读状态预览 · 本地演示')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => VideoDetailPage(
                        source: video.DemoSource(),
                        item: const SourceItem(
                          id: 'detail-status-review',
                          title: '予苍龙',
                          cover: 'https://preview.invalid/poster.png',
                        ),
                        library: videoLibrary,
                        imagePipeline: pipeline,
                        recordHistory: false,
                        onPlay: (_, target, _, _) async =>
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('演示选择：${target.chapterTitle}'),
                              ),
                            ),
                      ),
                    ),
                  ),
                  child: const Text('详情页 · 底色与选集边框'),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ComicReaderPage(
                        library: comicLibrary,
                        dataSource: comic.DetailDemoSource(),
                        target: const ReadingTarget(
                          sourceId: 'demo_comic',
                          itemId: 'reader-glass-preview',
                          title: '星海旅人（本地演示）',
                        ),
                        chapters: [
                          for (var i = 1; i <= 12; i++)
                            SourceChapter(id: 'chapter-$i', title: '第$i话'),
                        ],
                        initialChapterIndex: 0,
                        runtimeAvailable: true,
                        pageBytes: (url) async => images[url] ??=
                            Uint8List.fromList(await comic.artwork(url)),
                      ),
                    ),
                  ),
                  child: const Text('漫画阅读页 · 时间与电量'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
