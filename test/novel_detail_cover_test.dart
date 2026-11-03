import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/novel/novel_detail_page.dart';
import 'package:lume_box/features/reading/section_image.dart';

import 'support/fake_reading_source.dart';

class _Novel extends FakeReadingDataSource {
  _Novel(this.cover) : super(section: Section.comic);
  final String cover;
  @override
  Future<SourceDetail?> detail(String id) async => SourceDetail(
    id: id,
    title: '测试小说',
    cover: cover,
    coverHeaders: const {'Referer': 'https://books.test/'},
    author: '作者',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('novel-cover');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.comic);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  for (final detailCover in ['https://images.test/detail.png', '']) {
    testWidgets('小说详情显示封面且保留源请求头：$detailCover', (tester) async {
      final source = _Novel(detailCover);
      final requests = <NetworkRequest>[];
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 3)),
      );
      final pipeline = SectionImagePipeline(
        cacheDir: root.path,
        diskCache: false,
        requestSender: (request) async {
          requests.add(request);
          return NetworkResponse(
            statusCode: 200,
            body: bytes,
            headers: const {},
          );
        },
      );
      addTearDown(pipeline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: NovelDetailPage(
            source: source,
            library: library,
            imagePipeline: pipeline,
            target: const ReadingTarget(
              sourceId: 'fake.comic',
              itemId: 'book',
              title: '书',
              cover: 'https://images.test/list.png',
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      final cover = tester.widget<SectionImage>(
        find.byKey(const ValueKey('novel-detail-cover')),
      );
      expect(
        cover.url,
        detailCover.isEmpty ? 'https://images.test/list.png' : detailCover,
      );
      if (detailCover.isNotEmpty) {
        expect(cover.headers['Referer'], 'https://books.test/');
      }
      expect(requests.any((r) => r.url == cover.url), isTrue);
      expect(
        find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
