import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/site_session_pool.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/player/source_media_runtime.dart';
import 'package:lume_box/core/js/source_tools.dart';

Uint8List hex(String value) => Uint8List.fromList(
  List.generate(
    value.length ~/ 2,
    (i) => int.parse(value.substring(i * 2, i * 2 + 2), radix: 16),
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SiteSessionPool.shared.clear());
  tearDown(() => SiteSessionPool.shared.clear());

  test('domain/path/secure/expiry isolation, host UA, and safe Referer', () {
    final pool = SiteSessionPool();
    pool.importCookies([
      {
        'name': 'sid',
        'value': 'root',
        'domain': '.example.test',
        'path': '/',
        'secure': true,
      },
      {
        'name': 'sid',
        'value': 'detail',
        'domain': 'a.example.test',
        'path': '/watch',
        'secure': true,
      },
      {
        'name': 'expired',
        'value': 'no',
        'domain': 'a.example.test',
        'path': '/',
        'expires': 1,
      },
      {'name': 'private', 'value': 'no', 'domain': 'other.test', 'path': '/'},
    ]);
    pool.setUserAgent('a.example.test', 'Desktop fixture');
    final headers = pool.headersFor(
      'https://a.example.test/watch/1',
      {},
      referer: 'https://a.example.test/detail#secret',
    );
    expect(headers['Cookie'], 'sid=detail');
    expect(headers['User-Agent'], 'Desktop fixture');
    expect(headers['Referer'], 'https://a.example.test/detail');
    expect(pool.headersFor('https://evil-example.test/', {}), isEmpty);
    expect(
      pool.headersFor(
        'http://a.example.test/',
        {},
        referer: 'https://a.example.test/private',
      )['Cookie'],
      isNull,
    );
    expect(
      pool.headersFor(
        'http://a.example.test/',
        {},
        referer: 'https://a.example.test/private',
      )['Referer'],
      isNull,
    );
    expect(
      pool.headersFor('https://b.example.test/', {})['User-Agent'],
      isNull,
    );
  });
  test('301 POST becomes GET; cross-origin credentials stripped; target cookie selected', () async {
    final pool = SiteSessionPool.shared;
    pool.importCookies([
      {'name': 'target', 'value': 'yes', 'domain': 'cdn.test', 'path': '/'},
    ]);
    final calls = <http.Request>[];
    final client = LumeHttp(
      client: MockClient((r) async {
        calls.add(r);
        if (r.url.host == 'origin.test') {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://cdn.test/media'},
          );
        }
        return http.Response('done', 200);
      }),
      settings: const NetworkSettings(maxRetries: 0),
    );
    addTearDown(client.dispose);
    final response = await client.send(
      url: 'https://origin.test/post',
      method: 'POST',
      body: 'secret',
      headers: {
        'Cookie': 'source=private',
        'Authorization': 'private',
        'Referer': 'https://origin.test/watch',
        'Content-Type': 'text/plain',
      },
    );
    expect(response.url, 'https://cdn.test/media');
    expect(calls.last.method, 'GET');
    expect(calls.last.body, isEmpty);
    expect(calls.last.headers['authorization'], isNull);
    expect(calls.last.headers['cookie'], 'target=yes');
    expect(calls.last.headers['referer'], 'https://origin.test/watch');
  });
  test('307 preserves binary POST and relative redirects; loops and file redirects fail', () async {
    var requests = 0;
    final client = LumeHttp(
      client: MockClient((r) async {
        requests++;
        if (r.url.path == '/first') {
          return http.Response('', 307, headers: {'location': 'second'});
        }
        expect(r.bodyBytes, [0, 128, 255]);
        expect(r.method, 'POST');
        return http.Response('done', 200);
      }),
      settings: const NetworkSettings(maxRetries: 0),
    );
    addTearDown(client.dispose);
    await client.sendBytes(
      url: 'https://site.test/first',
      method: 'POST',
      bodyBytes: [0, 128, 255],
    );
    expect(requests, 2);
    for (final location in ['/loop', 'file:///private/data']) {
      final invalid = LumeHttp(
        client: MockClient(
          (r) async => http.Response('', 302, headers: {'location': location}),
        ),
        settings: const NetworkSettings(maxRetries: 0),
      );
      await expectLater(
        invalid.send(url: 'https://site.test/loop'),
        throwsA(isA<LumeHttpException>()),
      );
      invalid.dispose();
    }
  });
  test(
    'server Set-Cookie is shared with next request, including deletion',
    () async {
      var index = 0;
      final client = LumeHttp(
        client: MockClient((r) async {
          if (index++ == 0) {
            return http.Response(
              'ok',
              200,
              headers: {'set-cookie': 'sid=one; Path=/; Secure'},
            );
          }
          expect(r.headers['cookie'], 'sid=one');
          return http.Response('ok', 200);
        }),
        settings: const NetworkSettings(maxRetries: 0),
      );
      addTearDown(client.dispose);
      await client.send(url: 'https://cookie.test/a');
      await client.send(url: 'https://cookie.test/b');
      SiteSessionPool.shared.absorb('https://cookie.test/', {
        'set-cookie': 'sid=gone; Path=/; Max-Age=0',
      });
      expect(
        SiteSessionPool.shared.headersFor('https://cookie.test/', {})['Cookie'],
        isNull,
      );
    },
  );
  test('host cooldown leaves other domains free; 5xx recover; 404 cache is credential-scoped', () async {
    final calls = <String, int>{};
    final events = <String>[];
    final queue = NetworkQueue(
      settings: const NetworkSettings(
        maxRetries: 1,
        retryBaseDelay: Duration(milliseconds: 20),
      ),
      random: Random(1),
      sender: (r) async {
        final host = Uri.parse(r.url).host;
        final n = calls.update(host, (v) => v + 1, ifAbsent: () => 1);
        if (host == 'dead.test') {
          return const NetworkResponse(statusCode: 404, body: [], headers: {});
        }
        events.add('$host$n');
        return NetworkResponse(
          statusCode: host == 'a.test' && n == 1 ? 502 : 200,
          body: [],
          headers: {},
        );
      },
    );
    final first = queue.send(const NetworkRequest(url: 'https://a.test/'));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await queue.send(const NetworkRequest(url: 'https://b.test/'));
    expect((await first).statusCode, 200);
    expect(events.indexOf('b.test1'), lessThan(events.indexOf('a.test2')));
    expect(queue.failuresForHost('a.test'), 0);
    await queue.send(const NetworkRequest(url: 'https://dead.test/'));
    await queue.send(const NetworkRequest(url: 'https://dead.test/'));
    expect(calls['dead.test'], 1);
    await queue.send(
      const NetworkRequest(
        url: 'https://dead.test/',
        headers: {'Authorization': 'different'},
      ),
    );
    expect(calls['dead.test'], 2);
    queue.clearInvalidLinks();
    await queue.send(const NetworkRequest(url: 'https://dead.test/'));
    expect(calls['dead.test'], 3);
    for (final status in [429, 500, 502, 503, 504]) {
      expect(NetworkQueue.isRetryable(status), true);
    }
    expect(NetworkQueue.isRetryable(403), false);
    expect(NetworkQueue.isRetryable(501), false);
  });
  test('HLS key rotation, sequence IV, byte ranges, NONE, explicit IV and unsupported schemes', () {
    final parsed = SourceMediaRuntime.parseM3u8('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI="../key?k=a,b"
#EXTINF:5,
#EXT-X-BYTERANGE:16@0
chunk.ts
#EXTINF:5,
#EXT-X-BYTERANGE:16
chunk.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:2,
clear.ts
#EXT-X-ENDLIST
''', Uri.parse('https://media.test/path/list.m3u8'));
    final items = parsed['segments'] as List;
    expect(items[0]['key']['url'], 'https://media.test/key?k=a,b');
    expect(items[0]['key']['iv'], '00000000000000000000000000000007');
    expect(items[1]['byteRange'], {'start': 16, 'length': 16});
    expect(items[2]['key'], isNull);
    expect(parsed['endList'], true);
    for (final bad in [
      '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k"',
      '#EXT-X-KEY:METHOD=AES-128,URI="file:///k"',
      '#EXT-X-KEY:METHOD=AES-128,URI="k",IV=0xZZ\nseg.ts',
    ]) {
      expect(
        () => SourceMediaRuntime.parseM3u8(
          '#EXTM3U\n$bad',
          Uri.parse('https://a.test/'),
        ),
        throwsFormatException,
      );
    }
  });
  test('segment retries, AES-128 key auto fetch/cache, and origin Referer reach CDN', () async {
    var keys = 0;
    var chunks = 0;
    final transport = LumeHttp(
      client: MockClient((r) async {
        if (r.url.path == '/list.m3u8') {
          return http.Response(
            '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI="https://key.test/key"\n#EXTINF:5,\nhttps://cdn.test/chunk.ts\n#EXT-X-ENDLIST',
            200,
          );
        }
        expect(r.headers['referer'], 'https://origin.test/list.m3u8');
        expect(r.headers['cookie'], isNot(contains('private')));
        if (r.url.host == 'key.test') {
          keys++;
          return http.Response.bytes(List.generate(16, (i) => i), 200);
        }
        if (chunks++ == 0) return http.Response('', 503);
        return http.Response.bytes(
          base64Decode('N4oOmh2fjjJ90Tg9wDjco8reW7s5aCvnM44JBBVR/x8='),
          200,
        );
      }),
      settings: const NetworkSettings(
        maxRetries: 2,
        retryBaseDelay: Duration.zero,
      ),
    );
    addTearDown(transport.dispose);
    final media = SourceMediaRuntime(transport);
    addTearDown(media.dispose);
    for (var i = 0; i < 2; i++) {
      final reply = await media.invoke({
        'operation': 'segment',
        'url': 'https://origin.test/list.m3u8',
        'index': 0,
        'headers': {'Cookie': 'source=private'},
      }) as Map;
      expect(
        utf8.decode(base64Decode(reply['data'] as String)),
        'LumeBox AES-128 segment fixture',
      );
    }
    expect(keys, 1);
    expect(chunks, 3);
  });
  test(
    'NIST AES CBC vector, OpenSSL PKCS8 RSA fixture, and shared encodings',
    () {
      final cipher = SourceTools.run({
        'operation': 'aes',
        'encrypt': true,
        'padding': 'none',
        'mode': 'CBC',
        'key': base64Encode(hex('2b7e151628aed2a6abf7158809cf4f3c')),
        'iv': base64Encode(hex('000102030405060708090a0b0c0d0e0f')),
        'data': base64Encode(hex('6bc1bee22e409f96e93d7e117393172a')),
      }) as String;
      expect(base64Decode(cipher), hex('7649abac8119b246cee98e9b12e9197d'));
      final private = File('test/fixtures/source_runtime/rsa_private.pem')
          .readAsStringSync();
      final encrypted = File('test/fixtures/source_runtime/rsa_cipher.base64')
          .readAsStringSync();
      final decrypted = SourceTools.run({
        'operation': 'rsa',
        'pem': private,
        'encrypt': false,
        'data': encrypted,
      }) as String;
      expect(utf8.decode(base64Decode(decrypted)), 'LumeBox RSA fixture');
      for (final algorithm in [
        'md5',
        'sha1',
        'sha224',
        'sha256',
        'sha384',
        'sha512',
      ]) {
        expect(
          SourceTools.run({
            'operation': 'digest',
            'algorithm': algorithm,
            'data': 'abc',
          }),
          isNotEmpty,
        );
      }
      final encoded = SourceTools.run({
        'operation': 'base64Encode',
        'data': '测试+ /',
      }) as String;
      expect(
        SourceTools.run({'operation': 'base64Decode', 'data': encoded}),
        '测试+ /',
      );
      final zipped = base64Encode(zlib.encode(utf8.encode('压缩测试')));
      expect(
        utf8.decode(
          base64Decode(
            SourceTools.run({'operation': 'inflate', 'data': zipped}) as String,
          ),
        ),
        '压缩测试',
      );
      final url = SourceTools.run({
        'operation': 'urlEncode',
        'data': '中文 +/?',
      }) as String;
      expect(
        SourceTools.run({'operation': 'urlDecode', 'data': url}),
        '中文 +/?',
      );
    },
  );
  test('FLV tag lengths/timestamps/codecs are checked; transient AV errors differ from 403', () {
    final data = Uint8List.fromList([
      70,
      76,
      86,
      1,
      5,
      0,
      0,
      0,
      9,
      0,
      0,
      0,
      0,
      9,
      0,
      0,
      1,
      0,
      0,
      42,
      0,
      0,
      0,
      0,
      0x17,
      0,
      0,
      0,
      12,
    ]);
    final flv = SourceMediaRuntime.inspectFlv(data);
    expect((flv['tags'] as List).single, {
      'type': 9,
      'timestampMs': 42,
      'size': 1,
      'videoCodec': 7,
    });
    data[data.length - 1] = 13;
    expect(() => SourceMediaRuntime.inspectFlv(data), throwsFormatException);
  });
}
