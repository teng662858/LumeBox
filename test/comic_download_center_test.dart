import 'package:lume_box/features/comic/offline_comic_source.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_download_center.dart';

import 'support/fake_reading_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('download-center-');
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
  test('downloaded chapters can be read offline after restart without reopening the source', () async {
    final png = img.encodePng(img.Image(width: 2, height: 2));
    final source = FakeReadingDataSource(section: Section.comic, imageCount: 2);
    final center = ComicDownloadCenter(
      directory: () async => root,
      pipelineFactory: (source, lib) => SectionImagePipeline(
        cacheDir: lib.imageCacheDir,
        diskCache: false,
        requestSender: (_) async => NetworkResponse(
          statusCode: 200,
          body: png,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    await center.boot();
    final down = center.attach(
      source: source,
      library: library,
      itemId: 'offline',
      title: 'Offline comic',
    );
    await center.enqueue(
      down,
      const [SourceChapter(id: 'first', title: 'Chapter 1')],
      [0],
    );
    await center.flush();
    final restarted = ComicDownloadCenter(
      directory: () async => root,
      openSource: (_, _) async => throw StateError('network must not be used'),
    );
    await restarted.boot();
    final local = await OfflineComicSource.open(
      restarted.tasks.single,
      library,
    );
    expect((await local.chapters('offline')).single.id, 'first');
    final content = await local.content(
      itemId: 'offline',
      chapterId: 'first',
    ) as ImageContent;
    expect(content.images, hasLength(2));
    for (final url in content.images) {
      expect(Uri.parse(url).scheme, 'file');
      expect(await File.fromUri(Uri.parse(url)).readAsBytes(), png);
    }
  });

  test('全局下载离开页面不依赖页面管线，任务重开可恢复并跳过已有图片', () async {
    final source = FakeReadingDataSource(section: Section.comic, imageCount: 2);
    var requests = 0;
    final png = img.encodePng(img.Image(width: 2, height: 2));
    final center = ComicDownloadCenter(
      directory: () async => root,
      openSource: (_, _) async => source,
      pipelineFactory: (source, lib) => SectionImagePipeline(
        cacheDir: lib.imageCacheDir,
        diskCache: false,
        requestSender: (req) async {
          requests++;
          return NetworkResponse(
            statusCode: 200,
            body: png,
            headers: {'content-type': 'image/png'},
          );
        },
      ),
    );
    await center.boot();
    final down = center.attach(
      source: source,
      library: library,
      itemId: 'one',
      title: '漫画',
    );
    await center.enqueue(
      down,
      const [SourceChapter(id: 'c1', title: '第1章')],
      [0],
    );
    expect(center.tasks.single.state, 'done');
    expect(down.progress.imageSaved, 2);
    final restarted = ComicDownloadCenter(
      directory: () async => root,
      openSource: (_, _) async => source,
      pipelineFactory: (source, lib) => SectionImagePipeline(
        cacheDir: lib.imageCacheDir,
        diskCache: false,
        requestSender: (req) async {
          requests++;
          return NetworkResponse(
            statusCode: 200,
            body: png,
            headers: {'content-type': 'image/png'},
          );
        },
      ),
    );
    await restarted.boot();
    expect(restarted.tasks.single.completed, 1);
    final before = requests;
    await restarted.resume(restarted.tasks.single);
    expect(restarted.tasks.single.downloader!.progress.imageSkipped, 2);
    expect(requests, before);
    down.dispose();
    center.tasks.single.pipeline?.dispose();
    restarted.tasks.single.downloader?.dispose();
    restarted.tasks.single.pipeline?.dispose();
  });
  test('失败任务重开后保留失败章节，重试仅补失败项', () async {
    var online = false;
    final calls = <String>[];
    final source = FakeReadingDataSource(section: Section.comic, imageCount: 1);
    final png = img.encodePng(img.Image(width: 2, height: 2));
    SectionImagePipeline pipeline(DataSource source, ReadingLibrary lib) =>
        SectionImagePipeline(
          cacheDir: lib.imageCacheDir,
          diskCache: false,
          requestSender: (req) async {
            calls.add(req.url);
            final fail = !online && req.url.contains('second');
            return NetworkResponse(
              statusCode: fail ? 403 : 200,
              body: fail ? const [] : png,
              headers: {'content-type': 'image/png'},
            );
          },
        );
    final center = ComicDownloadCenter(
      directory: () async => root,
      openSource: (_, _) async => source,
      pipelineFactory: pipeline,
    );
    await center.boot();
    final down = center.attach(
      source: source,
      library: library,
      itemId: 'retry',
      title: '重试',
    );
    await center.enqueue(
      down,
      const [
        SourceChapter(id: 'first', title: '第1章'),
        SourceChapter(id: 'second', title: '第2章'),
      ],
      [0, 1],
    );
    expect(center.tasks.single.state, 'failed');
    final restarted = ComicDownloadCenter(
      directory: () async => root,
      openSource: (_, _) async => source,
      pipelineFactory: pipeline,
    );
    await restarted.boot();
    expect(restarted.tasks.single.state, 'failed');
    online = true;
    calls.clear();
    await restarted.resume(restarted.tasks.single, failedOnly: true);
    expect(restarted.tasks.single.state, 'done');
    expect(restarted.tasks.single.completed, 2);
    expect(calls, hasLength(1));
    expect(calls.every((url) => url.contains('second')), isTrue);
    down.dispose();
    center.tasks.single.pipeline?.dispose();
    restarted.tasks.single.downloader?.dispose();
    restarted.tasks.single.pipeline?.dispose();
  });

  test('仅打开范围面板的空任务不进入持久清单', () async {
    final source = FakeReadingDataSource(section: Section.comic, imageCount: 1);
    final center = ComicDownloadCenter(directory: () async => root);
    await center.boot();
    final down = center.attach(
      source: source,
      library: library,
      itemId: 'not-started',
      title: '未开始',
    );
    await center.pause(center.tasks.single);
    final reopened = ComicDownloadCenter(directory: () async => root);
    await reopened.boot();
    expect(reopened.tasks, isEmpty);
    down.dispose();
    center.tasks.single.pipeline?.dispose();
  });

  test('暂停在飞任务后不能重复启动，任务计划持久化为可继续状态', () async {
    final gate = Completer<void>(), started = Completer<void>();
    final source = FakeReadingDataSource(section: Section.comic, imageCount: 1);
    final center = ComicDownloadCenter(
      directory: () async => root,
      pipelineFactory: (source, lib) => SectionImagePipeline(
        cacheDir: lib.imageCacheDir,
        diskCache: false,
        requestSender: (req) async {
          if (!started.isCompleted) started.complete();
          await gate.future;
          return NetworkResponse(
            statusCode: 403,
            body: const [],
            headers: const {},
          );
        },
      ),
    );
    await center.boot();
    final down = center.attach(
      source: source,
      library: library,
      itemId: 'two',
      title: '漫画',
    );
    final running = center.enqueue(
      down,
      const [SourceChapter(id: 'c', title: '第1章')],
      [0],
    );
    await started.future;
    await center.pause(center.tasks.single);
    await center.resume(center.tasks.single);
    expect(center.tasks.single.state, 'paused');
    gate.complete();
    await running;
    final restarted = ComicDownloadCenter(directory: () async => root);
    await restarted.boot();
    expect(restarted.tasks.single.state, 'paused');
    expect(restarted.tasks.single.indices, [0]);
    down.dispose();
    center.tasks.single.pipeline?.dispose();
  });
}
