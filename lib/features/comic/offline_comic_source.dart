import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import 'comic_download_center.dart';

Future<Directory> comicDownloadDirectory(
  ComicDownloadTask task,
  ReadingLibrary library,
) async {
  final folder =
      '${ReadingStore.safeFolderName(task.title)}-${sha256.convert(utf8.encode(task.id)).toString().substring(0, 10)}';
  return Directory(
    p.join(library.exportDir, ReadingStore.safeFolderName(folder)),
  );
}

class OfflineComicSource implements DataSource {
  OfflineComicSource._(this.task, this._chapters, this._images);
  final ComicDownloadTask task;
  final List<SourceChapter> _chapters;
  final Map<String, List<String>> _images;
  static Future<OfflineComicSource> open(
    ComicDownloadTask task,
    ReadingLibrary library,
  ) async {
    final directory = await comicDownloadDirectory(task, library);
    final chapters = <SourceChapter>[], images = <String, List<String>>{};
    for (final index in task.indices.toSet().toList()..sort()) {
      if (index < 0 || index >= task.chapters.length) continue;
      final chapter = task.chapters[index];
      final folder = Directory(
        p.join(
          directory.path,
          ReadingStore.safeFolderName(
            '${(index + 1).toString().padLeft(3, '0')}_${chapter.title}',
          ),
        ),
      );
      if (!await folder.exists()) continue;
      final files = await folder
          .list(followLinks: false)
          .where(
            (e) =>
                e is File &&
                RegExp(
                  r'\.(jpe?g|png|webp|gif|avif|bmp|heic|jfif|jxl|tiff?)$',
                  caseSensitive: false,
                ).hasMatch(e.path),
          )
          .cast<File>()
          .toList();
      files.sort((a, b) {
        int number(File f) =>
            int.tryParse(
              RegExp(r'^\d+').firstMatch(p.basename(f.path))?.group(0) ?? '',
            ) ??
            0;
        return number(a).compareTo(number(b));
      });
      if (files.isEmpty) continue;
      chapters.add(chapter);
      images[chapter.id] = files.map((f) => f.uri.toString()).toList();
    }
    return OfflineComicSource._(task, chapters, images);
  }

  @override
  String get id => task.sourceId;
  @override
  String get name => '离线漫画';
  @override
  Section get section => task.section;
  @override
  Future<List<SourceCategory>> categories() async => [];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList();
  @override
  Future<SourceDetail?> detail(String itemId) async =>
      SourceDetail(id: itemId, title: task.title);
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => _chapters;
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => ImageContent(_images[chapterId] ?? []);
}
