import 'dart:convert';

import 'support/pump_io.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/github_source_repository.dart';
import 'package:lume_box/features/source/source_repository_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryCredentialStore extends RepositoryCredentialStore {
  Map<String, dynamic> value = {};
  @override
  Future<Map<String, dynamic>> load() async => value;
  @override
  Future<void> save(Map<String, dynamic> next) async {
    value = next;
  }

  @override
  Future<void> clear() async {
    value = {};
  }
}

void main() {
  testWidgets(
    'connect, display remote sources and cancel deletion without sending a mutation',
    (tester) async {
      final store = MemoryCredentialStore();
      var writes = 0;
      final catalog = jsonEncode({
        'sources': [
          {
            'id': 'one',
            'name': '远端测试源',
            'version': '1',
            'path': 'movie/测试.js',
            'aliases': [],
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SourceRepositoryPage(
            store: store,
            clientFactory: (token) => GithubSourceRepository(
              token,
              client: MockClient((request) async {
                if (request.method != 'GET') {
                  writes++;
                  return http.Response(
                    jsonEncode(
                      request.url.path.endsWith('/git/trees')
                          ? {'sha': 'newTree'}
                          : request.url.path.endsWith('/git/commits')
                          ? {'sha': 'candidate'}
                          : {'ref': 'candidate'},
                    ),
                    201,
                  );
                }
                Object data;
                if (request.url.path.endsWith('/LumeBox-Sources')) {
                  data = {
                    'permissions': {'push': true},
                  };
                } else if (request.url.path.contains('/actions/')) {
                  data = {'workflow_runs': []};
                } else if (request.url.path.endsWith('/main')) {
                  data = {
                    'object': {'sha': 'head'},
                  };
                } else if (request.url.path.endsWith('/commits/head')) {
                  data = {
                    'tree': {'sha': 'tree'},
                  };
                } else if (request.url.path.endsWith('/trees/tree')) {
                  data = {
                    'tree': [
                      {
                        'path': 'metadata/catalog.json',
                        'sha': 'catalog',
                        'type': 'blob',
                        'mode': '100644',
                      },
                      {
                        'path': 'movie/测试.js',
                        'sha': 'source',
                        'type': 'blob',
                        'mode': '100644',
                      },
                    ],
                  };
                } else if (request.url.path.endsWith('/blobs/catalog')) {
                  data = {'content': base64Encode(utf8.encode(catalog))};
                } else {
                  data = {};
                }
                return http.Response(
                  jsonEncode(data),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'test-token');
      await tester.tap(find.text('授权并读取仓库'));
      await pumpIoAndSettle(tester);
      expect(store.value['token'], 'test-token');
      expect(find.text('远端测试源'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('从 GitHub 删除源'));
      await tester.tap(find.byTooltip('从 GitHub 删除源'));
      // Confirmation holds the operation lock, so its progress bar keeps animating.
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('影响所有订阅用户'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.byTooltip('从 GitHub 删除源'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('确认提交'));
      await pumpIoAndSettle(tester);
      expect(writes, 3);
      expect(
        RepositoryOperation.parse(store.value['operation'])?.commit,
        'candidate',
      );
      expect(find.textContaining('等待 GitHub'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
