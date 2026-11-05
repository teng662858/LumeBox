import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/source/source_subscription_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('GitHub 拉取失败自动用 CDN，仍保留原始地址和强制更新请求头', () async {
    const url = 'https://raw.githubusercontent.com/example/sources/main/源.js';
    final calls = <Uri>[];
    final client = LumeHttp(
      client: MockClient((request) async {
        calls.add(request.url);
        expect(request.headers['Cache-Control'], 'no-cache');
        if (request.url.host == 'raw.githubusercontent.com') {
          throw const SocketException('offline');
        }
        return http.Response('var LumeSource = {};', 200);
      }),
      settings: const NetworkSettings(maxRetries: 0),
    );
    addTearDown(client.dispose);
    final resolver = SourceSubscription(
      fetch: (url) =>
          SourceSubscription.fetchSubscription(client, url, force: true),
    );
    final refs = await resolver.resolveRefs([url]);
    expect(refs.single.url, url);
    expect(calls.map((u) => u.host), [
      'raw.githubusercontent.com',
      'cdn.jsdelivr.net',
    ]);
    expect(
      Uri.decodeComponent(calls.last.path),
      '/gh/example/sources@main/源.js',
    );
  });
  test('真实 404 不用缓存 CDN 掩盖，自定义私有查询地址不改写', () async {
    var calls = 0;
    final client = LumeHttp(
      client: MockClient((_) async {
        calls++;
        return http.Response('missing', 404);
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      SourceSubscription.fetchSubscription(
        client,
        'https://raw.githubusercontent.com/example/sources/main/gone.js',
      ),
      throwsStateError,
    );
    expect(calls, 1);
    expect(
      SourceSubscription.githubCdnUrl('https://private.test/list'),
      isNull,
    );
    expect(
      SourceSubscription.githubCdnUrl(
        'https://raw.githubusercontent.com/a/b/main/file?token=secret',
      ),
      isNull,
    );
    expect(
      SourceSubscription.githubCdnUrl(
        'https://raw.githubusercontent.com/a/b/refs/heads/main/file',
      ),
      'https://cdn.jsdelivr.net/gh/a/b@main/file',
    );
  });
  test('旧官方 CDN 快照转到 GitHub，原站故障不再回退 CDN', () async {
    final calls = <Uri>[];
    final client = LumeHttp(
      client: MockClient((request) async {
        calls.add(request.url);
        throw const SocketException('offline');
      }),
      settings: const NetworkSettings(maxRetries: 0),
    );
    addTearDown(client.dispose);
    await expectLater(
      SourceSubscription.fetchSubscription(
        client,
        '${SubscriptionCatalog.cdnBase}subscriptions/cdn/video.11111111.txt',
      ),
      throwsA(isA<Exception>()),
    );
    expect(calls, isNotEmpty);
    expect(
      calls.every((url) => url.host == 'raw.githubusercontent.com'),
      isTrue,
    );
    expect(calls.first.path, endsWith('/subscriptions/video.txt'));
  });
}
