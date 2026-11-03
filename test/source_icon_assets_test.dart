import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/source/source_favicon.dart';

void main() {
  testWidgets('离线本地标识不写入成功缓存，网络恢复后自动替换', (tester) async {
    await tester.runAsync(() async {
      final directory = Directory.systemTemp.createTempSync('icon-retry-');
      try {
        var online = false;
        var now = DateTime(2026, 10, 29);
        var requests = 0;
        final picture = img.Image(width: 32, height: 32);
        img.fill(picture, color: img.ColorRgb8(255, 0, 0));
        final resolver = SourceFavicon(
          now: () => now,
          cacheDirectory: () async => directory,
          fetchHtmlHomepage: false,
          http: LumeHttp(
            client: MockClient((_) async {
              requests++;
              return online
                  ? http.Response.bytes(
                      img.encodePng(picture),
                      200,
                      headers: {'content-type': 'image/png'},
                    )
                  : http.Response('offline', 403);
            }),
          ),
        );
        final fallback = await resolver.load(
          origin: 'https://retry.invalid',
          sourceId: 'x8x8_video',
        );
        expect(img.decodePng(fallback!)!.width, 192);
        expect(directory.listSync(), isEmpty);
        final before = requests;
        await resolver.load(
          origin: 'https://retry.invalid',
          sourceId: 'x8x8_video',
        );
        expect(requests, before, reason: '失败冷却期间不反复请求');
        online = true;
        now = now.add(const Duration(minutes: 3));
        final real = await resolver.load(
          origin: 'https://retry.invalid',
          sourceId: 'x8x8_video',
        );
        expect(img.decodePng(real!)!.width, 32);
        expect(directory.listSync(), hasLength(1));
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  test('hxc 同类的全透明 PNG 和 ICO 不能遮掉备用图标', () {
    final blank = img.Image(width: 16, height: 16, numChannels: 4);
    expect(SourceFavicon.storedIcon(img.encodePng(blank)), isNull);
    expect(SourceFavicon.storedIcon(img.encodeIco(blank)), isNull);
  });

  testWidgets('内置图标离线可显示，真实图片均有来源和校验值', (tester) async {
    await tester.runAsync(() async {
      final index = jsonDecode(
        await rootBundle.loadString('assets/source_icons/index.json'),
      ) as Map;
      expect(
        index.keys,
        containsAll([
          'libvio_video',
          'czzy_video',
          'bfzy_video',
          'insav_video',
          'd9y1w_video',
          'uaa_video',
          'lao4j_video',
          'kpdz_video',
          'mitaovideo_video',
          'pypack_608941541d9f77a7',
        ]),
      );
      var requests = 0;
      final resolver = SourceFavicon(
        http: LumeHttp(
          client: MockClient((_) async {
            requests++;
            return http.Response('offline', 404);
          }),
        ),
      );
      for (final entry in index.entries) {
        final metadata = entry.value as Map;
        if (metadata['kind'] == 'site') {
          final asset = await rootBundle.load(
            'assets/source_icons/${metadata['file']}',
          );
          expect(
            sha256
                .convert(
                  asset.buffer.asUint8List(
                    asset.offsetInBytes,
                    asset.lengthInBytes,
                  ),
                )
                .toString(),
            metadata['sha256'],
          );
          expect(Uri.parse(metadata['url'] as String).host, isNotEmpty);
        } else {
          expect(metadata['labels'], isNotEmpty);
        }
        final bytes = await resolver.load(
          origin: '',
          sourceId: entry.key as String,
        );
        expect(bytes, isNotNull, reason: entry.key);
        final image = img.decodePng(bytes!);
        expect(image, isNotNull, reason: entry.key);
        expect(image!.width, greaterThan(0));
        expect(image.height, greaterThan(0));
      }
      expect(requests, 0, reason: '内置备用不等待离线站点');
    });
  });

  testWidgets('自动获取的新站点图片可替换本地标识，自定义地址优先', (tester) async {
    await tester.runAsync(() async {
      final red = img.Image(width: 32, height: 32);
      img.fill(red, color: img.ColorRgb8(255, 0, 0));
      final png = img.encodePng(red);
      final resolver = SourceFavicon(
        fetchHtmlHomepage: false,
        http: LumeHttp(
          client: MockClient(
            (request) async =>
                request.url.path == '/favicon.ico' ||
                    request.url.path == '/custom.png'
                ? http.Response.bytes(
                    png,
                    200,
                    headers: {'content-type': 'image/png'},
                  )
                : http.Response('missing', 404),
          ),
        ),
      );
      expect(
        img.decodePng((await resolver.bundledFallback('jcomic_comic'))!)!.width,
        192,
      );
      final best = await resolver.load(
        origin: 'https://fixture.invalid',
        sourceId: 'jcomic_comic',
      );
      expect(
        img.decodePng(best!)!.width,
        32,
        reason: '真实站点图标替换文字标识，不按标识的画布大小拒绝',
      );
      final custom = await resolver.load(
        origin: '',
        sourceId: 'jcomic_comic',
        explicit: ['https://fixture.invalid/custom.png'],
      );
      expect(img.decodePng(custom!)!.getPixel(0, 0).r, 255);
    });
  });
}
