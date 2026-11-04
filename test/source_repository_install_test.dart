import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/github_source_repository.dart';
import 'package:lume_box/features/source/source_repository_page.dart';

import 'support/fake_source_manager.dart';

class _Credentials extends RepositoryCredentialStore {
  _Credentials(this.data);
  Map<String, dynamic> data;
  @override
  Future<Map<String, dynamic>> load() async => data;
  @override
  Future<void> save(Map<String, dynamic> value) async {
    data = value;
  }
}

class _Repository extends GithubSourceRepository {
  _Repository() : super('test');
  static const source = RepositorySource('example', '影视示例', '1', [
    'movie/example.js',
  ]);
  @override
  Future<RepositorySnapshot> snapshot() async => const RepositorySnapshot(
    'head',
    'tree',
    {'movie/example.js': 'blob'},
    [source],
  );
  @override
  Future<String> readSource(
    RepositorySnapshot snapshot,
    RepositorySource source,
  ) async =>
      '// LumeSource: {"id":"example","name":"影视示例","version":"1","category":"video","contentCategory":"movie"}\nvar LumeSource={};';
  @override
  Future<RepositoryPublication> publication(
    RepositoryOperation operation,
  ) async =>
      const RepositoryPublication('已发布', finished: true, succeeded: true);
}

void main() {
  for (final automatic in [false, true]) {
    testWidgets(
      automatic
          ? 'Successful publication installs on phone and remembers completion'
          : 'Repository download installs on phone and refreshes its installed state',
      (tester) async {
        final credentials = _Credentials({
          'token': 'test',
          if (automatic)
            'operation': const RepositoryOperation(
              'branch',
              'commit',
              installPaths: ['movie/example.js'],
            ).toJson(),
        });
        final video = FakeSourceManager()
          ..importDescriptor = const SourceDescriptor(
            id: 'example',
            name: '影视示例',
            version: '1',
            enabled: true,
            contentCategory: 'movie',
          );
        final comic = FakeSourceManager();
        await tester.pumpWidget(
          MaterialApp(
            home: SourceRepositoryPage(
              store: credentials,
              clientFactory: (_) => _Repository(),
              managers: {Section.comic: comic, Section.video: video},
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!automatic) {
          await tester.scrollUntilVisible(
            find.textContaining('尚未安装到本机'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining('尚未安装到本机'), findsOneWidget);
          await tester.drag(find.byType(ListView).first, const Offset(0, -120));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('安装到本机'));
          await tester.pumpAndSettle();
        }
        expect(video.imported, hasLength(1));
        expect(comic.imported, isEmpty);
        await tester.scrollUntilVisible(
          find.textContaining('已在本机 · 视频'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('已在本机 · 视频'), findsOneWidget);
        if (automatic) {
          expect(
            RepositoryOperation.parse(credentials.data['operation'])!
                .installPaths,
            isEmpty,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
