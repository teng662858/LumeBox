// Local artwork only; uses the production reader without a source runtime.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';

import 'comic_detail_compare_preview.dart' as demo;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = await ReadingLibrary.open(Section.comic);
  final source = demo.DetailDemoSource();
  final chapters = [
    for (var i = 1; i <= 12; i++)
      SourceChapter(id: 'chapter-$i', title: '第$i话'),
    const SourceChapter(id: 'chapter-13', title: '第13话 · 星空之下，来自远方的一封信'),
  ];
  final images = <String, Uint8List>{};
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: ComicReaderPage(
        library: library,
        dataSource: source,
        target: const ReadingTarget(
          sourceId: 'demo_comic',
          itemId: 'reader-glass-preview',
          title: '星海旅人（本地演示）',
        ),
        chapters: chapters,
        initialChapterIndex: 0,
        runtimeAvailable: true,
        pageBytes: (url) async =>
            images[url] ??= Uint8List.fromList(await demo.artwork(url)),
      ),
    ),
  );
}
