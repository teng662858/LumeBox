import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_download_center.dart';

Future<void> waitFor(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      throw StateError('Timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('lume-merge-test-');
  });
  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final mp4 = [
    0, 0, 0, 16, ...ascii.encode('ftypisom'), 0, 0, 0, 0,
    0, 0, 0, 16, ...ascii.encode('moov'), 0, 0, 0, 8, ...ascii.encode('free'),
    0, 0, 0, 9, ...ascii.encode('mdat'), 1,
  ];

  Future<VideoDownloadTask> downloaded(
    VideoDownloadCenter center, {
    String state = 'done',
  }) async {
    await center.boot();
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('source', 'movie', 'one'),
      sourceId: 'source',
      itemId: 'movie',
      chapterId: 'one',
      title: 'Movie',
      chapterTitle: 'One',
      state: state,
      fileName: 'index.m3u8',
    );
    center.tasks.add(task);
    final folder = Directory(center.folder(task));
    await folder.create(recursive: true);
    await File('${folder.path}/index.m3u8')
        .writeAsString('#EXTM3U\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST\n');
    await File('${folder.path}/a.ts').writeAsBytes([1, 2, 3]);
    return task;
  }

  test('old HLS downloads merge locally and commit the MP4 before cleaning fragments', () async {
    var calls = 0;
    late VideoDownloadCenter center;
    center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async => throw StateError('Must not use source'),
      merge: (directory, output, id) async {
        calls++;
        expect(await File('${directory.path}/a.ts').exists(), true);
        expect(center.tasks.single.state, 'merging');
        await output.writeAsBytes(mp4);
      },
    );
    final task = await downloaded(center);
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    expect(File('${center.folder(task)}/a.ts').existsSync(), isFalse);
    expect(File('${center.folder(task)}/index.m3u8').existsSync(), isFalse);
    expect(calls, 1);
    expect(task.fileName, 'merged.mp4');
    expect(await center.localFile(task).readAsBytes(), mp4);
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(restored.tasks.single.fileName, 'merged.mp4');
    expect(restored.tasks.single.state, 'done');
  });

  test('failed merge removes partial output, keeps all source files and retries without a source call', () async {
    var calls = 0;
    final center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async => throw StateError('Source must not be called'),
      merge: (_, output, _) async {
        await output.writeAsBytes(mp4);
        if (++calls == 1) throw StateError('Not enough disk space');
      },
    );
    final task = await downloaded(center);
    await center.resume(task);
    await waitFor(() => task.state == 'merge_failed');
    expect(await center.localFile(task).exists(), true);
    expect(File('${center.folder(task)}/a.ts').existsSync(), true);
    expect(File('${center.folder(task)}/merged.mp4.part').existsSync(), false);
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    await waitFor(() => !File('${center.folder(task)}/a.ts').existsSync());
    expect(calls, 2);
  });

  test('pausing an active merge cancels it and preserves fragments for a local retry', () async {
    var calls = 0, cancellations = 0;
    final entered = Completer<void>(), release = Completer<void>();
    final center = VideoDownloadCenter(
      directory: () async => root,
      cancelMerge: (_) async {
        cancellations++;
        release.complete();
      },
      merge: (_, output, _) async {
        if (++calls == 1) {
          entered.complete();
          await release.future;
        }
        await output.writeAsBytes(mp4);
      },
    );
    final task = await downloaded(center);
    await center.resume(task);
    await entered.future;
    await center.pause(task);
    await center.flush();
    expect(task.state, 'paused');
    expect(File('${center.folder(task)}/a.ts').existsSync(), true);
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    await waitFor(() => !File('${center.folder(task)}/a.ts').existsSync());
    expect(cancellations, 1);
    expect(calls, 2);
  });

  test(
    'an interrupted merge restores paused and uses local files on resume',
    () async {
      final previous = VideoDownloadCenter(directory: () async => root);
      final task = await downloaded(previous, state: 'merging');
      await File('${previous.root.path}/tasks.json')
          .writeAsString(jsonEncode([task.toJson()]));
      final restored = VideoDownloadCenter(
        directory: () async => root,
        resolve: (_) async => throw StateError('Source unavailable'),
        merge: (_, output, _) async => output.writeAsBytes(mp4),
      );
      await restored.boot();
      final next = restored.tasks.single;
      expect(next.state, 'paused');
      final playback = await restored.completedPlayback('source', 'movie', 'one');
      expect(playback, isNotNull, reason: 'All HLS files survived the interrupted merge');
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(playback!.uri)).close();
        expect(await response.transform(utf8.decoder).join(), contains('a.ts'));
        final segment = await (await client.getUrl(playback.uri.resolve('a.ts'))).close();
        expect(await segment.expand((bytes) => bytes).toList(), [1, 2, 3]);
      } finally {
        client.close(force: true);
        await playback?.close();
      }
      await restored.resume(next);
      await waitFor(() => next.state == 'done');
      await restored.flush();
      await waitFor(() => !File('${restored.folder(next)}/a.ts').existsSync());
    },
  );

  test('invalid merger output never deletes original media', () async {
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, output, _) async => output.writeAsString('not an MP4'),
    );
    final task = await downloaded(center);
    await center.resume(task);
    await waitFor(() => task.state == 'merge_failed');
    await center.flush();
    expect(task.error, contains('有效的 MP4'));
    expect(File('${center.folder(task)}/a.ts').existsSync(), true);
    expect(task.fileName, 'index.m3u8');
  });

  test('a newly downloaded HLS is automatically merged before reporting completion', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/index.m3u8') {
        request.response.write('#EXTM3U\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST\n');
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async => VideoContent(
        url: Uri.parse('http://127.0.0.1:${server.port}/index.m3u8'),
      ),
      merge: (_, output, _) async => output.writeAsBytes(mp4),
    );
    await center.enqueue(
      sourceId: 'source',
      itemId: 'movie',
      title: 'Movie',
      chapters: const [SourceChapter(id: 'one', title: 'One')],
    );
    await waitFor(() => center.tasks.single.state == 'done');
    await center.flush();
    final task = center.tasks.single;
    await waitFor(
      () => !File('${center.folder(task)}/index.m3u8').existsSync(),
    );
    expect(task.fileName, 'merged.mp4');
  });
  test('manifest write failure retains the playlist and fragments alongside the MP4', () async {
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, output, _) async => output.writeAsBytes(mp4),
    );
    final task = await downloaded(center);
    await Directory('${center.root.path}/tasks.json.part').create();
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    expect(center.storageError, isNotNull);
    expect(File('${center.folder(task)}/a.ts').existsSync(), true);
    expect(File('${center.folder(task)}/index.m3u8').existsSync(), true);
    expect(await center.localFile(task).readAsBytes(), mp4);
  });

  test('a committed MP4 left by a crash is recovered without invoking the merger again', () async {
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, _, _) async => throw StateError('Must reuse committed output'),
    );
    final task = await downloaded(center, state: 'paused');
    await File('${center.folder(task)}/merged.mp4').writeAsBytes(mp4);
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    await waitFor(() => !File('${center.folder(task)}/a.ts').existsSync());
    expect(task.fileName, 'merged.mp4');
  });

  test('a truncated committed MP4 is rebuilt using the surviving local HLS', () async {
    var calls = 0;
    final center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async => throw StateError('Source is offline'),
      merge: (_, output, _) async {
        calls++;
        await output.writeAsBytes(mp4);
      },
    );
    final task = await downloaded(center, state: 'paused');
    await File('${center.folder(task)}/merged.mp4').writeAsBytes(mp4.sublist(0, mp4.length - 1));
    await center.resume(task);
    await waitFor(() => ['done', 'merge_failed'].contains(task.state));
    await center.flush();
    expect(task.state, 'done', reason: task.error);
    expect(calls, 1);
    expect(await center.localFile(task).readAsBytes(), mp4);
  });

  test('MP4 with only a file type box preserves the playable local HLS', () async {
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, output, _) async => output.writeAsBytes(mp4.sublist(0, 16)),
    );
    final task = await downloaded(center);
    await center.resume(task);
    await waitFor(() => ['done', 'merge_failed'].contains(task.state));
    await center.flush();
    expect(task.state, 'merge_failed');
    expect(await center.localFile(task).exists(), true);
    expect(await File('${center.folder(task)}/a.ts').exists(), true);
  });
}
