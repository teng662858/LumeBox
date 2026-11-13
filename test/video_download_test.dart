import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/experience/offline_policy.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/security/local_cipher.dart';
import 'package:lume_box/features/download/local_download_export.dart';
import 'package:lume_box/features/video/offline_video_server.dart';
import 'package:lume_box/features/video/video_download_center.dart';

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 30)) {
      throw StateError('test timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late Uri origin;
  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('lume-download-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}/');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<VideoDownloadCenter> center(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final value = VideoDownloadCenter(
      directory: () async => root,
      merge: (_, _, _) async => throw StateError('fixture cannot remux'),
      resolve: (_) async =>
          VideoContent(url: origin.resolve(path), headers: headers),
    );
    await value.boot();
    return value;
  }

  Future<void> enqueue(VideoDownloadCenter c) async => c.enqueue(
    sourceId: 'fixture',
    itemId: 'movie',
    title: 'Movie',
    chapters: const [SourceChapter(id: 'episode', title: 'Episode')],
  );
  test('网页下载重启后仍携带签名和请求头，任务清单只保存密文', () async {
    LocalCipher.configurePreview(root.path, LocalCipher.random(32));
    final c = VideoDownloadCenter(directory: () async => root);
    var allow = false;
    final calls = <String?>[];
    server.listen((request) async {
      calls.add(request.headers.value('cookie'));
      if (!allow) {
        request.response.statusCode = 403;
      } else {
        expect(request.uri.queryParameters['sign'], 'private-signature');
        expect(request.headers.value('referer'), 'https://fixture.test/watch');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.add([0, 0, 0, 24, ...ascii.encode('ftypisom')]);
      }
      await request.response.close();
    });
    await c.enqueue(
      sourceId: 'web-fixture',
      itemId: 'work',
      title: '影片',
      chapters: const [SourceChapter(id: 'web-episode-0', title: '正片')],
      captures: {
        'web-episode-0': VideoContent(
          url: origin.resolve('movie.mp4?sign=private-signature'),
          headers: {'Cookie': 'sid=private-cookie', 'Referer': 'https://fixture.test/watch'},
        ),
      },
    );
    await until(() => c.tasks.single.state == 'failed');
    await c.flush();
    final manifest = await File('${c.root.path}/tasks.json').readAsString();
    expect(manifest, contains(LocalCipher.prefix));
    for (final secret in ['private-cookie', 'private-signature', 'fixture.test/watch', 'movie.mp4']) {
      expect(manifest, isNot(contains(secret)));
    }
    allow = true;
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    await restored.resume(restored.tasks.single);
    await until(() => restored.tasks.single.state == 'done');
    await restored.flush();
    expect(calls, everyElement('sid=private-cookie'));
    expect(await restored.localFile(restored.tasks.single).length(), 12);
  });
  test('旧网页单集任务恢复后会移除清单里的明文签名', () async {
    LocalCipher.configurePreview(root.path, LocalCipher.random(32));
    final c = VideoDownloadCenter(directory: () async => root);
    await c.boot();
    final address = origin.resolve('legacy.mp4?token=private-token').toString();
    final old = VideoDownloadTask(
      id: VideoDownloadCenter.identity('web-fixture', 'captured-video', address),
      sourceId: 'web-fixture',
      itemId: 'captured-video',
      chapterId: address,
      title: '影片',
      chapterTitle: '正片',
    );
    final manifest = File('${c.root.path}/tasks.json');
    await manifest.writeAsString(jsonEncode([old.toJson()]));
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    final task = restored.tasks.single;
    expect(task.chapterId, 'web-episode-0');
    expect(task.state, 'paused');
    expect(await manifest.readAsString(), isNot(contains('private-token')));
    expect(task.encryptedCapture, startsWith(LocalCipher.prefix));
  });
  for (final remove in [false, true]) {
    test(
      'queued cancellation during network inspection skips the task (remove=$remove)',
      () async {
        final settings = ContentCenter.instance.data;
        final previous = settings['wifiOnly'];
        settings['wifiOnly'] = true;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final inspection = Completer<Map<String, Object?>>();
        final inspecting = Completer<void>();
        messenger.setMockMethodCallHandler(OfflinePolicy.channel, (_) async {
          if (inspecting.isCompleted) return {'wifi': true};
          inspecting.complete();
          return inspection.future;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(OfflinePolicy.channel, null);
          if (previous == null) {
            settings.remove('wifiOnly');
          } else {
            settings['wifiOnly'] = previous;
          }
        });
        final resolved = <String>[];
        final c = VideoDownloadCenter(
          directory: () async => root,
          resolve: (task) async {
            resolved.add(task.chapterId);
            throw StateError('fixture offline');
          },
        );
        await c.enqueue(
          sourceId: 's',
          itemId: 'i',
          title: 'Movie',
          chapters: const [
            SourceChapter(id: 'cancel', title: 'First'),
            SourceChapter(id: 'keep', title: 'Second'),
          ],
        );
        await inspecting.future;
        final first = c.tasks.first;
        if (remove) {
          await c.remove(first, deleteFiles: true);
        } else {
          await c.pause(first);
        }
        inspection.complete({'wifi': true});
        await until(() => c.tasks.last.state == 'failed');
        await c.flush();
        expect(resolved, ['keep']);
        expect(first.state, 'paused');
      },
    );
  }

  test(
    'HLS checks network policy before starting its segment requests',
    () async {
      final settings = ContentCenter.instance.data;
      final previous = settings['wifiOnly'];
      settings['wifiOnly'] = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var checks = 0, segments = 0;
      final inspecting = Completer<void>(), allow = Completer<bool>();
      messenger.setMockMethodCallHandler(OfflinePolicy.channel, (_) async {
        if (++checks < 3) return {'wifi': true};
        if (!inspecting.isCompleted) inspecting.complete();
        return {'wifi': await allow.future};
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(OfflinePolicy.channel, null);
        if (previous == null) {
          settings.remove('wifiOnly');
        } else {
          settings['wifiOnly'] = previous;
        }
      });
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/vod.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXTINF:1,\na.ts\n#EXTINF:1,\nb.ts\n#EXTINF:1,\nc.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          segments++;
          request.response.add([1, 2, 3]);
        }
        await request.response.close();
      });
      final c = await center('vod.m3u8');
      await enqueue(c);
      await inspecting.future;
      // While the device checks Wi-Fi, give any prematurely started requests
      // enough time to reach the loopback HTTP server.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      allow.complete(false);
      await until(() => c.tasks.single.state == 'paused');
      await c.flush();
      expect(segments, 0, reason: paths.toString());
      expect(c.tasks.single.error, contains('Wi-Fi'));
    },
  );

  test('offline media serves suffix ranges and reports invalid offsets', () async {
    await File('${root.path}/clip.mp4').writeAsBytes([10, 20, 30, 40]);
    final local = await OfflineVideoServer.open(root);
    final client = HttpClient();
    try {
      final uri = local.uri.resolve('clip.mp4');
      for (final (range, status, contentRange, bytes) in [
        ('bytes=-2', 206, 'bytes 2-3/4', [30, 40]),
        ('bytes=1-', 206, 'bytes 1-3/4', [20, 30, 40]),
        ('bytes=2-999999999999999999999', 206, 'bytes 2-3/4', [30, 40]),
        ('bytes=-0', 416, 'bytes */4', <int>[]),
        ('bytes=3-1', 416, 'bytes */4', <int>[]),
        ('bytes=999999999999999999999-', 416, 'bytes */4', <int>[]),
      ]) {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, range);
        final response = await request.close();
        expect(response.statusCode, status, reason: range);
        expect(response.headers.value('content-range'), contentRange);
        expect(await response.expand((chunk) => chunk).toList(), bytes);
      }
    } finally {
      client.close(force: true);
      await local.close();
    }
  });
  for (final playing in [false, true]) {
    test('HLS parallelism is bounded and yields to playback: $playing', () async {
      var active = 0, peak = 0;
      server.listen((request) async {
        if (request.uri.path == '/parallel.m3u8') {
          request.response.write(
            '#EXTM3U\n${List.generate(6, (i) => '#EXTINF:1,\npart$i.ts').join('\n')}\n#EXT-X-ENDLIST\n',
          );
        } else {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 25));
          request.response.add([1, 2, 3]);
          active--;
        }
        await request.response.close();
      });
      final c = VideoDownloadCenter(
        directory: () async => root,
        resolve: (_) async =>
            VideoContent(url: origin.resolve('parallel.m3u8')),
        playbackActive: () => playing,
        merge: (_, _, _) async => throw StateError('fixture cannot remux'),
      );
      await c.boot();
      await enqueue(c);
      await until(() => c.tasks.single.state == 'merge_failed');
      expect(peak, playing ? 1 : 3);
      expect(c.tasks.single.completed, 6);
      final body = await c.localFile(c.tasks.single).readAsString();
      final segments = const LineSplitter()
          .convert(body)
          .where((line) => line.contains('segment-'))
          .toList();
      expect(
        segments,
        orderedEquals(
          List.generate(
            6,
            (i) => segments.first.replaceFirst('segment-0', 'segment-$i'),
          ),
        ),
      );
      await c.flush();
      c.dispose();
    });
  }

  test('历史离线查找按源、作品和集数匹配，HLS 可播放且合并失败可重开', () async {
    final c = VideoDownloadCenter(directory: () async => root);
    await c.boot();
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('s', 'i', 'e'),
      sourceId: 's',
      itemId: 'i',
      chapterId: 'e',
      title: '测试',
      chapterTitle: '第3集',
      chapterIndex: 2,
      line: '备用线路',
      state: 'merge_failed',
      fileName: 'episode.m3u8',
    );
    c.tasks.add(task);
    await Directory(c.folder(task)).create(recursive: true);
    await c
        .localFile(task)
        .writeAsString('#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n');
    await File('${c.folder(task)}/part.ts').writeAsBytes([1, 2, 3]);
    expect(await c.completedPlayback('other', 'i', 'e'), isNull);
    final playback = (await c.completedPlayback('s', 'i', 'e'))!;
    final client = HttpClient();
    final response = await (await client.getUrl(playback.uri)).close();
    expect(await response.transform(utf8.decoder).join(), contains('part.ts'));
    final part = await (await client.getUrl(playback.uri.resolve('part.ts')))
        .close();
    expect(await part.fold<List<int>>([], (a, b) => a..addAll(b)), [1, 2, 3]);
    client.close(force: true);
    await playback.close();
    await c.flush();
    await File('${c.root.path}/tasks.json')
        .writeAsString(jsonEncode(c.tasks.map((t) => t.toJson()).toList()));
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(restored.tasks.single.chapterIndex, 2);
    expect(restored.tasks.single.line, '备用线路');
    expect(await restored.completedFile('s', 'i', 'e'), isNotNull);
    restored.dispose();
    task.state = 'paused';
    expect(await c.completedFile('s', 'i', 'e'), isNotNull);
    task.state = 'merging';
    expect(await c.completedFile('s', 'i', 'e'), isNull);
    task.state = 'done';
    await c.localFile(task).delete();
    expect(await c.completedFile('s', 'i', 'e'), isNull);
    c.dispose();
  });

  test('旧猫源下载原地恢复，再次加入队列保留原文件和任务', () async {
    final old = await center('unused');
    const source = 'subscription|video|site';
    const item = 'movie', chapter = 'episode';
    final legacy = VideoDownloadTask(
      id: VideoDownloadCenter.identity(source, item, chapter), sourceId: source,
      itemId: item, chapterId: chapter, title: '旧猫源', chapterTitle: '第1集',
      state: 'done', fileName: 'media.mp4',
    );
    await Directory(old.folder(legacy)).create();
    final file = old.localFile(legacy);
    await file.writeAsBytes([4, 5, 6]);
    final manifest = File('${old.root.path}/tasks.json');
    await manifest.writeAsString(jsonEncode([legacy.toJson()..remove('section')]));
    final restored = await center('unused');
    expect(restored.tasks.single.section, Section.cat);
    await restored.enqueue(section: Section.cat, sourceId: source, itemId: item, title: '旧猫源',
        chapters: const [SourceChapter(id: chapter, title: '第1集')]);
    expect(restored.tasks.single.id, legacy.id);
    final reopened = await center('unused');
    final playback = await reopened.completedFile(source, item, chapter, section: Section.cat);
    expect(playback?.path, file.path);
    expect(await playback!.readAsBytes(), [4, 5, 6]);
    expect(await reopened.completedFile(source, item, chapter), isNull);
  });

  test('damaged manifest entries do not hide playable downloads after restart', () async {
    final c = await center('unused');
    Map<String, Object?> entry(String chapter) => VideoDownloadTask(
      id: VideoDownloadCenter.identity('s', 'i', chapter),
      sourceId: 's',
      itemId: 'i',
      chapterId: chapter,
      title: 'Movie',
      chapterTitle: chapter,
      state: 'done',
      fileName: 'media.mp4',
    ).toJson();
    final older = entry('older')..['bytes'] = 'unknown';
    final latest = entry('latest')..['chapterIndex'] = 4;
    for (final row in [older, latest]) {
      final dir = await Directory('${c.root.path}/${row['id']}').create();
      await File('${dir.path}/media.mp4').writeAsBytes([1, 2, 3]);
    }
    await File('${c.root.path}/tasks.json').writeAsString(
      jsonEncode([older, null, entry('bad')..['id'] = 'invalid', latest]),
    );
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(restored.tasks.map((t) => t.chapterId), ['older', 'latest']);
    expect(restored.tasks.first.bytes, 0);
    expect(restored.tasks.last.chapterIndex, 4);
    for (final chapter in ['older', 'latest']) {
      final playback = await restored.completedPlayback('s', 'i', chapter);
      expect(await File.fromUri(playback!.uri).readAsBytes(), [1, 2, 3]);
      await playback.close();
    }
  });

  test('selecting a previously downloaded episode repairs its saved index locally', () async {
    var requests = 0;
    server.listen((r) async {
      requests++;
      r.response.add(List.filled(32, 1));
      await r.response.close();
    });
    final c = await center('movie.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => task.state == 'done');
    await c.flush();
    expect(task.chapterIndex, 0);
    await c.enqueue(
      sourceId: 'fixture',
      itemId: 'movie',
      title: 'Movie',
      chapters: const [SourceChapter(id: 'episode', title: 'Episode')],
      chapterIndices: const {'episode': 4},
    );
    await c.flush();
    final restored = await center('movie.mp4');
    expect(restored.tasks.single.chapterIndex, 4);
    expect(restored.tasks.single.state, 'done');
    expect(requests, 1);
  });

  test('a missing completed file can be downloaded again after restart', () async {
    server.listen((r) async {
      r.response.add(List.filled(32, 1));
      await r.response.close();
    });
    final c = await center('movie.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => task.state == 'done');
    await c.flush();
    await c.localFile(task).delete();
    final restored = await center('movie.mp4');
    final missing = restored.tasks.single;
    expect(missing.canPlayOffline, isFalse);
    expect(missing.state, 'paused');
    await restored.resume(missing);
    await until(() => missing.state == 'done');
    await restored.flush();
    expect(await restored.localFile(missing).readAsBytes(), List.filled(32, 1));
  });

  test('下载 HLS 跳过明确标记的广告，不请求广告分片', () async {
    final requested = <String>[];
    server.listen((request) async {
      requested.add(request.uri.path);
      if (request.uri.path == '/ad.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXTINF:1,\nmain.ts\n#EXT-X-CUE-OUT:1\n#EXTINF:1,\nad.ts\n#EXT-X-CUE-IN\n#EXTINF:1,\nnext.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final c = await center('ad.m3u8');
    await enqueue(c);
    await until(() => c.tasks.single.state == 'merge_failed');
    expect(requested, containsAll(['/main.ts', '/next.ts']));
    expect(requested, isNot(contains('/ad.ts')));
    expect(c.tasks.single.completed, 2);
    await c.flush();
    c.dispose();
  });

  test(
    'unsupported playlists are rejected before any segments are scheduled',
    () {
      expect(
        VideoDownloadCenter.unsupportedPlaylistReason(
          '#EXTM3U\n#EXT-X-BYTERANGE:3\nfile.ts\n#EXT-X-ENDLIST',
        ),
        contains('字节范围'),
      );
      expect(
        VideoDownloadCenter.unsupportedPlaylistReason(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\n#EXT-X-ENDLIST',
        ),
        contains('加密'),
      );
      expect(
        VideoDownloadCenter.unsupportedPlaylistReason(
          '#EXTM3U\n#EXTINF:1,\na.ts',
        ),
        contains('直播'),
      );
    },
  );

  test('MP4 is persisted, survives restart, and resolved URLs and headers are not serialized', () async {
    final data = Uint8List.fromList([
      0,
      0,
      0,
      24,
      ...ascii.encode('ftypisom'),
      ...List.filled(1000, 42),
    ]);
    server.listen((r) async {
      r.response.headers.contentType = ContentType('video', 'mp4');
      r.response.contentLength = data.length;
      r.response.add(data);
      await r.response.close();
    });
    final c = await center(
      'movie.mp4?token=private',
      headers: {'Cookie': 'session=private', 'Authorization': 'Bearer private'},
    );
    await enqueue(c);
    await until(() => c.tasks.single.state == 'done');
    await c.flush();
    expect(await c.localFile(c.tasks.single).readAsBytes(), data);
    final manifest = await File('${c.root.path}/tasks.json').readAsString();
    expect(manifest, isNot(contains('private')));
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(restored.tasks.single.state, 'done');
    expect(await restored.localFile(restored.tasks.single).readAsBytes(), data);
  });
  for (final knownLength in [false, true]) {
    test(
      'partial HTTP responses finish every range before publishing the file (known length=$knownLength)',
      () async {
        final data = List.generate(103, (i) => i);
        final offsets = <int>[];
        server.listen((request) async {
          final range = request.headers.value('range') ?? 'bytes=0-';
          final start = int.parse(range.substring(6, range.length - 1));
          offsets.add(start);
          if (start == data.length) {
            request.response.statusCode = 416;
            request.response.headers.set(
              'content-range',
              'bytes */${data.length}',
            );
          } else {
            final end = (start + 31).clamp(0, data.length - 1);
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/${knownLength ? data.length : "*"}',
            );
            request.response.contentLength = end - start + 1;
            request.response.add(data.sublist(start, end + 1));
          }
          await request.response.close();
        });
        final c = await center('capped.mp4');
        await enqueue(c);
        final task = c.tasks.single;
        await until(() => ['done', 'failed'].contains(task.state));
        await c.flush();
        expect(task.state, 'done', reason: task.error);
        expect(await c.localFile(task).readAsBytes(), data);
        expect(task.totalBytes, data.length);
        expect(offsets, [0, 32, 64, 96, if (!knownLength) 103]);
      },
    );
  }

  for (final resume in [false, true]) {
    test('a terminal 416 completes the download before its error body ends (resume=$resume)', () async {
      final data = List.generate(32, (i) => i);
      final body = Completer<void>();
      var requests = 0;
      server.listen((r) async {
        requests++;
        if (requests == 1) {
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes 0-31/*');
          r.response.add(data);
        } else if (resume && requests == 2) {
          r.response.statusCode = 503;
        } else {
          r.response.statusCode = 416;
          r.response.headers.set('Content-Range', 'bytes */32');
          r.response.write('end of file');
          await r.response.flush();
          await body.future;
        }
        await r.response.close();
      });
      final c = await center('capped.mp4');
      try {
        await enqueue(c);
        final task = c.tasks.single;
        if (resume) {
          await until(() => task.state == 'failed');
          await c.resume(task);
        }
        await until(() => task.state == 'done').timeout(const Duration(seconds: 3));
        expect(await c.localFile(task).readAsBytes(), data);
        expect(task.totalBytes, data.length);
      } finally {
        body.complete();
        await c.flush();
      }
    });
  }

  for (final (address, resolved, suffix, resumed) in [
    ('play?e=1', 'play?e=1', '.mkv', false),
    ('play?e=1', 'signed.webm', '.webm', false),
    ('movie.mp4', 'movie.mp4', '.mkv', true),
  ]) {
    test('offline container uses the file header and final URL ($resolved, resumed=$resumed)', () async {
      final bytes = [0x1a, 0x45, 0xdf, 0xa3, ...List.filled(28, 0)];
      var failed = false;
      server.listen((r) async {
        if (r.uri.toString() != '/$resolved') {
          r.response.statusCode = 302;
          r.response.headers.set('Location', resolved);
        } else if (!resumed || r.headers.value('range') == null) {
          if (resumed) {
            r.response.statusCode = 206;
            r.response.headers.set('Content-Range', 'bytes 0-31/*');
          }
          r.response.add(bytes);
        } else if (!failed) {
          failed = true;
          r.response.statusCode = 503;
        } else {
          r.response.statusCode = 416;
          r.response.headers.set('Content-Range', 'bytes */32');
        }
        await r.response.close();
      });
      final c = await center(address);
      await enqueue(c);
      final task = c.tasks.single;
      if (resumed) {
        await until(() => task.state == 'failed');
        await c.resume(task);
      }
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.fileName, 'media$suffix', reason: task.error);
      expect(await c.localFile(task).readAsBytes(), bytes);
    });
  }

  test('抓取的 Range 与缓存条件不会截断整片下载，防盗链请求头仍生效', () async {
    final data = List.generate(64, (i) => i);
    server.listen((r) async {
      if (r.headers.value('if-none-match') != null) {
        r.response.statusCode = 304;
      } else if (r.headers.value('range') != null || r.headers.value('if-range') != null) {
        r.response.statusCode = 416;
      } else if (r.headers.value('referer') != 'https://fixture.test/watch') {
        r.response.statusCode = 403;
      } else {
        r.response.add(data);
      }
      await r.response.close();
    });
    final c = await center('captured.mp4', headers: {
      'Range': 'bytes=32-63',
      'If-Range': '"old-probe"',
      'IF-NONE-MATCH': '"browser-cache"',
      'Referer': 'https://fixture.test/watch',
    });
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['failed', 'done'].contains(task.state));
    await c.flush();
    expect(task.state, 'done', reason: task.error);
    expect(await c.localFile(task).readAsBytes(), data);
  });

  for (final kind in ['weak-etag', 'recent-date', 'established-date']) {
    test('续传只发送可用于字节校验的 If-Range ($kind)', () async {
      var retry = false;
      final conditions = <String?>[];
      final starts = <int>[];
      final replacement = List.generate(64, (i) => i);
      final date = DateTime.utc(2026, 1, 1);
      final modified = HttpDate.format(kind == 'established-date'
          ? date.subtract(const Duration(minutes: 5)) : date);
      final expected = kind == 'established-date' ? modified : null;
      server.listen((r) async {
        final condition = r.headers.value('if-range');
        conditions.add(condition);
        final start = r.headers.value('range') == 'bytes=32-' ? 32 : 0;
        if (retry) starts.add(start);
        if (!retry && start > 0) {
          r.response.statusCode = 503;
        } else if (condition != (start == 0 ? null : expected)) {
          r.response.statusCode = 400;
        } else {
          r.response.statusCode = 206;
          r.response.headers.set('Date', HttpDate.format(date));
          r.response.headers.set('Last-Modified', modified);
          if (kind == 'weak-etag') r.response.headers.set('ETag', 'W/"same"');
          r.response.headers.set('Content-Range', 'bytes $start-${start + 31}/64');
          r.response.add(retry || expected != null
              ? replacement.sublist(start, start + 32) : List.filled(32, 255));
        }
        await r.response.close();
      });
      final c = await center('weak.mp4');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => task.state == 'failed');
      retry = true;
      await c.flush();
      final restored = await center('weak.mp4');
      final saved = restored.tasks.single;
      await restored.resume(saved);
      await until(() => ['failed', 'done'].contains(saved.state));
      await restored.flush();
      expect(saved.state, 'done', reason: saved.error);
      expect(conditions, [null, expected, if (expected == null) null, expected]);
      expect(starts, [if (expected == null) 0, 32]);
      expect(await restored.localFile(saved).readAsBytes(), replacement);
    });
  }

  test('malformed partial response cannot become a completed video', () async {
    server.listen((request) async {
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-999/32');
      request.response.add(List.filled(32, 6));
      await request.response.close();
    });
    final c = await center('bad.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['done', 'failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'failed');
    expect(task.fileName, isEmpty);
  });

  test('a changed validator on the terminal 416 keeps a partial download unpublished', () async {
    server.listen((r) async {
      if (r.headers.value('range') == null) {
        r.response.statusCode = 206;
        r.response.headers.set('ETag', '"old"');
        r.response.headers.set('Content-Range', 'bytes 0-31/*');
        r.response.add(List.filled(32, 1));
      } else {
        r.response.statusCode = 416;
        r.response.headers.set('ETag', '"new"');
        r.response.headers.set('Content-Range', 'bytes */32');
      }
      await r.response.close();
    });
    final c = await center('replaced.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['done', 'failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'failed');
    expect(task.fileName, isEmpty);
  });

  for (final restartApp in [false, true]) {
    test('retains a video version first reported on a later range (restartApp=$restartApp)', () async {
      var attempt = 0;
      final conditions = <String?>[];
      final replacement = List<int>.generate(96, (i) => i);
      server.listen((r) async {
        attempt++;
        conditions.add(r.headers.value('if-range'));
        if (restartApp && attempt == 3) {
          r.response.statusCode = 503;
        } else if (attempt > 2 && r.headers.value('range') == null) {
          r.response.headers.set('ETag', '"replacement"');
          r.response.add(replacement);
        } else {
          final start = switch (r.headers.value('range')) {
            'bytes=32-' => 32,
            'bytes=64-' => 64,
            _ => 0,
          };
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes $start-${start + 31}/96');
          if (attempt >= 2) {
            r.response.headers.set('ETag', attempt == 2 ? '"original"' : '"replacement"');
          }
          r.response.add(attempt <= 2 ? List<int>.filled(32, 99) : replacement.sublist(start));
        }
        await r.response.close();
      });
      var c = await center('movie.mp4');
      await enqueue(c);
      await until(() => ['failed', 'done'].contains(c.tasks.single.state));
      await c.flush();
      expect(c.tasks.single.state, 'failed', reason: 'a mixed file must never be published');
      expect(c.tasks.single.canPlayOffline, isFalse);
      if (restartApp) c = await center('movie.mp4');
      final task = c.tasks.single;
      await c.resume(task);
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'done', reason: task.error);
      expect(await c.localFile(task).readAsBytes(), replacement);
      expect(conditions, [null, null, '"original"', '"original"', null]);
    });
  }

  test('downloads compressed HLS manifests, keys and segments as playable bytes', () async {
    final paths = <String>[];
    final segment = List<int>.generate(188, (i) => i);
    final key = List<int>.filled(16, 42);
    server.listen((request) async {
      paths.add(request.uri.path);
      final plain = switch (request.uri.path) {
        '/play' => utf8.encode('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia\n'),
        '/media' => utf8.encode('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXTINF:1,\ns.ts\n#EXT-X-ENDLIST\n'),
        '/k' => key,
        _ => segment,
      };
      final deflate = request.uri.path == '/media';
      final bytes = deflate ? zlib.encode(plain) : gzip.encode(plain);
      request.response.headers.set('Content-Encoding', deflate ? 'deflate' : 'gzip');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final c = await center('play');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['done', 'failed', 'merge_failed'].contains(task.state));
    await c.flush();
    expect(task.fileName, 'index.m3u8', reason: task.error);
    expect(paths, containsAll(['/play', '/media', '/k', '/s.ts']));
    final files = await Directory(c.folder(task)).list(recursive: true).where((f) => f is File).cast<File>().toList();
    expect(await files.singleWhere((f) => f.path.endsWith('.key')).readAsBytes(), key);
    expect(await files.singleWhere((f) => f.path.endsWith('.ts')).readAsBytes(), segment);
  });
  test('decodes a capped gzip media stream after stitching its wire ranges', () async {
    final data = List<int>.generate(1024, (i) => i % 251);
    final wire = gzip.encode(data);
    final starts = <int>[];
    server.listen((r) async {
      final range = r.headers.value('range');
      final start = range == null ? 0 : int.parse(range.substring(6, range.length - 1));
      starts.add(start);
      final end = (start + 39).clamp(start, wire.length - 1);
      r.response.statusCode = 206;
      r.response.headers.set('content-encoding', 'gzip');
      r.response.headers.set('content-range', 'bytes $start-$end/${wire.length}');
      r.response.contentLength = end - start + 1;
      r.response.add(wire.sublist(start, end + 1));
      await r.response.close();
    });
    final c = await center('capped.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['done', 'failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'done', reason: task.error);
    expect(starts, containsAllInOrder([0, 40, 80]));
    expect(await c.localFile(task).readAsBytes(), data);
    expect(task.bytes, data.length);
  });
  for (final (change, status, sameTag) in [
    ('query', 206, false),
    ('redirect', 206, false),
    ('query', 416, false),
    ('redirect', 206, true),
    ('query', 206, true),
    ('query', 416, true),
    ('header', 206, false),
    ('header', 416, false),
    ('header', 206, true),
  ]) {
    test('a changed media request checks the partial file ($change, status=$status, sameTag=$sameTag)', () async {
      var version = 'old';
      final newBytes = List.generate(status == 416 ? 32 : 64, (i) => i);
      final resumedRanges = <String?>[];
      final c = VideoDownloadCenter(
        directory: () async => root,
        resolve: (_) async => VideoContent(
          url: origin.resolve(switch (change) {
            'redirect' => 'play',
            'header' => 'file.mp4',
            _ => 'file.mp4?v=$version',
          }),
          headers: change == 'header' ? {'Authorization': 'private-$version'} : const {},
        ),
      );
      server.listen((request) async {
        final response = request.response;
        final range = request.headers.value('range');
        if (change == 'header') expect(request.headers.value('authorization'), 'private-$version');
        if (sameTag) response.headers.set('ETag', '"movie"');
        if (version == 'new' && request.uri.path == '/file.mp4') {
          resumedRanges.add(range);
        }
        if (request.uri.path == '/play') {
          response.statusCode = 302;
          response.headers.set('Location', 'file.mp4?v=$version');
        } else if (version == 'old') {
          if (range == null) {
            response.statusCode = 206;
            response.headers.set('Content-Range', 'bytes 0-31/${status == 416 ? '*' : 64}');
            response.add(sameTag && change == 'header' ? newBytes.sublist(0, 32) : List.filled(32, 99));
          } else {
            response.statusCode = 503;
          }
        } else if (range != null) {
          response.statusCode = status;
          if (status == 416) {
            response.headers.set('Content-Range', 'bytes */32');
          } else {
            response.headers.set('Content-Range', 'bytes 32-63/64');
            response.add(newBytes.sublist(32));
          }
        } else {
          response.add(newBytes);
        }
        await response.close();
      });
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => task.state == 'failed');
      expect(task.bytes, 32);
      final metadata = await File('${c.folder(task)}/resume.json').readAsString();
      expect(metadata, isNot(contains('private-old')));
      version = 'new';
      await c.resume(task);
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'done', reason: task.error);
      expect(await c.localFile(task).readAsBytes(), newBytes);
      expect(resumedRanges, ['bytes=32-', if (!sameTag || change != 'header') null]);
    });
  }

  for (final tag in [null, '"same-revision"']) {
    test('a redirect during a range sequence cannot mix two files (tag=$tag)', () async {
      server.listen((r) async {
        if (tag != null) r.response.headers.set('ETag', tag);
        final range = r.headers.value('range');
        if (range != null && r.uri.path == '/file.mp4') {
          r.response.statusCode = 302;
          r.response.headers.set('Location', 'other.mp4');
        } else {
          final start = range == null ? 0 : 32;
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes $start-${start + 31}/64');
          r.response.add(List.filled(32, start));
        }
        await r.response.close();
      });
      final c = await center('file.mp4');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'failed');
      expect(task.fileName, isEmpty);
    });
  }

  for (final status in [206, 416]) {
    test('a late total length survives an interrupted download (HTTP $status)', () async {
      final ranges = <String?>[];
      final replacement = List<int>.generate(status == 416 ? 64 : 96, (i) => i);
      server.listen((r) async {
        final range = r.headers.value('range');
        ranges.add(range);
        switch (ranges.length) {
          case 1:
          case 2:
            final start = range == null ? 0 : 32;
            r.response.statusCode = 206;
            r.response.headers.set('Content-Range', 'bytes $start-${start + 31}/${range == null ? "*" : 128}');
            r.response.add(List<int>.filled(32, 99));
          case 3:
            r.response.statusCode = 503;
          case 4:
            r.response.statusCode = status;
            if (status == 416) {
              r.response.headers.set('Content-Range', 'bytes */64');
            } else {
              r.response.headers.set('Content-Range', 'bytes 64-95/96');
              r.response.add(replacement.sublist(64));
            }
          default:
            r.response.add(replacement);
        }
        await r.response.close();
      });
      final c = await center('movie.mp4');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => task.state == 'failed');
      await c.resume(task);
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'done', reason: task.error);
      expect(await c.localFile(task).readAsBytes(), replacement);
      expect(ranges, [null, 'bytes=32-', 'bytes=64-', 'bytes=64-', null]);
    });

    test('a changed file length restarts a partial download (HTTP $status)', () async {
      final next = List.generate(status == 206 ? 80 : 32, (i) => i);
      var requests = 0;
      server.listen((r) async {
        requests++;
        if (requests == 1) {
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes 0-31/64');
          r.response.add(List.filled(32, 99));
        } else if (requests == 2) {
          r.response.statusCode = 503;
        } else if (r.headers.value('range') != null) {
          r.response.statusCode = status;
          if (status == 206) {
            r.response.headers.set('Content-Range', 'bytes 32-79/80');
            r.response.add(next.sublist(32));
          } else {
            r.response.headers.set('Content-Range', 'bytes */32');
          }
        } else {
          r.response.add(next);
        }
        await r.response.close();
      });
      final c = await center('file.mp4');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => task.state == 'failed');
      await c.resume(task);
      await until(() => ['done', 'failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'done', reason: task.error);
      expect(await c.localFile(task).readAsBytes(), next);
    });
  }

  test('resumed download restarts if the CDN returns a different ETag with 206', () async {
    final ranges = <String?>[];
    final next = List<int>.generate(64, (i) => i);
    server.listen((r) async {
      final range = r.headers.value('range');
      ranges.add(range);
      r.response.headers.set('ETag', ranges.length == 1 ? '"old"' : '"new"');
      if (ranges.length == 1) {
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes 0-31/64');
        r.response.add(List<int>.filled(32, 99));
      } else if (ranges.length == 2) {
        r.response.statusCode = 503;
      } else if (range != null) {
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes 32-63/64');
        r.response.add(next.sublist(32));
      } else {
        r.response.add(next);
      }
      await r.response.close();
    });
    final c = await center('changed.mp4');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => task.state == 'failed');
    await c.resume(task);
    await until(() => ['done', 'failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'done', reason: task.error);
    expect(await c.localFile(task).readAsBytes(), next);
    expect(ranges, [null, 'bytes=32-', 'bytes=32-', null]);
  });

  test(
    'a capped HLS segment is stored in full before it becomes playable offline',
    () async {
      final data = List.generate(20, (i) => i);
      server.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          final start = request.headers.value('range') == 'bytes=10-' ? 10 : 0;
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-${start + 9}/20',
          );
          request.response.add(data.sublist(start, start + 10));
        }
        await request.response.close();
      });
      final c = await center('index.m3u8');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => ['failed', 'merge_failed'].contains(task.state));
      await c.flush();
      final local = c.localFile(task);
      final segment = (await local.readAsLines()).firstWhere(
        (line) => line.endsWith('.ts'),
      );
      expect(
        await File.fromUri(local.uri.resolve(segment)).readAsBytes(),
        data,
      );
    },
  );

  test('pause then resume uses Range and preserves exact file bytes', () async {
    final data = Uint8List.fromList(List.generate(256 * 1024, (i) => i % 251));
    final ranges = <String?>[];
    server.listen((r) async {
      try {
        final range = r.headers.value('range');
        ranges.add(range);
        final start = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        r.response.headers.set('ETag', '"fixture"');
        r.response.headers.contentType = ContentType('video', 'mp4');
        if (start > 0) {
          r.response.statusCode = 206;
          r.response.headers.set(
            'Content-Range',
            'bytes $start-${data.length - 1}/${data.length}',
          );
        }
        r.response.contentLength = data.length - start;
        for (var offset = start; offset < data.length; offset += 4096) {
          r.response.add(
            data.sublist(offset, (offset + 4096).clamp(0, data.length)),
          );
          await r.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await r.response.close();
      } catch (_) {}
    });
    final c = await center('movie.mp4');
    await enqueue(c);
    await until(() => c.tasks.single.bytes > 8192);
    await c.pause(c.tasks.single);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await c.resume(c.tasks.single);
    await until(() => c.tasks.single.state == 'done');
    await c.flush();
    expect(ranges.any((r) => r != null), true);
    expect(await c.localFile(c.tasks.single).readAsBytes(), data);
  });
  test('a 200 login page in an HLS segment is retried before publishing the playlist', () async {
    final attempts = <String, int>{};
    server.listen((r) async {
      final path = r.uri.path;
      attempts[path] = (attempts[path] ?? 0) + 1;
      if (path == '/index.m3u8') {
        r.response.write('#EXTM3U\n#EXTINF:1,\ngood.ts\n#EXTINF:1,\nblocked.ts\n#EXT-X-ENDLIST\n');
      } else if (path == '/blocked.ts' && attempts[path] == 1) {
        r.response.headers.set('Content-Encoding', 'gzip');
        r.response.add(gzip.encode(utf8.encode('<!doctype html><html>sign in</html>')));
      } else {
        r.response.add([0x47, 2, 3, 4]);
      }
      await r.response.close();
    });
    final c = await center('index.m3u8');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['failed', 'merge_failed'].contains(task.state));
    expect(task.state, 'failed');
    expect(task.canPlayOffline, false);
    await c.resume(task);
    await until(() => ['failed', 'merge_failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'merge_failed', reason: 'fixture remux is disabled');
    expect(attempts['/good.ts'], 1);
    expect(attempts['/blocked.ts'], 2);
    expect(task.completed, 2);
  });

  test('HLS retries completed fragments, stores AES-128 keys, and plays through local HTTP without origin access', () async {
    var first = 0, second = 0, keys = 0;
    const playlist =
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n';
    server.listen((r) async {
      switch (r.uri.path) {
        case '/index.m3u8':
          r.response.write(playlist);
        case '/key':
          keys++;
          r.response.add(List.filled(16, 7));
        case '/a.ts':
          first++;
          r.response.add(List.filled(188, 65));
        case '/b.ts':
          second++;
          if (second == 1) {
            r.response.statusCode = 500;
          } else {
            r.response.add(List.filled(188, 66));
          }
      }
      await r.response.close();
    });
    final headers = {'X-Route': 'test', 'Authorization': 'private-fixture'};
    final c = await center('index.m3u8', headers: headers);
    await enqueue(c);
    await until(() => c.tasks.single.state == 'failed');
    headers
      ..clear()
      ..addAll({'authorization': 'private-fixture', 'x-route': 'test'});
    await c.resume(c.tasks.single);
    await until(() => c.tasks.single.state == 'merge_failed');
    await c.flush();
    expect(first, 1);
    expect(second, 2);
    expect(keys, 2);
    expect(c.tasks.single.completed, 2);
    final local = await OfflineVideoServer.open(
      Directory(c.folder(c.tasks.single)),
    );
    final client = HttpClient();
    try {
      final r = await (await client.getUrl(local.uri)).close();
      final text = await utf8.decodeStream(r);
      expect(text, contains('#EXTM3U'));
      expect(text, isNot(contains(origin.toString())));
      final segment = const LineSplitter()
          .convert(text)
          .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
      final request = await client.getUrl(local.uri.resolve(segment));
      request.headers.set('Range', 'bytes=0-2');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((b) => b).toList(), [65, 65, 65]);
    } finally {
      client.close(force: true);
      await local.close();
    }
  });
  test('offline HLS keeps credentials scoped to each rendition', () async {
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => cdn.close(force: true));
    final auth = <String, String?>{};
    final referers = <String?>[];
    void record(HttpRequest request) {
      auth[request.uri.path] = request.headers.value('authorization');
      referers.add(request.headers.value('referer'));
    }
    cdn.listen((r) async {
      record(r);
      await r.response.redirect(origin.resolve('audio.m3u8'));
    });
    server.listen((r) async {
      record(r);
      switch (r.uri.path) {
        case '/master':
          r.response.write('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",URI="audio"\n#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO="a"\nvideo.m3u8\n');
        case '/audio':
          await r.response.redirect(Uri.parse('http://127.0.0.1:${cdn.port}/bounce'));
          return;
        case '/audio.m3u8':
          r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\nsound.aac\n#EXT-X-ENDLIST\n');
        case '/video.m3u8':
          r.response.write('#EXTM3U\n#EXTINF:1,\npicture.ts\n#EXT-X-ENDLIST\n');
        case '/key':
        case '/sound.aac':
        case '/picture.ts':
          r.response.add(List<int>.filled(16, 1));
        default:
          r.response.statusCode = 404;
      }
      await r.response.close();
    });
    final c = await center('master', headers: {
      'Authorization': 'source-only',
      'Referer': 'https://viewer.example/',
    });
    await enqueue(c);
    await until(() => ['failed', 'merge_failed'].contains(c.tasks.single.state));
    await c.flush();
    expect(c.tasks.single.state, 'merge_failed', reason: c.tasks.single.error);
    expect(await c.localFile(c.tasks.single).exists(), isTrue);
    expect(auth, {
      '/master': 'source-only',
      '/audio': 'source-only',
      '/bounce': null,
      '/audio.m3u8': null,
      '/key': null,
      '/sound.aac': null,
      '/video.m3u8': 'source-only',
      '/picture.ts': 'source-only',
    });
    expect(referers, everyElement('https://viewer.example/'));
  });

  test('redirected HLS playlists resolve media against each final URL', () async {
    final finishRedirect = Completer<void>();
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => cdn.close(force: true));
    final paths = <String>[], hosts = <String?>[], auth = <String?>[];
    final sourcePaths = <String>[];
    server.listen((r) async {
      sourcePaths.add(r.uri.path);
      if (r.uri.path == '/play') {
        r.response.statusCode = 302;
        r.response.headers.set('Location', 'http://127.0.0.1:${cdn.port}/show/master.m3u8');
        r.response.write('redirecting');
        await r.response.flush();
        await finishRedirect.future;
        await r.response.close();
      } else {
        r.response.statusCode = 404;
        await r.response.close();
      }
    });
    cdn.listen((r) async {
      paths.add(r.uri.path);
      hosts.add(r.headers.value('host'));
      auth.add(r.headers.value('authorization'));
      void capped(List<int> bytes) {
        final raw = r.headers.value('range') ?? 'bytes=0-';
        final start = int.parse(raw.substring(6, raw.length - 1));
        final stop = (start + 16).clamp(0, bytes.length);
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes $start-${stop - 1}/${bytes.length}');
        r.response.add(bytes.sublist(start, stop));
      }
      switch (r.uri.path) {
        case '/show/master.m3u8':
          capped(utf8.encode('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",URI="audio"\n#EXT-X-STREAM-INF:BANDWIDTH=123,AUDIO="a"\nvideo\n'));
        case '/show/audio':
        case '/show/video':
          r.response.statusCode = 302;
          r.response.headers.set('location', '/media/${r.uri.pathSegments.last}/stream.m3u8');
        case '/media/audio/stream.m3u8':
          capped(utf8.encode('#EXTM3U\n#EXTINF:1,\nsound.aac\n#EXT-X-ENDLIST\n'));
        case '/media/video/stream.m3u8':
          r.response.write('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1,\nfirst.m4s\n#EXT-X-ENDLIST\n');
        case '/media/audio/sound.aac':
        case '/media/video/init.mp4':
        case '/media/video/first.m4s':
          r.response.statusCode = 302;
          r.response.headers.set('Location', '/storage/segment');
        case '/storage/segment':
          capped(List<int>.generate(33, (i) => i));
        default:
          r.response.statusCode = 404;
      }
      await r.response.close();
    });
    final c = await center('play', headers: {
      'Authorization': 'source-only',
      'Host': 'source.example',
    });
    await enqueue(c);
    try {
      await until(() => ['failed', 'merge_failed'].contains(c.tasks.single.state))
          .timeout(const Duration(seconds: 2));
    } finally {
      finishRedirect.complete();
    }
    await c.flush();
    expect(sourcePaths, ['/play']);
    for (final path in ['/show/audio', '/show/video', '/media/video/first.m4s']) {
      expect(paths.where((value) => value == path), hasLength(1));
    }
    expect(paths, containsAll(['/media/audio/sound.aac', '/media/video/init.mp4', '/media/video/first.m4s']));
    expect(hosts, everyElement('127.0.0.1:${cdn.port}'));
    expect(auth, everyElement(isNull));
    expect(c.tasks.single.fileName, 'index.m3u8');
  });
  test('offline HLS removes verified PNG wrappers only from plaintext TS segments', () async {
    final ts = List<int>.filled(188 * 5, 0);
    for (var i = 0; i < ts.length; i += 188) {
      ts.setAll(i, [0x47, 0x40, 0, 0x10]);
    }
    final wrapped = [137, 80, 78, 71, 13, 10, 26, 10, ...List.filled(32768, 0), ...ts];
    server.listen((r) async {
      if (r.uri.path.endsWith('.m3u8')) {
        r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXTINF:1,\ncipher.png\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:1,\nclear.png\n#EXT-X-ENDLIST\n');
      } else if (r.uri.path == '/k') {
        r.response.add(List<int>.filled(16, 9));
      } else {
        r.response.add(wrapped.sublist(0, 3));
        await r.response.flush();
        r.response.add(wrapped.sublist(3));
      }
      await r.response.close();
    });
    final c = await center('index.m3u8');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['failed', 'merge_failed'].contains(task.state));
    await c.flush();
    final playlist = c.localFile(task);
    final parts = (await playlist.readAsLines()).where((line) => line.endsWith('.ts')).toList();
    expect(await File.fromUri(playlist.uri.resolve(parts.first)).readAsBytes(), wrapped);
    final clear = await File.fromUri(playlist.uri.resolve(parts.last)).readAsBytes();
    expect(clear.length, ts.length);
    expect(clear, ts);
  });

  test('HLS retries do not mix segments or AES keys from a different playlist location', () async {
    var generation = 'old';
    server.listen((r) async {
      final path = r.uri.path;
      if (path == '/play') {
        await r.response.redirect(origin.resolve('/$generation/index.m3u8'));
        return;
      }
      if (path.endsWith('index.m3u8')) {
        r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,\na.ts\n#EXTINF:1,\nb.ts\n#EXT-X-ENDLIST\n');
      } else if (path == '/old/b.ts') {
        r.response.statusCode = 503;
      } else {
        r.response.add(List<int>.filled(path.endsWith('/key') ? 16 : 188, path.startsWith('/old/') ? 1 : 2));
      }
      await r.response.close();
    });
    final c = await center('play');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => task.state == 'failed');
    generation = 'new';
    await c.resume(task);
    await until(() => ['failed', 'merge_failed'].contains(task.state));
    await c.flush();
    expect(task.fileName, 'index.m3u8', reason: task.error);
    final local = await c.localFile(task).readAsLines();
    final paths = [
      RegExp(r'URI="([^"]+)"').firstMatch(local.join('\n'))![1]!,
      ...local.where((line) => line.endsWith('.ts')),
    ];
    for (final path in paths) {
      final bytes = await File.fromUri(c.localFile(task).uri.resolve(path)).readAsBytes();
      expect(bytes, everyElement(2), reason: path);
    }
  });

  for (final rotatedKey in [false, true]) {
    test('HLS resume rejects stale downloaded resources after a header or key changes (key=$rotatedKey)', () async {
      var version = 1;
      final c = VideoDownloadCenter(
        directory: () async => root,
        merge: (_, _, _) async => throw StateError('fixture cannot remux'),
        resolve: (_) async => VideoContent(
          url: origin.resolve('index.m3u8'),
          headers: {'Authorization': 'token-${rotatedKey ? 1 : version}'},
        ),
      );
      server.listen((r) async {
        final generation = rotatedKey ? version : int.parse(r.headers.value('authorization')!.split('-').last);
        switch (r.uri.path) {
          case '/index.m3u8':
            r.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x00000000000000000000000000000000\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1,\na.m4s\n#EXTINF:1,\nb.m4s\n#EXT-X-ENDLIST\n');
          case '/key':
            r.response.add(List.filled(16, rotatedKey ? generation : 9));
          default:
            if (generation == 1 && r.uri.path == '/b.m4s') {
              r.response.statusCode = 503;
            } else {
              r.response.add(List.filled(32, generation));
            }
        }
        await r.response.close();
      });
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => task.state == 'failed');
      version = 2;
      await c.resume(task);
      await until(() => ['failed', 'merge_failed'].contains(task.state));
      await c.flush();
      expect(task.state, 'merge_failed', reason: task.error);
      final manifest = await c.localFile(task).readAsString();
      final refs = [
        for (final m in RegExp(r'URI="([^"]+)"').allMatches(manifest)) m[1]!,
        ...LineSplitter.split(manifest).where((line) => line.endsWith('.m4s')),
      ];
      expect(refs, hasLength(4));
      for (final path in refs) {
        expect(await File.fromUri(c.localFile(task).uri.resolve(path)).readAsBytes(),
            everyElement(path.endsWith('.key') && !rotatedKey ? 9 : 2), reason: path);
      }
    });
  }
  test('offline master retains in-band audio, alternate languages and caption descriptors', () async {
    final requests = <String>[];
    server.listen((r) async {
      requests.add(r.uri.path);
      if (r.uri.path == '/master.m3u8') {
        r.response.write(
          [
            '#EXTM3U',
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Original",DEFAULT=YES,AUTOSELECT=YES',
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",LANGUAGE="en",NAME="English, dubbed",URI="en.m3u8"',
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",LANGUAGE="fr",NAME="French",URI="fr.m3u8"',
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="Other",URI="unused.m3u8"',
            '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English",INSTREAM-ID="CC1"',
            '#EXT-X-STREAM-INF:BANDWIDTH=500,CODECS="flac"',
            'audio-only.m3u8',
            '#EXT-X-STREAM-INF:SUBTITLES="subs",BANDWIDTH=100,CODECS="avc1.64001f,mp4a.40.2",AUDIO="main",CLOSED-CAPTIONS="cc"',
            '# video rendition',
            '',
            'video.m3u8',
          ].join('\n'),
        );
      } else if (r.uri.path.endsWith('.m3u8')) {
        r.response.write(
          '#EXTM3U\n#EXTINF:1,\n${r.uri.path.substring(1)}.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        r.response.add([1, 2, 3]);
      }
      await r.response.close();
    });
    final c = await center('master.m3u8');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => ['failed', 'merge_failed'].contains(task.state));
    await c.flush();
    expect(task.state, 'merge_failed', reason: task.error);
    final master = await c.localFile(task).readAsString();
    expect(master, contains('NAME="Original",DEFAULT=YES'));
    expect(master, contains('NAME="English, dubbed"'));
    expect(master, contains('NAME="French"'));
    expect(master, contains('INSTREAM-ID="CC1"'));
    expect(master, contains('#EXT-X-STREAM-INF:BANDWIDTH=100,'));
    expect(requests, containsAll(['/en.m3u8', '/fr.m3u8', '/video.m3u8']));
    expect(requests, isNot(contains('/unused.m3u8')));
    expect(requests, isNot(contains('/audio-only.m3u8')));
    for (final m in RegExp(r'URI="([^"]+)"').allMatches(master)) {
      expect(
        await File.fromUri(c.localFile(task).uri.resolve(m[1]!)).exists(),
        isTrue,
      );
    }
  });

  for (final (extension, mime, bsid) in [
    ('ac3', 'audio/ac3', 8),
    ('ec3', 'audio/eac3', 16),
    ('eac3', 'audio/eac3', 16),
  ]) {
    test('offline Dolby audio keeps its format in new and legacy downloads ($extension)', () async {
      final frame = [0x0b, 0x77, 0, 63, 0, bsid << 3, ...List.filled(122, 0)];
      final bytes = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, ...frame, ...frame];
      server.listen((r) async {
        if (r.uri.path.endsWith('.m3u8')) {
          r.response.write('#EXTM3U\n#EXTINF:1,\nsound.$extension?sig=x\n#EXT-X-ENDLIST\n');
        } else {
          r.response.add(bytes);
        }
        await r.response.close();
      });
      final c = await center('audio.m3u8');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => ['failed', 'merge_failed'].contains(task.state));
      await c.flush();
      final playlist = await c.localFile(task).readAsLines();
      final segment = playlist.firstWhere((l) => !l.startsWith('#'));
      expect(segment, endsWith('.$extension'));
      final playback = (await c.completedPlayback('fixture', 'movie', 'episode'))!;
      final client = HttpClient();
      try {
        await File('${c.folder(task)}/legacy.ts').writeAsBytes(bytes);
        for (final path in [segment, 'legacy.ts']) {
          final request = await client.getUrl(playback.uri.resolve(path));
          request.headers.set('Range', 'bytes=14-19');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(response.headers.contentType?.mimeType, mime);
          expect(await response.expand((b) => b).toList(), frame.take(6));
        }
      } finally {
        client.close(force: true);
        await playback.close();
      }
    });
  }

  test('offline fMP4 segments from signed endpoints retain their MP4 media type', () async {
    final init = [0, 0, 0, 8, ...ascii.encode('ftyp')];
    final fragment = [0, 0, 0, 8, ...ascii.encode('moof')];
    server.listen((r) async {
      switch (r.uri.path) {
        case '/index.m3u8':
          r.response.write('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n'
              '#EXT-X-MAP:URI="asset?id=init"\n#EXTINF:1,\nasset?id=part\n#EXT-X-ENDLIST\n');
        default:
          r.response.add(r.uri.queryParameters['id'] == 'init' ? init : fragment);
      }
      await r.response.close();
    });
    final c = await center('index.m3u8');
    await enqueue(c);
    final task = c.tasks.single;
    await until(() => task.state == 'merge_failed');
    await c.flush();
    final local = await OfflineVideoServer.open(Directory(c.folder(task)));
    final client = HttpClient();
    try {
      final manifest = await c.localFile(task).readAsString();
      final segment = LineSplitter.split(manifest).firstWhere((line) => !line.startsWith('#'));
      expect(segment, endsWith('.m4s'));
      final response = await (await client.getUrl(local.uri.resolve(segment))).close();
      expect(response.headers.contentType?.mimeType, 'video/mp4');
      expect(await response.expand((b) => b).toList(), fragment);
      // Older releases saved the same fragments under a TS filename.
      final legacy = File('${c.folder(task)}/legacy.ts');
      await legacy.writeAsBytes(fragment);
      final old = await (await client.headUrl(local.uri.resolve('legacy.ts'))).close();
      expect(old.headers.contentType?.mimeType, 'video/mp4');
      await old.drain<void>();
    } finally {
      client.close(force: true);
      await local.close();
    }
  });

  test('HLS master retains a selected separate audio rendition', () async {
    final paths = <String>[];
    server.listen((r) async {
      paths.add(r.uri.path);
      switch (r.uri.path) {
        case '/master.m3u8':
          r.response.write(
            '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Original",DEFAULT=YES,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO="audio"\nvideo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow.m3u8\n',
          );
        case '/audio.m3u8':
          r.response.write('#EXTM3U\n#EXTINF:1,\na.aac\n#EXT-X-ENDLIST\n');
        case '/video.m3u8':
          r.response.write('#EXTM3U\n#EXTINF:1,\nv.ts\n#EXT-X-ENDLIST\n');
        default:
          r.response.add([1, 2, 3]);
      }
      await r.response.close();
    });
    final c = await center('master.m3u8');
    await enqueue(c);
    await until(() => c.tasks.single.state == 'merge_failed');
    await c.flush();
    expect(
      paths,
      containsAll(['/audio.m3u8', '/video.m3u8', '/a.aac', '/v.ts']),
    );
    expect(paths, isNot(contains('/low.m3u8')));
    final master = await c.localFile(c.tasks.single).readAsString();
    expect(master, contains('URI="index-audio.m3u8"'));
  });
  for (final (tag, reason) in [
    ('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key?METHOD=NONE"', '加密'),
    ('#EXT-X-KEY:METHOD=AES-128', '密钥地址'),
    ('#EXT-X-MAP:BYTERANGE="128@32"', '初始化片段地址'),
    ('#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXT-X-MAP:URI="init.mp4"', 'IV'),
  ]) {
    test('unsupported or incomplete HLS fails before any resource request: $tag', () async {
      final requested = <String>[];
      server.listen((r) async {
        requested.add(r.uri.path);
        if (r.uri.path == '/entry.m3u8') {
          r.response.write('#EXTM3U\n$tag\n#EXTINF:1,\ns.ts\n#EXT-X-ENDLIST\n');
        } else {
          r.response.add(List.filled(16, 1));
        }
        await r.response.close();
      });
      final c = await center('entry.m3u8');
      await enqueue(c);
      final task = c.tasks.single;
      await until(() => ['merge_failed', 'failed'].contains(task.state));
      await c.flush();
      expect(requested, ['/entry.m3u8']);
      expect(task.error, contains(reason));
      expect(task.fileName, isEmpty);
    });
  }

  test(
    'DRM HLS is reported as a failure, never as a completed download',
    () async {
      server.listen((r) async {
        r.response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST\n',
        );
        await r.response.close();
      });
      final c = await center('index.m3u8');
      await enqueue(c);
      await until(() => c.tasks.single.state == 'failed');
      expect(c.tasks.single.error, contains('加密格式'));
      expect(c.tasks.single.fileName, '');
      await c.flush();
    },
  );
  test('live HLS is rejected before fetching segments', () async {
    final requested = <String>[];
    server.listen((r) async {
      requested.add(r.uri.path);
      r.response.write('#EXTM3U\n#EXTINF:1,\nsegment.ts\n');
      await r.response.close();
    });
    final c = await center('live.m3u8');
    await enqueue(c);
    await until(() => c.tasks.single.state == 'failed');
    await c.flush();
    expect(c.tasks.single.error, contains('直播流'));
    expect(requested, ['/live.m3u8']);
  });
  test('HLS ZIP export includes only local referenced files and survives export cancellation', () async {
    final dir = await Directory('${root.path}/offline').create();
    await Directory('${dir.path}/segments').create();
    await File('${dir.path}/index.m3u8')
        .writeAsString('#EXTM3U\n#EXTINF:1,\nsegments/a.ts\n#EXT-X-ENDLIST\n');
    await File('${dir.path}/segments/a.ts').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/resume.json').writeAsString('private');
    final saved = await LocalDownloadExport.directory(
      dir,
      entryPoint: 'index.m3u8',
      exporter: (file) async {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          archive.files.map((f) => f.name),
          containsAll(['index.m3u8', 'segments/a.ts']),
        );
        expect(
          archive.files.map((f) => f.name),
          isNot(contains('resume.json')),
        );
        return false;
      },
    );
    expect(saved, false);
    expect(await File('${dir.path}/index.m3u8').exists(), true);
  });
}
