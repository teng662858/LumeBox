import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';
import 'package:lume_box/features/comic/comic_download.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

/// 漫画详情页批量下载的验证。
///
/// 分两层：
/// - **下载器（纯逻辑）**：用注入的字节来源驱动，验证落盘布局、同名覆盖、
///   已下跳过、失败不中断、取消即停、进度计数——这些都不该依赖网络；
/// - **详情页（UI 接线）**：入口按钮 / 范围面板 / 进度与结果卡片，
///   用不可达图片地址验证失败路径的汇总与展示。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_download');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    library = await ReadingLibrary.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // ------------------------------------------------------------------ 工具

  /// 章节列表：8 章，与章节 id 一一对应。
  List<SourceChapter> chapters(int count) => <SourceChapter>[
        for (var index = 1; index <= count; index++)
          SourceChapter(id: 'c$index', title: '第 $index 章'),
      ];

  /// 字节来源：按 URL 返回确定的字节；[fail] 里的 URL 返回 null（模拟取不到）。
  Future<Uint8List?> Function(String) fetcher({
    Set<String> fail = const <String>{},
    List<String>? log,
  }) =>
      (String url) async {
        log?.add(url);
        if (fail.contains(url)) return null;
        return Uint8List.fromList(<int>[1, 2, 3, 4, url.length]);
      };

  ComicDownloader downloader({
    int imageCount = 3,
    int chapterCount = 8,
    Set<String> fail = const <String>{},
    List<String>? log,
    FakeReadingDataSource? source,
  }) =>
      ComicDownloader(
        dataSource: source ??
            FakeReadingDataSource(
              section: Section.comic,
              chapterCount: chapterCount,
              imageCount: imageCount,
            ),
        itemId: 'item-1',
        works: '测试漫画',
        library: library,
        fetch: fetcher(fail: fail, log: log),
      );

  String chapterDir(int chapterIndex) => Directory(
        '${library.exportDir}/测试漫画/'
        '${(chapterIndex + 1).toString().padLeft(3, '0')}_第_${chapterIndex + 1}_章',
      ).path;
  List<String> dirFiles(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList()
      ..sort();
  }

  // ------------------------------------------------------------- 范围与命名

  test('下载范围：全部 / 未读 / 仅当前章都按正序下标给出', () {
    expect(
      ComicDownloadScope.all.indices(chapterCount: 5),
      <int>[0, 1, 2, 3, 4],
    );
    // 没有进度时「未读」等于全部。
    expect(
      ComicDownloadScope.unread.indices(chapterCount: 5),
      <int>[0, 1, 2, 3, 4],
    );
    // 读到第 3 章（下标 2）时，未读从下标 3 开始。
    expect(
      ComicDownloadScope.unread.indices(chapterCount: 5, readChapterIndex: 2),
      <int>[3, 4],
    );
    // 全书读完：未读为空，而不是负数区间。
    expect(
      ComicDownloadScope.unread.indices(chapterCount: 5, readChapterIndex: 4),
      isEmpty,
    );
    expect(
      ComicDownloadScope.current.indices(chapterCount: 5, currentIndex: 3),
      <int>[3],
    );
    // 越界进度夹回区间内，不产生非法下标。
    expect(
      ComicDownloadScope.current.indices(chapterCount: 5, currentIndex: 99),
      <int>[4],
    );
    expect(ComicDownloadScope.all.indices(chapterCount: 0), isEmpty);
  });

  test('落盘文件名：三位序号 + 原扩展名，认不出的扩展名退回 .jpg', () {
    expect(comicImageFileName('https://a.com/x/y/abc.jpg', 0), '001.jpg');
    expect(comicImageFileName('https://a.com/x/y/abc.PNG?sig=1', 11), '012.png');
    expect(comicImageFileName('https://a.com/x/y/abc', 2), '003.jpg');
    expect(comicImageFileName('https://a.com/x/y/abc.jsp', 2), '003.jpg');
    expect(comicImageFileName('https://a.com/x/y/abc.php', 2), '003.jpg');
  });

  // ------------------------------------------------------------- 下载器行为

  test('批量下载：按作品 / 章节分目录落盘，进度计数与文件一致', () async {
    final requests = <String>[];
    final runner = downloader(imageCount: 3, log: requests);

    await runner.start(
      chapters: chapters(8),
      indices: ComicDownloadScope.unread.indices(chapterCount: 8),
    );

    expect(runner.progress.status, ComicDownloadStatus.done);
    expect(runner.progress.chapterTotal, 8);
    expect(runner.progress.chapterDone, 8);
    expect(runner.progress.chapterFailed, 0);
    expect(runner.progress.imageSaved, 24);
    expect(runner.progress.imageSkipped, 0);
    expect(requests.length, 24);
    expect(runner.progress.destination, runner.worksDir);
    for (var index = 0; index < 8; index++) {
      expect(
        dirFiles(chapterDir(index)),
        <String>['001.jpg', '002.jpg', '003.jpg'],
        reason: '第 ${index + 1} 章应有 3 张图',
      );
    }
  });

  test('重跑：已存在的图片跳过，不再请求，也不产生副本', () async {
    final first = downloader(imageCount: 2);
    await first.start(chapters: chapters(3), indices: const <int>[0, 1, 2]);

    final requests = <String>[];
    final second = downloader(imageCount: 2, log: requests);
    await second.start(chapters: chapters(3), indices: const <int>[0, 1, 2]);

    expect(requests, isEmpty, reason: '所有图都在磁盘上，不该再发请求');
    expect(second.progress.imageSkipped, 6);
    expect(second.progress.imageSaved, 0);
    expect(second.progress.chapterDone, 3);
    expect(dirFiles(chapterDir(0)).length, 2, reason: '不产生 _1 副本');
  });

  test('失败不中断：某章取不到图只记该章失败，其余章照下', () async {
    final source =
        FakeReadingDataSource(section: Section.comic, chapterCount: 3, imageCount: 2);
    final broken = <String>{
      // 第 2 章的两张都取不到。
      '${FakeReadingDataSource.imageHost}/c2/1.jpg',
      '${FakeReadingDataSource.imageHost}/c2/2.jpg',
    };
    final runner = downloader(source: source, fail: broken);
    await runner.start(chapters: chapters(3), indices: const <int>[0, 1, 2]);

    expect(runner.progress.status, ComicDownloadStatus.done);
    expect(runner.progress.chapterDone, 2);
    expect(runner.progress.chapterFailed, 1);
    expect(runner.progress.failures.single, contains('第 2 章'));
    expect(runner.progress.imageSaved, 4);
    expect(dirFiles(chapterDir(0)).length, 2);
    expect(dirFiles(chapterDir(1)), isEmpty, reason: '失败章没有落盘');
    expect(dirFiles(chapterDir(2)).length, 2);
  });

  test('取消：当前批次停下，状态为已取消，已完成的部分保留', () async {
    final runner = downloader(imageCount: 4);
    // 第一张下完后取消：不给它机会把后面的下完。
    void onProgress() {
      if (runner.progress.currentImageDone >= 1) runner.cancel();
    }

    runner.addListener(onProgress);
    await runner.start(chapters: chapters(5), indices: const <int>[0, 1, 2, 3, 4]);
    runner.removeListener(onProgress);

    expect(runner.progress.status, ComicDownloadStatus.cancelled);
    expect(runner.progress.chapterTotal, 5);
    expect(
      runner.progress.chapterDone + runner.progress.chapterFailed,
      lessThan(5),
      reason: '不应该把五章都跑完',
    );
    expect(runner.progress.imageSaved, greaterThan(0));
    expect(runner.progress.failures, isEmpty, reason: '取消不该被记成失败');
  });

  test('章节没有图片内容：记为该章失败，不抛异常', () async {
    final empty = FakeReadingDataSource(
      section: Section.comic,
      chapterCount: 2,
      imageCount: 0,
    );
    final runner = downloader(source: empty);
    await runner.start(chapters: chapters(2), indices: const <int>[0, 1]);

    expect(runner.progress.chapterFailed, 2);
    expect(runner.progress.chapterDone, 0);
    expect(runner.progress.failures.length, 2);
    expect(runner.progress.failures.first, contains('没有图片内容'));
  });

  test('脏标题：目录名清洗后不会跑出导出目录', () async {
    final runner = downloader(imageCount: 1);
    await runner.start(
      chapters: const <SourceChapter>[
        SourceChapter(id: 'c1', title: '../../etc/第 1 章'),
      ],
      indices: const <int>[0],
    );

    expect(runner.progress.chapterDone, 1);
    final worksDir = Directory(runner.worksDir);
    final folders = worksDir.listSync().whereType<Directory>().toList();
    expect(folders, hasLength(1));
    final folder = folders.single;
    expect(folder.path.startsWith(library.exportDir), isTrue);
    final relative = p.relative(folder.path, from: worksDir.path);
    expect(
      relative.contains('/') || relative.contains(r'\'),
      isFalse,
      reason: '章节目录只有一层：标题里的分隔符被清洗成普通字符，路径不会变深',
    );
    expect(dirFiles(folder.path), <String>['001.jpg']);

    // 作品名只有点点时退回固定目录名，不会写到导出目录之外。
    final dotty = ComicDownloader(
      dataSource: FakeReadingDataSource(section: Section.comic, imageCount: 1),
      itemId: 'item-1',
      works: '..',
      library: library,
      fetch: fetcher(),
    );
    await dotty.start(
      chapters: const <SourceChapter>[SourceChapter(id: 'c1', title: '第 1 章')],
      indices: const <int>[0],
    );
    expect(dotty.worksFolder, 'lume');
    expect(dotty.progress.chapterDone, 1);
  });

  // ------------------------------------------------------------------ 页面

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ComicDetailPage(
          library: library,
          manager: FakeSourceManager(
            sources: const <SourceDescriptor>[
              SourceDescriptor(id: 'a', name: '测试源', version: '1.0', enabled: true),
            ],
            opened: <String, DataSource>{
              'a': FakeReadingDataSource(
                section: Section.comic,
                chapterCount: 3,
                imageCount: 1,
              ),
            },
          ),
          target: const ReadingTarget(
            sourceId: 'a',
            itemId: 'item-1',
            title: '测试漫画',
          ),
          runtimeAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('详情页：批量下载入口与范围面板', (tester) async {
    await pumpPage(tester);

    expect(find.byIcon(Icons.download_for_offline_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.download_for_offline_outlined));
    await tester.pumpAndSettle();

    expect(find.text('批量下载'), findsOneWidget);
    expect(find.text('全部章节'), findsOneWidget);
    expect(find.text('未读章节'), findsOneWidget);
    expect(find.text('仅当前章'), findsOneWidget);
    expect(find.text('整部作品，共 3 章'), findsOneWidget);
    expect(find.text('没有未读章节'), findsNothing, reason: '没有进度时未读等于全部');
    expect(find.text('进度之后，共 3 章'), findsOneWidget);
  });

  testWidgets('详情页：不可达图床下跑完整批，结果卡片给出失败汇总与路径', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.download_for_offline_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅当前章'));
    // 逐帧推进到下载结束：网络请求在真实异步里完成，pumpAndSettle 等不到它。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('下载结束（有失败）').evaluate().isNotEmpty) break;
    }

    expect(find.text('下载结束（有失败）'), findsOneWidget);
    expect(find.textContaining('成功 0 章'), findsOneWidget);
    expect(find.textContaining('失败 1 章'), findsOneWidget);
    expect(find.textContaining('1 张图片未能取到'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('下载结束（有失败）'), findsNothing, reason: '关闭后卡片收起');
  });
}
