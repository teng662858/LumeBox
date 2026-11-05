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
      Map<String, dynamic>? submittedTree;
      final catalog = jsonEncode({
        'sources': [
          {
            'id': 'one',
            'name': '远端测试源',
            'version': '1',
            'path': 'movie/测试.js',
            'aliases': [],
          },
          {
            'id': 'two',
            'name': '第二个源',
            'version': '1',
            'path': 'movie/第二.js',
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
                  if (request.url.path.endsWith('/git/trees')) {
                    submittedTree = jsonDecode(request.body);
                  }
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
                      {
                        'path': 'movie/第二.js',
                        'sha': 'source2',
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
      await tester.scrollUntilVisible(
        find.text('远端测试源'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('远端测试源'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('PY'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('PY'));
      await tester.pumpAndSettle();
      expect(find.text('远端测试源'), findsNothing);
      await tester.tap(find.text('JS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已安装'));
      await tester.pumpAndSettle();
      expect(find.text('远端测试源'), findsNothing);
      await tester.tap(find.text('未安装'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('远端测试源'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('远端测试源'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('标记删除').first);
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.scrollUntilVisible(
        find.text('第二个源'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('标记删除').first);
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.scrollUntilVisible(
        find.text('一次提交并发布全部变更'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        find.text('待提交：新增 0，删除 2'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('待提交：新增 0，删除 2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('一次提交并发布全部变更'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('一次提交并发布全部变更'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('影响所有订阅用户'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('一次提交并发布全部变更'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('确认提交'));
      await pumpIoAndSettle(tester);
      expect(writes, 3);
      expect((submittedTree!['tree'] as List).map((e) => e['path']).toSet(), {
        'movie/测试.js',
        'movie/第二.js',
      });
      expect(
        RepositoryOperation.parse(store.value['operation'])?.commit,
        'candidate',
      );
      expect(find.textContaining('等待 GitHub'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
