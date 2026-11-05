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
  testWidgets('放弃未发布记录保留本次待删除选择', (tester) async {
    final credentials = _Credentials({
      'token': 'test',
      'operation': const RepositoryOperation(
        'draft',
        'old',
        manual: true,
      ).toJson(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SourceRepositoryPage(
          store: credentials,
          clientFactory: (_) => _Repository(),
          managers: {
            Section.comic: FakeSourceManager(),
            Section.video: FakeSourceManager(),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('批量管理'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选／取消全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记待删除'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('手动提交全部变更'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('手动提交全部变更'));
    await tester.pumpAndSettle();
    expect(find.text('上一批变更尚未完成'), findsOneWidget);
    await tester.tap(find.text('放弃上一批记录'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('当前选择的变更会保留'), findsOneWidget);
    await tester.tap(find.text('放弃记录'));
    await tester.pumpAndSettle();
    expect(credentials.data.containsKey('operation'), false);
    await tester.scrollUntilVisible(
      find.text('手动提交全部变更'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '手动提交全部变更'))
          .onPressed,
      isNotNull,
    );
    expect(find.text('待提交：新增 0，删除 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
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
            find.textContaining('未安装'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining('未安装'), findsOneWidget);
          await tester.drag(find.byType(ListView).first, const Offset(0, -120));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('源操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('安装到本机'));
          await tester.pumpAndSettle();
        }
        expect(video.imported, hasLength(1));
        expect(comic.imported, isEmpty);
        await tester.scrollUntilVisible(
          find.textContaining('已安装'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('已安装'), findsOneWidget);
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
