import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/private_github_subscription.dart';
import 'package:lume_box/core/net/source_subscription.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const credentials = PrivateGithubSubscription(
    owner: 'owner',
    repository: 'repo',
    ref: 'main',
    token: 'read-only-token',
  );
  const base = 'https://raw.githubusercontent.com/owner/repo/main/';
  const channel = MethodChannel('lumebox/source_repository');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    PrivateGithubSubscription.resetForTesting();
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'privateRead'
          ? jsonEncode({
              'owner': 'owner',
              'repository': 'repo',
              'ref': 'main',
              'token': 'read-only-token',
            })
          : null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    PrivateGithubSubscription.resetForTesting();
  });

  test('私有仓库连接短暂中断时重试，404 不重试', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (attempts == 1) throw http.ClientException('connection closed');
      return http.Response('ok', 200);
    });
    expect(
      utf8.decode(
        await credentials.download(
          credentials.apiFor('${base}file.js')!,
          client: client,
        ),
      ),
      'ok',
    );
    expect(attempts, 2);
    attempts = 0;
    final missing = MockClient((request) async {
      attempts++;
      return http.Response('missing', 404);
    });
    await expectLater(
      credentials.download(
        credentials.apiFor('${base}file.js')!,
        client: missing,
      ),
      throwsA(isA<StateError>()),
    );
    expect(attempts, 1);
  });

  test(
    'raw, CDN and blob links map only the configured repository and ref',
    () {
      for (final url in [
        '${base}subscriptions/all.json',
        'https://cdn.jsdelivr.net/gh/owner/repo@main/subscriptions/all.json',
        'https://github.com/owner/repo/blob/main/subscriptions/all.json',
      ]) {
        final uri = credentials.apiFor(url)!;
        expect(uri.host, 'api.github.com');
        expect(uri.path, '/repos/owner/repo/contents/subscriptions/all.json');
        expect(uri.queryParameters['ref'], 'main');
      }
      for (final url in [
        'https://evil.test/owner/repo/main/a.js',
        'https://raw.githubusercontent.com/other/repo/main/a.js',
        'https://raw.githubusercontent.com/owner/repo/other/a.js',
        '${base}a.js?token=bad',
        'https://owner:password@raw.githubusercontent.com/owner/repo/main/a.js',
      ]) {
        expect(credentials.apiFor(url), isNull);
      }
    },
  );

  test(
    'manifest and nested source download use authenticated GitHub only',
    () async {
      final seen = <String>[];
      final responses = {
        '/repos/owner/repo/contents/subscriptions/all.json': jsonEncode({
          'format': 'lume.total-subscription',
          'version': 1,
          'sections': {
            'video': ['${base}subscriptions/video.txt'],
          },
        }),
        '/repos/owner/repo/contents/subscriptions/video.txt':
            '${base}video/test.js',
        '/repos/owner/repo/contents/video/test.js': '// LumeSource: {"id":"test_video","name":"test","version":"1","category":"video","contentCategory":"movie"}\nvar LumeSource = {};',
      };
      PrivateGithubSubscription.clientFactory = () => MockClient((
        request,
      ) async {
        expect(request.url.host, 'api.github.com');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer read-only-token');
        expect(request.headers['Accept'], 'application/vnd.github.raw+json');
        seen.add(request.url.path);
        final body = responses[request.url.path];
        return http.Response(body ?? '', body == null ? 404 : 200);
      });
      final public = LumeHttp(
        client: MockClient(
          (_) async => throw StateError('must not call public network'),
        ),
      );
      addTearDown(public.dispose);
      final resolver = SourceSubscription(
        section: 'video',
        strictManifest: true,
        fetch: (url) => SourceSubscription.fetchSubscription(public, url),
      );
      final refs = await resolver.resolveRefs([
        '${base}subscriptions/all.json',
      ]);
      expect(refs.single.url, '${base}video/test.js');
      expect(seen.toSet(), responses.keys.toSet());
    },
  );

  test(
    'redirects and failures do not forward credentials or fall back',
    () async {
      var requests = 0;
      PrivateGithubSubscription.clientFactory = () =>
          MockClient((request) async {
            requests++;
            expect(request.followRedirects, isFalse);
            return http.Response(
              '',
              302,
              headers: {'location': 'https://evil.test/steal'},
            );
          });
      final public = LumeHttp(
        client: MockClient((_) async => throw StateError('must not fall back')),
      );
      addTearDown(public.dispose);
      await expectLater(
        SourceSubscription.fetchSubscription(public, '${base}a.js'),
        throwsStateError,
      );
      await expectLater(
        SourceSubscription.fetchSubscription(
          public,
          'https://raw.githubusercontent.com/owner/repo/other/a.js',
        ),
        throwsFormatException,
      );
      expect(requests, 1);
    },
  );
  test(
    'unrelated public subscriptions never receive the private token',
    () async {
      PrivateGithubSubscription.clientFactory = () => MockClient((_) async {
        fail('private GitHub client must not be called');
      });
      final public = LumeHttp(
        client: MockClient((request) async {
          expect(request.url.host, 'example.org');
          expect(
            request.headers.keys.map((e) => e.toLowerCase()),
            isNot(contains('authorization')),
          );
          return http.Response('public content', 200);
        }),
      );
      addTearDown(public.dispose);
      expect(
        (await SourceSubscription.fetchSubscription(
          public,
          'https://example.org/a.txt',
        )).text,
        'public content',
      );
    },
  );
  test('official Cloudflare links use the private GitHub API', () {
    const official = PrivateGithubSubscription(
      owner: 'teng662858',
      repository: 'LumeBox-Sources',
      ref: 'main',
      token: 'secret',
    );
    expect(
      official
          .apiFor('https://lume-sources.pages.dev/subscriptions/all.json')
          ?.path,
      '/repos/teng662858/LumeBox-Sources/contents/subscriptions/all.json',
    );
    expect(
      credentials.apiFor(
        'https://lume-sources.pages.dev/subscriptions/all.json',
      ),
      isNull,
    );
  });
}
