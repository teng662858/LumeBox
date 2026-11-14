import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../tool/fetch_sources.dart';

void main() {
  late Directory root;
  const treeId = '0123456789012345678901234567890123456789';
  final content = utf8.encode('// 字幕、视频源\r\n');
  final hash = sha1.convert([
    ...utf8.encode('blob ${content.length}\u0000'),
    ...content,
  ]).toString();
  Map<String, Object> entry(String path, {String mode = '100644'}) => {
    'type': 'blob',
    'mode': mode,
    'path': path,
    'sha': hash,
    'size': content.length,
  };
  http.Response json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-fixture-fetch-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'authorized immutable blobs preserve Chinese names and exact bytes',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(request.headers['Authorization'], 'Bearer fixture-token');
        expect(request.followRedirects, false);
        paths.add(request.url.path);
        if (request.url.path.endsWith('/trees/main')) {
          expect(request.url.queryParameters['recursive'], '1');
          return json({
            'sha': treeId,
            'truncated': false,
            'tree': [
              entry('video/中文源.js'),
              entry('novel/book.js'),
              entry('snapshots/site/index.html'),
              entry('tools/private.js'),
              entry('video/link.js', mode: '120000'),
              entry('snapshots/../../escape'),
              entry('snapshots/..\\escape'),
            ],
          });
        }
        expect(request.url.path, endsWith('/git/blobs/$hash'));
        return json({
          'encoding': 'base64',
          'content': '${base64.encode(content)}\n',
        });
      });
      addTearDown(client.close);
      final result = await SourceFixtureFetcher(
        client,
        'fixture-token',
      ).fetch(root);
      expect(result, (tree: treeId, ok: 3, failed: 0));
      expect(paths, hasLength(4));
      for (final path in [
        'video/中文源.js',
        'novel/book.js',
        'snapshots/site/index.html',
      ]) {
        expect(await File('${root.path}/$path').readAsBytes(), content);
      }
      expect(
        await root.list(recursive: true).where((e) => e is File).length,
        3,
      );
    },
  );

  test('corrupted blob cannot overwrite an existing fixture', () async {
    final existing = File('${root.path}/video/source.js');
    await existing.parent.create(recursive: true);
    await existing.writeAsString('previous');
    final client = MockClient(
      (request) async => request.url.path.endsWith('/trees/main')
          ? json({
              'sha': treeId,
              'tree': [entry('video/source.js')],
            })
          : json({
              'encoding': 'base64',
              'content': base64.encode([1, 2, 3]),
            }),
    );
    addTearDown(client.close);
    final result = await SourceFixtureFetcher(
      client,
      'fixture-token',
    ).fetch(root);
    expect(result.failed, 1);
    expect(await existing.readAsString(), 'previous');
    expect(await File('${existing.path}.fetch-tmp').exists(), false);
  });

  test('truncated tree fails before downloading partial coverage', () async {
    final client = MockClient(
      (_) async => json({'sha': treeId, 'truncated': true}),
    );
    addTearDown(client.close);
    await expectLater(
      SourceFixtureFetcher(client, 'fixture-token').fetch(root),
      throwsFormatException,
    );
    expect(await root.list().isEmpty, true);
  });

  for (final status in [302, 403]) {
    test(
      'HTTP $status fails without following an external credential redirect',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          expect(request.followRedirects, false);
          return http.Response(
            '',
            status,
            headers: {'location': 'https://foreign.test/file'},
          );
        });
        addTearDown(client.close);
        await expectLater(
          SourceFixtureFetcher(client, 'fixture-token').fetch(root),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              isNot(contains('fixture-token')),
            ),
          ),
        );
        expect(requests, 1);
      },
    );
  }
}
