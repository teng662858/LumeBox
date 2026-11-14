import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/experience/offline_policy.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_download_center.dart';
import 'package:lume_box/features/video/offline_hls_master.dart';

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
    String chapter = 'one',
  }) async {
    await center.boot();
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('source', 'movie', chapter),
      sourceId: 'source',
      itemId: 'movie',
      chapterId: chapter,
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

  test('flattening a nested master keeps relative track paths and leaves incomplete inputs intact', () async {
    final nested = await Directory('${root.path}/nested').create();
    final entry = File('${root.path}/index.m3u8');
    const original = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=300\nnested/inner.m3u8\n';
    await entry.writeAsString(original);
    await File('${nested.path}/inner.m3u8').writeAsString('#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Dub",URI="dub.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO="a"\nvideo.m3u8\n');
    const media = '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n';
    await File('${nested.path}/video.m3u8').writeAsString(media);
    await expectLater(flattenOfflineHlsMaster(entry), throwsA(isA<FileSystemException>()));
    expect(await entry.readAsString(), original);
    await File('${nested.path}/dub.m3u8').writeAsString(media);
    await flattenOfflineHlsMaster(entry);
    final flat = await entry.readAsString();
    expect(flat, contains('URI="nested/dub.m3u8"'));
    expect(flat, endsWith('\nnested/video.m3u8\n'));
    await flattenOfflineHlsMaster(entry);
    expect(await entry.readAsString(), flat);
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

  test('离线 HLS 播放期间合并完成，直到最后一个播放页面关闭仍能拖动和读取分片', () async {
    final merging = Completer<void>(), finishMerge = Completer<void>();
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, output, _) async {
        merging.complete();
        await finishMerge.future;
        await output.writeAsBytes(mp4);
      },
    );
    final task = await downloaded(center);
    final first = (await center.completedPlayback('source', 'movie', 'one'))!;
    await center.resume(task);
    await merging.future;
    final second = await center.completedPlayback('source', 'movie', 'one');
    finishMerge.complete();
    final client = HttpClient();
    try {
      expect(second, isNotNull);
      await waitFor(() => task.fileName == 'merged.mp4');
      await center.flush();
      final latest = (await center.completedPlayback('source', 'movie', 'one'))!;
      expect(latest.uri, center.localFile(task).uri);
      await latest.close();
      await first.close();
      await first.close();
      final list = await (await client.getUrl(second!.uri)).close();
      expect(list.statusCode, 200);
      expect(await list.transform(utf8.decoder).join(), contains('a.ts'));
      final seek = await client.getUrl(second.uri.resolve('a.ts'));
      seek.headers.set('Range', 'bytes=1-2');
      final response = await seek.close();
      expect(response.statusCode, 206);
      expect(await response.expand((bytes) => bytes).toList(), [2, 3]);
    } finally {
      client.close(force: true);
      await first.close();
      await second?.close();
    }
    expect(await File('${center.folder(task)}/a.ts').exists(), isFalse);
    expect(await center.localFile(task).readAsBytes(), mp4);
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
    await File('${center.folder(task)}/a.ts').delete();
    await center.resume(task);
    await waitFor(() => task.state == 'done');
    await center.flush();
    await waitFor(() => !File('${center.folder(task)}/a.ts').existsSync());
    expect(task.fileName, 'merged.mp4');
  });

  test('repairing a damaged encrypted download reuses valid segments and replaces the key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((r) async {
      requests.add(r.uri.path);
      if (r.uri.path == '/vod.m3u8') {
        r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
            '#EXTINF:1,\none.ts\n#EXTINF:1,\ntwo.ts\n#EXT-X-ENDLIST\n');
      } else {
        r.response.add(List.filled(16, r.uri.path == '/two.ts' ? 2 : 1));
      }
      await r.response.close();
    });
    var merges = 0;
    final center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async => VideoContent(url: Uri.parse('http://127.0.0.1:${server.port}/vod.m3u8')),
      merge: (_, output, _) async {
        if (++merges == 1) throw StateError('Keep local inputs');
        await output.writeAsBytes(mp4);
      },
    );
    await center.enqueue(sourceId: 'source', itemId: 'movie', title: 'Movie',
        chapters: const [SourceChapter(id: 'one', title: 'One')]);
    final task = center.tasks.single;
    await waitFor(() => task.state == 'merge_failed');
    final lines = await center.localFile(task).readAsLines();
    final keyPath = RegExp('URI="([^"]+)"').firstMatch(lines.join('\n'))![1]!;
    final base = center.localFile(task).uri;
    final second = lines.where((line) => !line.startsWith('#') && line.isNotEmpty).last;
    await File.fromUri(base.resolve(keyPath)).writeAsBytes([0]);
    await File.fromUri(base.resolve(second)).delete();
    requests.clear();
    await center.resume(task);
    await waitFor(() => ['done', 'failed', 'merge_failed'].contains(task.state));
    await center.flush();
    expect(requests, ['/vod.m3u8', '/enc.key', '/two.ts']);
    expect(task.state, 'done', reason: task.error);
    expect(await center.localFile(task).readAsBytes(), mp4);
  });

  for (final state in ['done', 'merge_failed']) {
    test('a damaged $state HLS download fetches its missing segment before merging', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((r) async {
        requests.add(r.uri.path);
        if (r.uri.path == '/index.m3u8') {
          r.response.write('#EXTM3U\n#EXTINF:1,\nvideo.ts\n#EXT-X-ENDLIST\n');
        } else {
          r.response.add([11, 22, 33]);
        }
        await r.response.close();
      });
      var resolutions = 0, merges = 0;
      final center = VideoDownloadCenter(
        directory: () async => root,
        resolve: (_) async {
          resolutions++;
          return VideoContent(url: Uri.parse('http://127.0.0.1:${server.port}/index.m3u8'));
        },
        merge: (directory, output, _) async {
          merges++;
          final lines = await File('${directory.path}/index.m3u8').readAsLines();
          final segment = lines.singleWhere((line) => line.isNotEmpty && !line.startsWith('#'));
          final bytes = await File.fromUri(directory.uri.resolve(segment)).readAsBytes();
          if (bytes.join(',') != '11,22,33') throw StateError('Bad segment bytes');
          await output.writeAsBytes(mp4);
        },
      );
      final task = await downloaded(center, state: state);
      await File('${center.folder(task)}/a.ts').delete();
      if (state == 'done') {
        await center.enqueue(sourceId: 'source', itemId: 'movie', title: 'Movie',
            chapters: const [SourceChapter(id: 'one', title: 'One')]);
      } else {
        await center.resume(task);
      }
      await waitFor(() => ['done', 'failed', 'merge_failed', 'paused'].contains(task.state));
      await center.flush();
      expect(resolutions, 1);
      expect(requests, ['/index.m3u8', '/video.ts']);
      expect(merges, 1);
      expect(task.state, 'done', reason: task.error);
      expect(task.fileName, 'merged.mp4');
      expect(await center.localFile(task).readAsBytes(), mp4);
    });
  }

  test('local merge without Wi-Fi respects reserved disk space and never resolves the source', () async {
    final settings = ContentCenter.instance.data;
    final previous = Map.of(settings);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var freeBytes = 0, inspected = 0, resolutions = 0;
    settings['wifiOnly'] = true;
    settings['reserveMB'] = 1;
    messenger.setMockMethodCallHandler(OfflinePolicy.channel, (_) async {
      inspected++;
      return {'wifi': false, 'freeBytes': freeBytes};
    });
    addTearDown(() {
      settings..clear()..addAll(previous);
      messenger.setMockMethodCallHandler(OfflinePolicy.channel, null);
    });
    final center = VideoDownloadCenter(
      directory: () async => root,
      resolve: (_) async {
        resolutions++;
        throw StateError('Source is offline');
      },
      merge: (_, output, _) async => output.writeAsBytes(mp4),
    );
    final task = await downloaded(center);
    await center.resume(task);
    await waitFor(() => task.state == 'paused');
    expect(task.error, contains('空间'));
    freeBytes = 2 * 1024 * 1024;
    await center.resume(task);
    await waitFor(() => ['done', 'paused', 'merge_failed'].contains(task.state));
    await center.flush();
    expect(task.state, 'done', reason: task.error);
    final missing = await downloaded(center, chapter: 'missing');
    await File('${center.folder(missing)}/a.ts').delete();
    await center.resume(missing);
    await waitFor(() => ['paused', 'failed', 'merge_failed'].contains(missing.state));
    await center.flush();
    expect(missing.error, contains('Wi-Fi'));
    expect(inspected, greaterThanOrEqualTo(3));
    expect(resolutions, 0);
  });

  test('successful writes after a manifest write failure restore fragment cleanup', () async {
    final center = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, output, _) async => output.writeAsBytes(mp4),
    );
    final first = await downloaded(center);
    final obstruction = await Directory('${center.root.path}/tasks.json.part').create();
    await center.resume(first);
    await waitFor(() => first.state == 'done');
    await center.flush();
    expect(center.storageError, isNotNull);
    expect(await File('${center.folder(first)}/a.ts').exists(), true);
    await obstruction.delete();
    final next = await downloaded(center, chapter: 'two');
    await center.resume(next);
    await waitFor(() => next.state == 'done');
    await center.flush();
    expect(center.storageError, isNull);
    expect(await File('${center.folder(next)}/a.ts').exists(), false);
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(await restored.completedFile('source', 'movie', 'two'), isNotNull);
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
