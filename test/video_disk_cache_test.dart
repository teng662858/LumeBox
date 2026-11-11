import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';

void main() {
  late Directory root;
  late VideoDiskCache cache;
  late HttpServer server;
  late HttpClient client;
  late Uri upstream;
  final data = Uint8List.fromList(List.generate(2500000, (i) => i % 251));
  var calls = 0;
  final paths = <String>[];
  var failures = 0;

  for (final throws in [false, true]) {
    test('缓存装载失败回退原始地址并保留请求头：throws=$throws', () async {
      final player = _TransportPlayer(throws);
      final media = PlayerMedia(
        uri: upstream,
        headers: {'Referer': 'https://example.test/'},
      );
      await cache.load(player, media);
      expect(player.loads, hasLength(2));
      expect(player.loads.last, same(media));
      expect(player.state.value.error, isNull);
      expect(await cache.wrap(media), same(media));
      expect(cache.status, contains('内核缓冲'));
      player.state.dispose();
      player.info.dispose();
    });
  }
  test('内核暂时隐藏错误进行重试时，等待终态后仍回退原地址', () async {
    final player = _TransportPlayer(false, delayed: true);
    final media = PlayerMedia(uri: upstream);
    await cache.load(player, media);
    expect(player.loads, hasLength(2));
    expect(player.loads.last, same(media));
    expect(player.state.value.error, isNull);
    player.state.dispose();
    player.info.dispose();
  });
  Completer<void>? pause;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('video-buffer-test-');
    cache = VideoDiskCache();
    cache.freeSpace = () async => 10 * 1024 * 1024 * 1024;
    await cache.boot(directory: root);
    client = HttpClient();
    calls = 0;
    paths.clear();
    failures = 0;
    pause = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream = Uri.parse('http://127.0.0.1:${server.port}/movie.mp4');
    server.listen((request) async {
      calls++;
      paths.add(request.uri.path);
      if (request.uri.path.startsWith('/status/')) {
        request.response.statusCode = int.parse(request.uri.pathSegments.last);
        request.response.write('private upstream error body');
        await request.response.close();
        return;
      }
      if (pause != null) await pause!.future;
      if (failures > 0) {
        failures--;
        request.response.statusCode = 502;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/nested/master.m3u8');
        await request.response.close();
        return;
      }
      if (request.uri.path.endsWith('/master.m3u8')) {
        if (request.uri.path.startsWith('/no-range/') &&
            request.headers.value('range') != null) {
          request.response.statusCode = 502;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        const playlist =
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n';
        if (request.uri.path.startsWith('/gzip/')) {
          request.response.headers.set('Content-Encoding', 'gzip');
          request.response.add(gzip.encode(utf8.encode(playlist)));
        } else {
          request.response.write(playlist);
        }
      } else {
        final match = RegExp(r'bytes=(\d+)-(\d*)')
            .firstMatch(request.headers.value('range') ?? '');
        final start = match == null ? 0 : int.parse(match[1]!);
        final requestedEnd = match == null || match[2]!.isEmpty
            ? data.length - 1
            : int.parse(match[2]!);
        if (start >= data.length) {
          request.response.statusCode = 416;
          request.response.headers.set(
            'Content-Range',
            'bytes */${data.length}',
          );
          await request.response.close();
          return;
        }
        final end = requestedEnd.clamp(start, data.length - 1);
        request.response.statusCode = 206;
        // Reproduce a cat proxy declaring the whole remainder while sending
        // only one capped block. The host must stitch all subsequent ranges.
        request.response.headers.set(
          'Content-Range',
          'bytes $start-${data.length - 1}/${data.length}',
        );
        request.response.headers.set('Content-Type', 'video/mp4');
        final body = data.sublist(start, end + 1);
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await cache.close();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> get(Uri uri, [String? range]) async {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set('Range', range);
    final response = await request.close();
    return (response, await response.expand((b) => b).toList());
  }

  for (final status in [400, 401, 403, 404, 429, 500, 502, 503]) {
    test(
      'upstream HTTP $status is preserved without leaking its body',
      () async {
        final wrapped = await cache.wrap(
          PlayerMedia(uri: upstream.resolve('/status/$status')),
        );
        final (response, body) = await get(wrapped.uri);
        expect(response.statusCode, status);
        expect(body, isEmpty);
        expect(calls, [502, 503].contains(status) ? 2 : 1);
      },
    );
  }

  test(
    'settings filesystem errors are reported without breaking UI actions',
    () async {
      await Directory('${root.path}/video_buffer.json.tmp').create();
      await cache.configure(capacityMb: 777);
      expect(cache.capacityMb, 777);
      expect(cache.status, contains('保存或清理失败'));
    },
  );

  test(
    'concurrent settings writes persist the final complete snapshot',
    () async {
      await Future.wait([
        for (var i = 0; i < 20; i++)
          cache.configure(capacityMb: 700 + i, enabled: i.isEven),
      ]);
      final saved = jsonDecode(
        await File('${root.path}/video_buffer.json').readAsString(),
      );
      expect(saved, {'enabled': false, 'capacityMb': 719});
    },
  );

  test(
    'capped local ranges stream to EOF without a false end or quality change',
    () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final (response, body) = await get(wrapped.uri);
      expect(response.statusCode, 200);
      expect(response.contentLength, data.length);
      expect(body, data);
      expect(calls, 3);
      expect(cache.bytes, data.length);
      final (seekResponse, seek) = await get(wrapped.uri, 'bytes=100-399');
      expect(
        seekResponse.headers.value('content-range'),
        'bytes 100-399/${data.length}',
      );
      expect(seek, data.sublist(100, 400));
      expect(calls, 3, reason: 'overlapping seeks reuse cached blocks');
      expect(cache.hits, greaterThan(0));
    },
  );

  test(
    'capacity eviction and clear preserve playback and enforce bytes',
    () async {
      cache.capacityMb = 1;
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      expect((await get(wrapped.uri)).$2, data);
      expect(cache.bytes, lessThanOrEqualTo(1024 * 1024));
      expect(await cache.clear(), greaterThan(0));
      expect(cache.bytes, 0);
      expect(
        await Directory('${root.path}/video-buffer-v1').list().toList(),
        isEmpty,
      );
      expect((await get(wrapped.uri, 'bytes=0-15')).$2, data.sublist(0, 16));
    },
  );

  test(
    'low free space falls back to kernel buffering without failing playback',
    () async {
      cache.freeSpace = () async => 1024;
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      expect((await get(wrapped.uri)).$2, data);
      expect(cache.bytes, 0);
      expect(cache.status, contains('空间不足'));
    },
  );

  test(
    'HEAD, suffix ranges and unsatisfiable offsets obey HTTP semantics',
    () async {
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final head = await (await client.headUrl(wrapped.uri)).close();
      expect(head.contentLength, data.length);
      expect(await head.expand((e) => e).toList(), isEmpty);
      expect(
        (await get(wrapped.uri, 'bytes=-100')).$2,
        data.sublist(data.length - 100),
      );
      final (invalid, _) = await get(wrapped.uri, 'bytes=3000000-');
      expect(invalid.statusCode, 416);
      expect(invalid.headers.value('content-range'), 'bytes */${data.length}');
      expect((await get(wrapped.uri, 'bytes=0-3,10-12')).$1.statusCode, 416);
    },
  );

  test('temporary 502 retries once without a quality downgrade', () async {
    failures = 1;
    final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
    expect((await get(wrapped.uri, 'bytes=0-15')).$2, data.sublist(0, 16));
    expect(calls, 2);
    failures = 3;
    expect(
      (await get(wrapped.uri, 'bytes=1048576-1048591')).$1.statusCode,
      502,
    );
    expect(failures, 1, reason: 'bounded retry, no endless loop');
  });

  test(
    'clear invalidates an in-flight cache write without dropping its reader',
    () async {
      pause = Completer<void>();
      final wrapped = await cache.wrap(PlayerMedia(uri: upstream));
      final reading = get(wrapped.uri, 'bytes=0-15');
      while (calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await cache.clear();
      pause!.complete();
      expect((await reading).$2, data.sublist(0, 16));
      expect(cache.bytes, 0);
    },
  );

  test('HLS redirect base is used for relative segments and keys', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('redirect')),
    );
    final body = utf8.decode((await get(wrapped.uri)).$2);
    final segment = Uri.parse(
      const LineSplitter()
          .convert(body)
          .firstWhere((line) => line.startsWith('http')),
    );
    await get(segment, 'bytes=0-15');
    expect(calls, 3);
    expect(paths.last, '/nested/part.ts');
  });

  test(
    'extra disk read-ahead waits for playback reserve and is serial',
    () async {
      final media = PlayerMedia(uri: upstream);
      final wrapped = await cache.wrap(media);
      await get(wrapped.uri, 'bytes=0-15');
      cache.prefetch(media, const Duration(seconds: 60), allowed: false);
      expect(calls, 1);
      cache.prefetch(media, const Duration(seconds: 60), allowed: true);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (cache.bytes < data.length && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.bytes, data.length);
      expect(calls, 3);
      cache.prefetch(media, const Duration(seconds: 60), allowed: true);
      cache.stopPrefetch();
      expect(calls, 3);
    },
  );

  test('gzip HLS is decoded before rewriting and never cached', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/gzip/master.m3u8')),
    );
    final response = await get(wrapped.uri);
    expect(utf8.decode(response.$2), startsWith('#EXTM3U'));
    expect(utf8.decode(response.$2), isNot(contains('URI="key"')));
    expect(response.$1.headers.value('content-encoding'), isNull);
    expect(cache.bytes, 0);
  });

  test('HLS 清单按普通 GET 获取，兼容拒绝 Range 的服务器', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('/no-range/master.m3u8')),
    );
    final (response, body) = await get(wrapped.uri);
    expect(response.statusCode, 200);
    expect(utf8.decode(body), startsWith('#EXTM3U'));
  });

  test('HLS rewrites keys and segments and never caches a playlist', () async {
    final wrapped = await cache.wrap(
      PlayerMedia(uri: upstream.resolve('master.m3u8')),
    );
    final body = utf8.decode((await get(wrapped.uri)).$2);
    expect(body, startsWith('#EXTM3U'));
    expect(body, isNot(contains('URI="key"')));
    expect(body, isNot(contains('\npart.ts\n')));
    expect(cache.bytes, 0);
    await get(wrapped.uri);
    expect(calls, 2);
  });

  test(
    'memory mode still repairs local cat ranges; credentials stay private',
    () async {
      await cache.configure(enabled: false);
      final wrapped = await cache.wrap(
        PlayerMedia(uri: upstream, headers: {'Authorization': 'private'}),
      );
      expect(wrapped.uri.toString(), isNot(contains('private')));
      expect(wrapped.headers, isNull);
      expect((await get(wrapped.uri)).$2, data);
      expect(cache.bytes, 0);
      expect(
        (await get(wrapped.uri.replace(path: '/unknown'))).$1.statusCode,
        404,
      );
      final remote = PlayerMedia(
        uri: Uri.parse('https://example.test/movie.mp4'),
      );
      expect(await cache.wrap(remote), same(remote));
    },
  );
}

class _TransportPlayer extends AbstractPlayer {
  _TransportPlayer(this.throws, {this.delayed = false});
  final bool throws;
  final bool delayed;
  final loads = <PlayerMedia>[];
  final state = ValueNotifier(const PlayerSnapshot());
  final info = ValueNotifier(const PlayerStats());
  @override
  ValueNotifier<PlayerSnapshot> get snapshot => state;
  @override
  ValueNotifier<PlayerStats> get stats => info;
  @override
  Future<void> load(PlayerMedia media) async {
    loads.add(media);
    if (loads.length == 1) {
      if (throws) throw StateError('local connection failed');
      if (delayed) {
        state.value = const PlayerSnapshot(buffering: true);
        Future<void>.delayed(const Duration(milliseconds: 20), () {
          state.value = const PlayerSnapshot(error: 'HTTP 502');
        });
        return;
      }
      state.value = const PlayerSnapshot(error: 'local connection failed');
    } else {
      state.value = const PlayerSnapshot();
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> applySettings(PlayerSettings settings) async {}
  @override
  Widget buildView() => const SizedBox();
  @override
  Future<void> dispose() async {}
}
