import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/source/github_source_repository.dart';

Uint8List script({
  String id = 'test_source',
  String category = 'video',
  String content = 'movie',
}) => Uint8List.fromList(
  utf8.encode(
    '// LumeSource: ${jsonEncode({'id': id, 'name': '测试源', 'version': '1.0.0', 'category': category, 'contentCategory': content})}\nconst LumeSource = {};',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = RepositorySource('old', '旧源', '1', [
    'movie/旧源.js',
    'video/旧源.js',
  ]);
  const snapshot = RepositorySnapshot(
    'base',
    'baseTree',
    {'movie/旧源.js': 'blob1', 'video/旧源.js': 'blob2'},
    [source],
  );

  test('upload validates category, UTF-8, paths, metadata and limits before any write', () {
    expect(
      GithubSourceRepository.validateUpload('movie/测试.js', script()).id,
      'test_source',
    );
    for (final path in [
      '../x.py',
      'movie/a/b.js',
      'tools/a.js',
      'video/.hidden.py',
      'video/a\\b.js',
    ]) {
      expect(
        () => GithubSourceRepository.validateUpload(path, script()),
        throwsA(isA<RepositoryFailure>()),
      );
    }
    expect(
      () => GithubSourceRepository.validateUpload('comic/测试.js', script()),
      throwsA(isA<RepositoryFailure>()),
    );
    expect(
      () => GithubSourceRepository.validateUpload(
        'video/测试.py',
        Uint8List.fromList([255]),
      ),
      throwsA(isA<RepositoryFailure>()),
    );
    expect(
      () => GithubSourceRepository.validateUpload(
        'video/测试.py',
        Uint8List(4 * 1024 * 1024 + 1),
      ),
      throwsA(isA<RepositoryFailure>()),
    );
    expect(
      () => GithubSourceRepository.validateUpload(
        'movie/测试.js',
        script(content: 'adult'),
      ),
      throwsA(isA<RepositoryFailure>()),
    );
  });

  test(
    'create commits on candidate branch without forcing or modifying main',
    () async {
      final requests = <http.Request>[];
      final repo = GithubSourceRepository(
        'test-token',
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.host, 'api.github.com');
          expect(request.followRedirects, false);
          expect(request.headers['Authorization'], 'Bearer test-token');
          if (request.url.path.endsWith('/git/blobs')) {
            return http.Response('{"sha":"uploaded"}', 201);
          }
          if (request.url.path.endsWith('/git/trees')) {
            final body = jsonDecode(request.body) as Map;
            expect(body['base_tree'], 'baseTree');
            expect((body['tree'] as List).single['path'], 'movie/新源.js');
            return http.Response('{"sha":"newTree"}', 201);
          }
          if (request.url.path.endsWith('/git/commits')) {
            expect(jsonDecode(request.body)['parents'], ['base']);
            return http.Response('{"sha":"candidate"}', 201);
          }
          expect(
            jsonDecode(request.body)['ref'],
            startsWith('refs/heads/lumebox/manage-'),
          );
          return http.Response('{"ref":"candidate"}', 201);
        }),
      );
      addTearDown(repo.close);
      final operation = await repo.add(snapshot, 'movie/新源.js', script());
      expect(operation.commit, 'candidate');
      expect(requests.map((r) => r.method), everyElement('POST'));
      final before = requests.length;
      await expectLater(
        repo.add(snapshot, 'movie/旧源.js', script()),
        throwsA(isA<RepositoryFailure>()),
      );
      await expectLater(
        repo.add(snapshot, 'movie/不同名.js', script(id: 'old')),
        throwsA(isA<RepositoryFailure>()),
      );
      expect(requests.length, before);
    },
  );

  test(
    'delete all aliases in one Git tree, protected conflict has readable error',
    () async {
      var calls = 0;
      final repo = GithubSourceRepository(
        'token',
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/git/trees')) {
            final entries = jsonDecode(request.body)['tree'] as List;
            expect(entries.map((e) => e['path']), source.paths);
            expect(
              entries.every((e) => e.containsKey('sha') && e['sha'] == null),
              true,
            );
            return http.Response('{"sha":"tree"}', 201);
          }
          if (request.url.path.endsWith('/git/commits')) {
            return http.Response('{"sha":"candidate"}', 201);
          }
          return http.Response('{"message":"secret token server echo"}', 422);
        }),
      );
      addTearDown(repo.close);
      await expectLater(
        repo.remove(snapshot, source),
        throwsA(
          isA<RepositoryFailure>().having(
            (e) => e.message,
            'sanitized',
            allOf(contains('刷新'), isNot(contains('secret'))),
          ),
        ),
      );
      expect(calls, 3);
    },
  );

  test('snapshot pinned to one commit and rejects truncated trees', () async {
    final repo = GithubSourceRepository(
      'token',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/main')) {
          return http.Response('{"object":{"sha":"pinned"}}', 200);
        }
        if (path.endsWith('/pinned')) {
          return http.Response('{"tree":{"sha":"tree"}}', 200);
        }
        return http.Response('{"truncated":true,"tree":[]}', 200);
      }),
    );
    addTearDown(repo.close);
    await expectLater(
      repo.snapshot(),
      throwsA(
        isA<RepositoryFailure>().having(
          (e) => e.message,
          'truncated',
          contains('不完整'),
        ),
      ),
    );
  });

  test(
    'publication does not report success for queued or failed Actions runs',
    () async {
      var result = <String, Object>{'workflow_runs': []};
      final repo = GithubSourceRepository(
        'token',
        client: MockClient(
          (request) async => http.Response(jsonEncode(result), 200),
        ),
      );
      addTearDown(repo.close);
      const operation = RepositoryOperation('lumebox/manage-test', 'candidate');
      expect((await repo.publication(operation)).finished, false);
      result = {
        'workflow_runs': [
          {'status': 'in_progress', 'html_url': 'https://github.com/run'},
        ],
      };
      expect((await repo.publication(operation)).finished, false);
      result = {
        'workflow_runs': [
          {'status': 'completed', 'conclusion': 'failure'},
        ],
      };
      expect((await repo.publication(operation)).status, contains('未完成'));
      result = {
        'workflow_runs': [
          {'status': 'completed', 'conclusion': 'success'},
        ],
      };
      expect((await repo.publication(operation)).status, contains('内容核对通过'));
    },
  );

  test('credentials and pending operation use native Keychain channel and clear explicitly', () async {
    var stored = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RepositoryCredentialStore.channel, (
          call,
        ) async {
          if (call.method == 'read') return stored;
          stored = call.arguments as String;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RepositoryCredentialStore.channel, null),
    );
    final store = RepositoryCredentialStore();
    await store.save({
      'token': 'private',
      'operation': const RepositoryOperation('branch', 'commit').toJson(),
    });
    expect(
      RepositoryOperation.parse((await store.load())['operation'])?.commit,
      'commit',
    );
    await store.clear();
    expect(await store.load(), isEmpty);
  });
}
