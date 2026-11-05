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
  ) async => operation.manual && !operation.dispatched
      ? const RepositoryPublication('已提交，等待手动发布')
      : const RepositoryPublication(
          '已发布',
          finished: true,
          succeeded: true,
          started: true,
        );
}

class _PublishedRepository extends _Repository {
  _PublishedRepository(this.stillExists);
  final bool stillExists;
  @override
  Future<RepositoryPublication> publication(
    RepositoryOperation operation,
  ) async => const RepositoryPublication(
    '已发布：订阅内容核对通过',
    finished: true,
    succeeded: true,
    started: true,
  );
  @override
  Future<RepositorySnapshot> snapshot() async => RepositorySnapshot(
    'head',
    'tree',
    stillExists ? {'movie/example.js': 'blob'} : {},
    const [],
  );
}

void main() {
  for (final exists in [false, true]) {
    testWidgets(exists ? '工作流成功但目标仍存在时不能报成功' : '外部发布成功后恢复记录并核对删除', (
      tester,
    ) async {
      final credentials = _Credentials({
        'token': 'test',
        'operation': const RepositoryOperation(
          'draft',
          'commit',
          manual: true,
          removedPaths: ['movie/example.js'],
          removedNames: ['影视示例'],
        ).toJson(),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SourceRepositoryPage(
            store: credentials,
            clientFactory: (_) => _PublishedRepository(exists),
            managers: {
              Section.comic: FakeSourceManager(),
              Section.video: FakeSourceManager(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(exists ? '待删除文件仍在仓库' : '发布成功：新增 0 个，删除 1 个'),
        findsOneWidget,
      );
      expect(find.text('发布待发布的变更'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

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
