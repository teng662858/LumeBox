import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/experience/content_center.dart';
import 'package:lume_box/core/experience/offline_policy.dart';
import 'package:lume_box/core/source/source.dart';
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
    expect(await restored.completedFile('s', 'i', 'e'), isNotNull);
    restored.dispose();
    task.state = 'paused';
    expect(await c.completedFile('s', 'i', 'e'), isNull);
    task.state = 'done';
    await c.localFile(task).delete();
    expect(await c.completedFile('s', 'i', 'e'), isNull);
    c.dispose();
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
  test('HLS retries completed fragments, stores AES-128 keys, and plays through local HTTP without origin access', () async {
    var first = 0, second = 0;
    const playlist =
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n';
    server.listen((r) async {
      switch (r.uri.path) {
        case '/index.m3u8':
          r.response.write(playlist);
        case '/key':
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
    final c = await center('index.m3u8');
    await enqueue(c);
    await until(() => c.tasks.single.state == 'failed');
    await c.resume(c.tasks.single);
    await until(() => c.tasks.single.state == 'merge_failed');
    await c.flush();
    expect(first, 1);
    expect(second, 2);
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
  test('redirected HLS playlists resolve media against each final URL', () async {
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => cdn.close(force: true));
    final paths = <String>[], hosts = <String?>[], auth = <String?>[];
    final sourcePaths = <String>[];
    server.listen((r) async {
      sourcePaths.add(r.uri.path);
      if (r.uri.path == '/play') {
        await r.response.redirect(Uri.parse('http://127.0.0.1:${cdn.port}/show/master.m3u8'));
      } else {
        r.response.statusCode = 404;
        await r.response.close();
      }
    });
    cdn.listen((r) async {
      paths.add(r.uri.path);
      hosts.add(r.headers.value('host'));
      auth.add(r.headers.value('authorization'));
      switch (r.uri.path) {
        case '/show/master.m3u8':
          r.response.write('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",URI="audio"\n#EXT-X-STREAM-INF:BANDWIDTH=123,AUDIO="a"\nvideo\n');
        case '/show/audio':
        case '/show/video':
          r.response.statusCode = 302;
          r.response.headers.set('location', '/media/${r.uri.pathSegments.last}/stream.m3u8');
        case '/media/audio/stream.m3u8':
          r.response.write('#EXTM3U\n#EXTINF:1,\nsound.aac\n#EXT-X-ENDLIST\n');
        case '/media/video/stream.m3u8':
          r.response.write('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1,\nfirst.m4s\n#EXT-X-ENDLIST\n');
        case '/media/audio/sound.aac':
        case '/media/video/init.mp4':
        case '/media/video/first.m4s':
          r.response.add([1, 2, 3]);
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
    await until(() => ['failed', 'merge_failed'].contains(c.tasks.single.state));
    await c.flush();
    expect(sourcePaths, ['/play']);
    expect(paths, containsAll(['/media/audio/sound.aac', '/media/video/init.mp4', '/media/video/first.m4s']));
    expect(hosts, everyElement('127.0.0.1:${cdn.port}'));
    expect(auth, everyElement(isNull));
    expect(c.tasks.single.fileName, 'index.m3u8');
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
