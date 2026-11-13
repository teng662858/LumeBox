import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/media/media_resource_service.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/native_video_bridge.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_download_center.dart';
import 'package:lume_box/features/media/media_resource_router.dart';

class _LocalHttp extends HttpOverrides {}

class _PlaybackObserver extends NavigatorObserver {
  Completer<void>? opened;

  Future<void> tapAndWait(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      opened = Completer<void>();
      await tester.tap(find.text(label));
      await opened!.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) opened?.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('lumebox/native_video');
  late ReadingLibrary library;
  late Directory directory;
  late NativeVideoBridge bridge;
  late VideoDownloadCenter downloads;
  final calls = <MethodCall>[];
  setUp(() async {
    calls.clear();
    directory = await Directory.systemTemp.createTemp('native-route-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await SectionScope.open(Section.video);
    library = await ReadingLibrary.open(Section.video);
    bridge = NativeVideoBridge();
    downloads = VideoDownloadCenter(directory: () async => directory);
    await downloads.boot();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });
  Widget route() => MaterialApp(
    home: VideoPlayerPage(
      media: PlayerMedia(uri: Uri.parse('https://example/video.mp4')),
      library: library,
      bridge: bridge,
      prepareMedia: (media, _) async => media,
      playerFactory: (_) =>
          throw StateError('Legacy Dart engine must not be created'),
    ),
  );
  testWidgets('从媒体库返回后，刚解析好的本地视频不会再弹出播放器', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final entry = MediaResource(
      id: 'file', title: '本地视频', kind: ResourceKind.video,
      destination: Section.video,
      episodes: [ResourceEpisode(id: 'one', title: '正片', url: Uri.file('/fixture.mp4'))],
    );
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator, home: const Scaffold(body: Text('首页')),
    ));
    late BuildContext origin;
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) {
      origin = context;
      return const Scaffold(body: Text('媒体库'));
    }));
    await tester.pumpAndSettle();
    final opening = openMediaResource(origin, entry);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsNothing);
    expect(find.text('首页'), findsOneWidget);
    await opening;
  });
  testWidgets('媒体库从下载播放 HLS，关闭后释放服务，删除后回到在线地址', (tester) async {
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('saved-source', 'show', 'second'),
      sourceId: 'saved-source', itemId: 'show', chapterId: 'second',
      title: '离线影片', chapterTitle: '第二集', chapterIndex: 1,
      state: 'merge_failed', fileName: 'index.m3u8',
    );
    downloads.tasks.add(task);
    Directory(downloads.folder(task)).createSync(recursive: true);
    downloads.localFile(task).writeAsStringSync('#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n');
    File('${downloads.folder(task)}/part.ts').writeAsBytesSync([9, 8, 7]);
    final online = Uri.parse('https://expired.invalid/second.mp4');
    final entry = MediaResource(
      id: 'placed', title: '离线影片', kind: ResourceKind.video,
      destination: Section.comic, originSection: Section.video,
      sourceId: task.sourceId, itemId: task.itemId,
      episodes: [
        const ResourceEpisode(id: 'first', title: '第一集'),
        ResourceEpisode(id: 'second', title: '第二集', url: online, headers: const {'Cookie': 'source-only'}),
      ],
    );
    final nav = GlobalKey<NavigatorState>();
    final observer = _PlaybackObserver();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, navigatorObservers: [observer], home: Builder(builder: (context) =>
        TextButton(onPressed: () => openMediaResource(context, entry, index: 1, downloadCenter: downloads),
            child: const Text('播放')))));
    Future<VideoPlayerPage> open() async {
      await observer.tapAndWait(tester, '播放');
      return tester.widget<VideoPlayerPage>(find.byType(VideoPlayerPage));
    }
    final page = await open();
    expect(page.media!.isDownloaded, true);
    expect(page.media!.headers, isNull);
    final uri = page.media!.uri;
    expect(uri.host, '127.0.0.1');
    expect(page.target?.chapterId, 'second');
    await tester.runAsync(() async {
      final client = _LocalHttp().createHttpClient(null);
      try {
        final response = await (await client.getUrl(uri.resolve('part.ts'))).close();
        expect(await response.expand((chunk) => chunk).toList(), [9, 8, 7]);
      } finally {
        client.close(force: true);
      }
    });
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await expectLater(Socket.connect(uri.host, uri.port), throwsA(isA<SocketException>()));
    });
    downloads.localFile(task).deleteSync();
    final fallback = await open();
    expect(fallback.media!.uri, online);
    expect(fallback.media!.headers, {'Cookie': 'source-only'});
    expect(fallback.media!.isDownloaded, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final explicit in [false, true]) {
    testWidgets('media library retains source identity and selected chapter (explicit=$explicit)', (tester) async {
      library.saveProgress(VideoProgress(
        section: Section.video, sourceId: 'fixture', itemId: 'show',
        chapterIndex: 0, chapterId: 'second', chapterTitle: '第二集',
        position: const Duration(seconds: 28), duration: const Duration(minutes: 3),
        updatedAt: DateTime.now(),
      ));
      final entry = MediaResource(
        id: 'placed', title: '剧集', kind: ResourceKind.video,
        destination: Section.comic, originSection: Section.video,
        sourceId: 'fixture', itemId: 'show',
        episodes: [
          for (final id in ['first', 'second'])
            ResourceEpisode(id: id, title: id, url: Uri.parse('https://cdn.test/$id.mp4')),
        ],
      );
      final observer = _PlaybackObserver();
      await tester.pumpWidget(MaterialApp(navigatorObservers: [observer], home: Builder(builder: (context) => TextButton(
        onPressed: () => openMediaResource(
          context, entry,
          downloadCenter: downloads,
          index: explicit ? 0 : null,
          initialMedia: explicit ? ResolvedMedia(Uri.parse('https://cdn.test/signed.mp4'),
              headers: {'X-Test': 'ticket'}) : null,
        ),
        child: const Text('打开'),
      ))));
      await observer.tapAndWait(tester, '打开');
      final page = tester.widget<VideoPlayerPage>(find.byType(VideoPlayerPage));
      expect(page.target?.chapterId, explicit ? 'first' : 'second');
      expect(page.target?.chapterIndex, explicit ? 0 : 1);
      expect(page.target?.sourceId, 'fixture');
      expect(page.target?.itemId, 'show');
      expect(page.library, same(library));
      expect(page.sourceManager, isNotNull);
      expect(page.media?.uri.path, explicit ? '/signed.mp4' : '/second.mp4');
      if (explicit) expect(page.media?.headers, {'X-Test': 'ticket'});
    });
  }
  testWidgets(
    'route hands off once, does not run a hidden Flutter animation, and tears down on exit',
    (tester) async {
      await tester.pumpWidget(route());
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    },
  );
  testWidgets('native presentation failure keeps back and retry available', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') {
        throw PlatformException(code: 'native', message: 'cannot present');
      }
      return null;
    });
    await tester.pumpWidget(route());
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot present'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed direct address can be retried without re-entering it', (
    tester,
  ) async {
    final tried = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') {
        tried.add(call.arguments['media']['url'] as String);
        if (tried.length == 1) throw PlatformException(code: 'invalid_media');
      }
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerPage(
          library: library,
          bridge: bridge,
          prepareMedia: (media, _) async => media,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example/video.mp4');
    await tester.tap(find.text('打开原生播放器'));
    await tester.pumpAndSettle();
    expect(find.textContaining('invalid_media'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(tried, ['https://example/video.mp4', 'https://example/video.mp4']);
    expect(find.textContaining('invalid_media'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
