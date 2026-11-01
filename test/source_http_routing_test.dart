import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/site_session_pool.dart';
import 'package:lume_box/core/source/source_extension_settings.dart';

void main() {
  setUp(() => SiteSessionPool.shared.clear());
  tearDown(() => SiteSessionPool.shared.clear());

  for (final destination in [
    'https://new.example',
    'https://old.example:8443',
  ]) {
    test('换站 $destination 使用目标登录会话并同步 Origin/Referer/Host', () async {
      final target = Uri.parse(destination);
      SiteSessionPool.shared.importCookies([
        {
          'name': 'login',
          'value': 'destination',
          'domain': target.host,
          'path': '/',
          'secure': true,
        },
      ]);
      SiteSessionPool.shared.userAgents[target.host] = 'destination-UA';
      final route = SourceRoute(
        urls: const ['https://old.example'],
        custom: destination,
      );
      late http.Request sent;
      final transport = LumeHttp(
        rewriteUrl: route.rewrite,
        client: MockClient((request) async {
          sent = request;
          return http.Response('ok', 200);
        }),
      );
      addTearDown(transport.dispose);
      await transport.send(
        url: 'https://old.example/wp-login.php',
        method: 'POST',
        body: 'fixture=1',
        headers: {
          'origin': 'https://old.example',
          'referer': 'https://old.example/account',
          'host': 'old.example',
          'cookie': 'login=stale',
          'authorization': 'Bearer old',
        },
      );
      expect(sent.url.toString(), '$destination/wp-login.php');
      expect(sent.headers['origin'], destination);
      expect(sent.headers['referer'], '$destination/account');
      expect(sent.headers['host'], isNot('old.example'));
      expect(sent.headers['cookie'], 'login=destination');
      expect(sent.headers['authorization'], isNull);
      expect(sent.headers['user-agent'], 'destination-UA');
      expect(sent.body, 'fixture=1');
    });
  }

  test('同站只换目录保留显式登录凭据和编码后的路径查询', () async {
    final route = SourceRoute(
      urls: const ['https://site.example/old'],
      custom: 'https://site.example/new',
    );
    late http.Request sent;
    final transport = LumeHttp(
      rewriteUrl: route.rewrite,
      client: MockClient((request) async {
        sent = request;
        return http.Response('', 200);
      }),
    );
    addTearDown(transport.dispose);
    await transport.send(
      url: 'https://site.example/old/a%20b?token=a%2Fb',
      headers: {
        'Cookie': 'login=current',
        'Authorization': 'Bearer current',
        'Origin': 'https://site.example',
        'Referer': 'https://site.example/old/book',
      },
    );
    expect(sent.url.toString(), 'https://site.example/new/a%20b?token=a%2Fb');
    expect(sent.headers['cookie'], 'login=current');
    expect(sent.headers['authorization'], 'Bearer current');
    expect(sent.headers['origin'], 'https://site.example');
    expect(sent.headers['referer'], 'https://site.example/new/book');
  });

  test('换域不改第三方 Origin/Referer，也不发送第三方会话', () async {
    SiteSessionPool.shared.importCookies([
      {
        'name': 'unrelated',
        'value': 'secret',
        'domain': 'other.example',
        'path': '/',
      },
    ]);
    final route = SourceRoute(
      urls: const ['https://old.example'],
      custom: 'https://new.example',
    );
    late http.Request sent;
    final transport = LumeHttp(
      rewriteUrl: route.rewrite,
      client: MockClient((request) async {
        sent = request;
        return http.Response('', 200);
      }),
    );
    addTearDown(transport.dispose);
    await transport.send(
      url: 'https://old.example/api',
      headers: {
        'Origin': 'https://other.example',
        'Referer': 'https://other.example/page',
      },
    );
    expect(sent.headers['origin'], 'https://other.example');
    expect(sent.headers['referer'], 'https://other.example/page');
    expect(sent.headers['cookie'], isNull);
  });
}
