// Demo data only; renders the production comic and gallery detail page.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';

import '../test/support/fake_reading_source.dart';
import '../test/support/fake_source_manager.dart';

class DetailDemoSource extends FakeReadingDataSource {
  DetailDemoSource({this.gallery = false}) : super(section: Section.comic);
  final bool gallery;
  @override
  String get id => gallery ? 'demo_gallery' : 'demo_comic';
  @override
  String get name => gallery ? '光影图集 · 演示源' : '星河书屋 · 演示源';
  @override
  Future<SourceDetail?> detail(String itemId) async => SourceDetail(
    id: itemId,
    title: gallery ? '春日光影 · 城市漫步' : '星河漫游',
    cover: 'https://preview.invalid/${gallery ? 'gallery' : 'comic'}/cover.png',
    author: gallery ? '示例摄影师' : '示例作者',
    status: gallery ? null : '连载中',
    tags: gallery ? const ['风景', '摄影'] : const ['科幻', '冒险', '成长'],
    updatedAt: DateTime(2026, 10, 24),
    description: gallery ? '沿着城市的小路，记录春日的光影与色彩。这是一组用于界面预览的演示图集。' : '一次意外的星际信号，让少年踏上寻找失落文明的旅程。他和伙伴穿越陌生星球，在浩瀚星海中逐渐发现自己的身世。这里展示的是演示数据，用来对比新版和原版详情页。',
  );
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => gallery
      ? const [SourceChapter(id: 'album', title: '完整图集')]
      : [
          for (var i = 1; i <= 48; i++)
            SourceChapter(id: 'chapter-$i', title: '第$i话'),
        ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => ImageContent([
    for (var i = 1; i <= 8; i++)
      'https://preview.invalid/${gallery ? 'gallery' : 'comic'}/$i.png',
  ]);
}

Future<List<int>> artwork(String url) async {
  final photo = url.contains('gallery');
  final number =
      int.tryParse(Uri.parse(url).pathSegments.last.split('.').first) ?? 0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const bounds = Rect.fromLTWH(0, 0, 330, 450);
  final shades = photo
      ? [const Color(0xff91c7bb), const Color(0xffe9d8a8)]
      : [const Color(0xff172343), const Color(0xff715da7)];
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: shades,
      ).createShader(bounds),
  );
  if (photo) {
    canvas.drawCircle(
      Offset(240 - number * 5.0, 110),
      60,
      Paint()..color = const Color(0xffffe8b1),
    );
    final path = Path()
      ..moveTo(0, 330)
      ..lineTo(100, 190 + number * 8)
      ..lineTo(240, 350)
      ..lineTo(330, 250)
      ..lineTo(330, 450)
      ..lineTo(0, 450)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xff517f79));
  } else {
    for (var i = 0; i < 45; i++) {
      canvas.drawCircle(
        Offset((i * 71 % 330).toDouble(), (i * 41 % 350).toDouble()),
        i % 3 == 0 ? 2 : 1,
        Paint()..color = Colors.white54,
      );
    }
    canvas.drawCircle(
      const Offset(250, 125),
      92,
      Paint()..color = const Color(0xffa596d0).withValues(alpha: .25),
    );
    canvas.drawCircle(
      const Offset(260, 130),
      60,
      Paint()..color = const Color(0xffe3cdbc),
    );
  }
  final text = TextPainter(
    text: TextSpan(
      text: photo ? '春日光影${number == 0 ? '' : '\n$number'}' : '星河\n漫游',
      style: const TextStyle(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        height: 1.3,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  text.layout(maxWidth: 280);
  text.paint(canvas, const Offset(25, 270));
  final picture = recorder.endRecording();
  final image = await picture.toImage(330, 450);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = await ReadingLibrary.open(Section.comic);
  library.setSetting('comic.detail.compactLayout', 'false');
  library.saveProgress(
    ComicProgress(
      section: Section.comic,
      itemId: 'demo-comic',
      chapterIndex: 11,
      chapterId: 'chapter-12',
      chapterTitle: '第12话',
      updatedAt: DateTime.now(),
      page: 7,
    ),
  );
  final cache = <String, List<int>>{};
  final pipeline = SectionImagePipeline(
    cacheDir: library.imageCacheDir,
    diskCache: false,
    requestSender: (request) async => NetworkResponse(
      statusCode: 200,
      body: cache[request.url] ??= await artwork(request.url),
      headers: const {'content-type': 'image/png'},
    ),
  );
  final comic = DetailDemoSource(), gallery = DetailDemoSource(gallery: true);
  final manager = FakeSourceManager(
    sources: [
      for (final source in [comic, gallery])
        SourceDescriptor(
          id: source.id,
          name: source.name,
          version: '1',
          enabled: true,
          group: source.gallery ? '美图' : '漫画',
        ),
    ],
    opened: {comic.id: comic, gallery.id: gallery},
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('漫画与图集详情 · 演示数据')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final source in [comic, gallery])
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: FilledButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ComicDetailPage(
                            library: library,
                            manager: manager,
                            target: ReadingTarget(
                              sourceId: source.id,
                              itemId: source.gallery
                                  ? 'demo-gallery'
                                  : 'demo-comic',
                              title: source.gallery ? '春日光影' : '星河漫游',
                            ),
                            imagePipeline: pipeline,
                            runtimeAvailable: true,
                          ),
                        ),
                      ),
                      child: Text(source.gallery ? '查看图集详情（演示）' : '查看漫画详情（演示）'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
