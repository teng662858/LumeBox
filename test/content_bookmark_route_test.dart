import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/experience/content_center_page.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/features/video/video_player_page.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('content-bookmark-');
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
  });
  tearDown(() async {
    ContentCenter.instance.data.remove('clips');
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  for (final section in Section.values) {
    testWidgets(
      'a ${section.name} bookmark opens its reader after history is cleared',
      (tester) async {
        final source = section == Section.cat
            ? _TextSource()
            : section == Section.video
            ? _DetailVideoSource()
            : FakeReadingDataSource(section: section);
        final manager = FakeSourceManager(opened: {source.id: source});
        final ref = ContentRef(section, source.id, 'work', '书签回读');
        ContentCenter.instance.data['clips'] = [
          {
            'id': 'saved',
            'ref': ref.toJson(),
            'folder': '默认',
            'text': '摘录',
            'chapter': 0,
            'chapterId': 'work-c2',
            if (section == Section.comic) 'page': 2,
            if (section == Section.video) 'seconds': 42,
          },
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: ContentCenterPage(initialTab: 3, managerFor: (_) => manager),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('书签回读'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (section == Section.comic) {
          final reader = tester.widget<ComicReaderPage>(
            find.byType(ComicReaderPage),
          );
          expect(reader.initialChapterIndex, 1);
          expect(reader.initialPage, 2);
        } else if (section == Section.video) {
          final player = tester.widget<VideoPlayerPage>(
            find.byType(VideoPlayerPage),
          );
          expect(player.target?.chapterId, 'work-c2');
          expect(player.initialPosition, const Duration(seconds: 42));
        } else {
          final reader = tester.widget<NovelReaderPage>(
            find.byType(NovelReaderPage),
          );
          expect(reader.initialChapterIndex, 1);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }
}

class _TextSource extends FakeReadingDataSource {
  _TextSource() : super(section: Section.cat);
  @override
  Future<ChapterContent> content({
    required String itemId,
    required String chapterId,
  }) async => TextContent(chapterText(itemId, chapterId));
}

class _DetailVideoSource extends FakeReadingDataSource {
  _DetailVideoSource() : super(section: Section.video);
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => [];
  @override
  Future<SourceDetail?> detail(String itemId) async => SourceDetail(
    id: itemId,
    title: '视频',
    chapters: await super.chapters(itemId),
  );
}
