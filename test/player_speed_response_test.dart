import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/features/video/player_speed_meter.dart';

void main() {
  test('background probes require sufficient buffering and no native traffic counter', () {
    bool allowed({
      int seconds = 20,
      bool buffering = false,
      bool native = false,
    }) => PlaybackSpeedMeter.canProbeInBackground(
      playing: true,
      buffering: buffering,
      buffered: Duration(seconds: seconds),
      foreground: true,
      hasNativeSpeed: native,
    );
    expect(allowed(), true);
    expect(allowed(seconds: 8), false);
    expect(allowed(buffering: true), false);
    expect(allowed(native: true), false);
  });
  test('canceling a background probe releases busy state without reporting failure', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    final client = LumeHttp(
      client: MockClient((_) {
        entered.complete();
        return response.future;
      }),
    );
    final meter = PlaybackSpeedMeter(http: client);
    final task = meter.measure(
      Uri.parse('https://example.test/slow.mp4'),
      background: true,
    );
    await entered.future;
    expect(meter.busy.value, true);
    meter.cancelBackground();
    await task;
    expect(meter.busy.value, false);
    expect(meter.failed.value, false);
    response.complete(http.Response(List.filled(4096, 'a').join(), 200));
    await Future<void>.delayed(Duration.zero);
    meter.dispose();
    client.dispose();
  });

  test('HLS 测媒体分片而非索引，保留防盗链头', () async {
    final urls = <String>[];
    final meter = PlaybackSpeedMeter(
      http: LumeHttp(
        client: MockClient((request) async {
          urls.add(request.url.path);
          expect(request.headers['referer'], 'https://example.com/');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (request.url.path == '/master.m3u8') {
            return http.Response(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nsub/media.m3u8\n',
              200,
            );
          }
          if (request.url.path == '/sub/media.m3u8') {
            return http.Response('#EXTM3U\n#EXTINF:10,\nsegment.ts\n', 200);
          }
          return http.Response(
            'x' * 16384,
            206,
            headers: {'Content-Type': 'video/mp2t'},
          );
        }),
      ),
    );
    addTearDown(meter.dispose);
    await meter.measure(
      Uri.parse('https://example.com/master.m3u8'),
      headers: {'Referer': 'https://example.com/'},
    );
    expect(urls, ['/master.m3u8', '/sub/media.m3u8', '/sub/segment.ts']);
    expect(meter.kbps.value, greaterThan(0));
  });

  for (final status in [403, 404, 500]) {
    test('HTTP $status 的大响应不能显示测速成功', () async {
      final meter = PlaybackSpeedMeter(
        http: LumeHttp(
          client: MockClient((request) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return http.Response('x' * 16384, status);
          }),
        ),
      );
      addTearDown(meter.dispose);
      await meter.measure(Uri.parse('https://example.com/video'));
      expect(meter.failed.value, isTrue);
      expect(meter.kbps.value, isNull);
      expect(meter.busy.value, isFalse);
    });
  }

  test('200 HTML 验证页不能显示测速成功', () async {
    final meter = PlaybackSpeedMeter(
      http: LumeHttp(
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response(
            'x' * 16384,
            200,
            headers: {'Content-Type': 'text/html; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(meter.dispose);
    await meter.measure(Uri.parse('https://example.com/video'));
    expect(meter.failed.value, isTrue);
    expect(meter.kbps.value, isNull);
  });

  test('覆盖源的小写 Range，206 媒体响应仍显示真实读数', () async {
    final meter = PlaybackSpeedMeter(
      http: LumeHttp(
        client: MockClient((request) async {
          expect(request.headers['range'], 'bytes=0-262143');
          expect(request.headers['referer'], 'https://example.com/');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response(
            'x' * 16384,
            206,
            headers: {'Content-Type': 'video/mp4'},
          );
        }),
      ),
    );
    addTearDown(meter.dispose);
    await meter.measure(
      Uri.parse('https://example.com/video'),
      headers: {'range': 'bytes=1000000-', 'Referer': 'https://example.com/'},
    );
    expect(meter.failed.value, isFalse);
    expect(meter.kbps.value, greaterThan(0));
  });
}
