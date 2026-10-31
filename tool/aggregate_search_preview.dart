/// Interactive phone preview using the production aggregate search page.
/// flutter run -d emulator-5554 -t tool/aggregate_search_preview.dart
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/search_results_page.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';

import '../test/support/fake_reading_source.dart';
import '../test/support/fake_source_manager.dart';

const _titles = ['山海之间', '山河长夜微光', '风起远山', '昨日山间晴空', '星河与远山来信', '无声山城'];
const _names = ['影视精选', '高清片库', '综合视频', '动漫专区', '电影专区', '经典剧场', '云端影院', '热门推荐'];

class _PreviewPaths extends PathProviderPlatform {
  _PreviewPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
}

class _Source extends FakeReadingDataSource {
  _Source(this.index) : super(section: Section.video);
  final int index;
  @override
  String get id => 'preview-$index';
  @override
  String get name => _names[index];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => SourceList(
    items: [
      for (var i = 0; i < 24; i++)
        SourceItem(
          id: '$i',
          title: '${_titles[(i + index) % _titles.length]} · 第${i + 1}季',
          cover: 'https://preview.test/${i + index}.png',
          subtitle: '更新至${i + 2}集',
        ),
    ],
    hasMore: false,
  );
}

Future<List<Uint8List>> _posters() async {
  final output = <Uint8List>[];
  final colors = [
    const Color(0xFF486B78),
    const Color(0xFF513B68),
    const Color(0xFF9C7151),
    const Color(0xFF607664),
    const Color(0xFF384D77),
    const Color(0xFF8F6263),
  ];
  for (var i = 0; i < colors.length; i++) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 240, 336),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, const Offset(240, 336), [
          colors[i],
          const Color(0xFF111A2B),
        ]),
    );
    canvas.drawCircle(
      Offset(155 - i * 7, 88),
      48,
      Paint()..color = const Color(0xFFEBE0C3).withValues(alpha: .66),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 230)
        ..lineTo(70, 145)
        ..lineTo(146, 228)
        ..lineTo(200, 190)
        ..lineTo(240, 240)
        ..lineTo(240, 336)
        ..lineTo(0, 336)
        ..close(),
      Paint()..color = colors[i].withValues(alpha: .7),
    );
    final text = TextPainter(
      text: TextSpan(
        text: _titles[i],
        style: const TextStyle(
          fontSize: 27,
          color: Colors.white,
          letterSpacing: 3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 210);
    text.paint(canvas, Offset((240 - text.width) / 2, 250));
    text.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 336);
    output.add(
      (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List(),
    );
    image.dispose();
    picture.dispose();
  }
  return output;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sandbox = Directory.systemTemp.createTempSync(
    'lumebox-search-preview-',
  );
  PathProviderPlatform.instance = _PreviewPaths(sandbox.path);
  await ReadingLibrary.open(Section.video);
  final posters = await _posters();
  final pipeline = SectionImagePipeline(
    cacheDir: sandbox.path,
    diskCache: false,
    requestSender: (request) async => NetworkResponse(
      statusCode: 200,
      body:
          posters[int.parse(
                Uri.parse(request.url).pathSegments.first.split('.').first,
              ) %
              posters.length],
      headers: const {'content-type': 'image/png'},
    ),
  );
  final manager = FakeSourceManager(
    sources: [
      for (var i = 0; i < _names.length; i++)
        SourceDescriptor(
          id: 'preview-$i',
          name: _names[i],
          version: '1',
          enabled: true,
        ),
    ],
    opened: {for (var i = 0; i < _names.length; i++) 'preview-$i': _Source(i)},
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(),
      home: Builder(
        builder: (context) => SearchResultsPage(
          section: Section.video,
          keyword: '山',
          mode: SearchMode.aggregate,
          manager: manager,
          pipeline: pipeline,
          onOpenItem: (selection) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已选中：${selection.item.title}')),
            );
          },
        ),
      ),
    ),
  );
}
