import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';

/// Production detail-page comparison with explicitly labelled demo episodes.

import 'package:flutter/material.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_detail_page.dart';

import '../test/support/fake_reading_source.dart';
import 'comic_detail_compare_preview.dart' as comic;

class DemoSource extends FakeReadingDataSource {
  DemoSource() : super(section: Section.video);
  @override
  String get name => '详情样式演示';
  @override
  Future<SourceDetail?> detail(String id) async => const SourceDetail(
    id: 'demo',
    title: '予苍龙',
    cover: 'https://preview.invalid/poster.png',
    subtitle: '更新至10集 · 2026 · 剧情',
    description: '将门之女岳望舒被献祭龙渊，意外解封龙君离止。两人以压制离火为条件结盟，在联手对抗岳家与齐王的阴谋过程中，从敌对逐渐走向相知，并揭开彼此间的情感羁绊。',
  );
  @override
  Future<List<SourceChapter>> chapters(String id) async => [
    for (final line in ['高清线路', '备用线路', '长文件名演示'])
      for (var i = 1; i <= 10; i++)
        SourceChapter(
          id: '$line-$i',
          line: line,
          title: line == '长文件名演示'
              ? 'Drama.S01E${i.toString().padLeft(2, '0')}.2026.2160p.WEB-DL.mkv [1.7GB]'
              : i.toString().padLeft(2, '0'),
        ),
  ];
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LumeNet.boot();
  await TmdbSettings.instance.boot();
  final library = await ReadingLibrary.open(Section.video);
  library.setSetting('video.detail.originalStyle', 'false');
  for (final i in [1, 2, 3]) {
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'demo',
        chapterIndex: i - 1,
        chapterId: '高清线路-$i',
        chapterTitle: i.toString().padLeft(2, '0'),
        updatedAt: DateTime.now(),
        position: Duration(seconds: i < 3 ? 2390 : 756),
        duration: const Duration(minutes: 40),
      ),
    );
  }

  final bytes = await comic.artwork('preview-video');
  final pipeline = SectionImagePipeline(
    cacheDir: library.imageCacheDir,
    diskCache: false,
    requestSender: (request) async =>
        Uri.parse(request.url).host == 'preview.invalid'
        ? NetworkResponse(
            statusCode: 200,
            body: bytes,
            headers: {'content-type': 'image/png'},
          )
        : LumeNet.queue.send(request),
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('详情页对比 · 演示数据')),
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => VideoDetailPage(
                    source: DemoSource(),
                    item: const SourceItem(
                      id: 'demo',
                      title: '予苍龙',
                      cover: 'https://preview.invalid/poster.png',
                    ),
                    library: library,
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
              child: const Text('打开详情页（更多中切换两版）'),
            ),
          ),
        ),
      ),
    ),
  );
}
