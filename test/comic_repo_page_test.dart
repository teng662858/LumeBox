import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/comic/comic_repo_page.dart';
import 'package:lume_box/features/comic/repo/comic_repo_fetcher.dart';
import 'package:lume_box/features/comic/repo/comic_repo_models.dart';
import 'package:lume_box/features/comic/repo/comic_repo_service.dart';
import 'package:lume_box/features/comic/repo/comic_repo_store.dart';

import 'support/fake_source_manager.dart';

/// 仓库页与扩展页的验证：添加 / 刷新 / 删除仓库，浏览扩展，安装 / 启停 / 卸载，
/// 以及 APK 载体的如实拒绝。页面由真实服务 + 替身抓取器 + 替身图源端口驱动，
/// 存储在临时目录里的真实 sqlite 上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ComicRepoStore store;
  late _FakeFetcher fetcher;
  late FakeSourceManager manager;
  late ComicRepoService service;

  const indexUrl = 'https://repo.example/index.json';

  const veneraIndex = '''
[
  {"name": "拷贝漫画", "fileName": "copy_manga.js", "key": "copy_manga", "version": "1.4.2"}
]
''';

  const mihonIndex = '''
[
  {"name": "MangaDex", "pkg": "eu.mangadex", "apk": "mangadex-v1.5.0.apk", "lang": "all", "version": "1.5.0", "nsfw": 0, "sources": [{"name": "MangaDex", "lang": "en", "id": "1", "baseUrl": "https://mangadex.org"}]}
]
''';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_repo_page');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    store = await ComicRepoStore.open();
    fetcher = _FakeFetcher()
      ..responses[indexUrl] = veneraIndex
      ..responses['https://repo.example/copy_manga.js'] =
          'var LumeSource = {id: "lume.copy"};'
      ..responses['https://repo.example/mihon/index.min.json'] = mihonIndex;
    manager = FakeSourceManager();
    service = ComicRepoService(
      store: store,
      sources: manager,
      fetcher: fetcher,
    );
  });

  tearDown(() async {
    ComicRepoStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ComicRepoPage(service: service),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addRepo(
    WidgetTester tester,
    String url, {
    RepoKind kind = RepoKind.venera,
  }) async {
    await tester.tap(find.byTooltip('添加仓库'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(kind.label),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, url);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
  }

  /// SnackBar 串行展示：清掉前一条，后一条才不会被排队挡住。
  void clearToasts(WidgetTester tester) {
    ScaffoldMessenger.of(
      tester.element(find.byType(ComicRepoPage)),
    ).clearSnackBars();
  }

  testWidgets('空态：提示添加仓库入口', (tester) async {
    await pumpPage(tester);

    expect(find.text('暂无仓库'), findsOneWidget);
    expect(find.byTooltip('添加仓库'), findsOneWidget);
  });

  testWidgets('添加仓库：解析计数并刷新列表', (tester) async {
    await pumpPage(tester);
    await addRepo(tester, 'https://repo.example');

    expect(find.text('已添加：repo.example · 1 个扩展'), findsOneWidget);
    expect(find.text('repo.example'), findsOneWidget);
    expect(find.text(RepoKind.venera.label), findsOneWidget);
    expect(find.textContaining('扩展 1 个'), findsOneWidget);
    expect(fetcher.requested.last.toString(), indexUrl);
  });

  testWidgets('刷新与删除：计数更新；删除后回到空态', (tester) async {
    await pumpPage(tester);
    await addRepo(tester, indexUrl);
    expect(find.textContaining('扩展 1 个'), findsOneWidget);
    clearToasts(tester);
    await tester.pumpAndSettle();

    fetcher.responses[indexUrl] = '''
[
  {"name": "A", "fileName": "a.js", "key": "a", "version": "1.0.0"},
  {"name": "B", "fileName": "b.js", "key": "b", "version": "1.0.0"}
]
''';
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('已刷新：repo.example · 2 个扩展'), findsOneWidget);
    expect(find.textContaining('扩展 2 个'), findsOneWidget);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除仓库'), findsOneWidget);
    expect(find.textContaining('已安装的扩展不会被卸载'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('暂无仓库'), findsOneWidget);
    expect(await service.repos(), isEmpty);
  });

  testWidgets('扩展页：JS 扩展安装 → 启停 → 卸载', (tester) async {
    await pumpPage(tester);
    await addRepo(tester, indexUrl);
    clearToasts(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('repo.example'));
    await tester.pumpAndSettle();

    // 未安装：显示版本与安装按钮。
    expect(find.text('v1.4.2'), findsOneWidget);
    expect(find.text('JS'), findsOneWidget);
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();

    expect(find.text('已安装：新图源'), findsOneWidget);
    expect(manager.imported.single, contains('LumeSource'));
    expect(find.textContaining('已安装 v1.4.2'), findsOneWidget);

    // 启停：等价于图源启停。
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(manager.toggled.single, ('lume.new', false));

    // 卸载：二次确认后摘除图源。
    await tester.tap(find.byTooltip('卸载'));
    await tester.pumpAndSettle();
    expect(find.text('卸载扩展'), findsOneWidget);
    await tester.tap(find.text('卸载'));
    await tester.pumpAndSettle();
    expect(manager.removed.single, 'lume.new');
    expect(find.text('安装'), findsOneWidget);
  });

  testWidgets('扩展页：APK 载体如实标记不可运行，安装入口禁用', (tester) async {
    await pumpPage(tester);
    await addRepo(tester, 'https://repo.example/mihon', kind: RepoKind.mihon);
    clearToasts(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('repo.example'));
    await tester.pumpAndSettle();

    expect(find.text('APK'), findsOneWidget);
    expect(
      find.text('APK 载体需要 Android 运行时，本平台不能运行——只能浏览'),
      findsOneWidget,
    );
    expect(find.text('不可运行'), findsOneWidget);
    expect(find.text('安装'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets(
    '非 iOS：漫画板块只有骨架，扩展仓库入口不可达',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: LumeTheme.build(), home: const ComicPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      expect(find.byTooltip('扩展仓库'), findsNothing);
    },
    skip: Platform.isIOS,
  );
}

/// 替身抓取器：按地址返回预置文本，记录请求。
class _FakeFetcher implements RepoFetcher {
  final Map<String, String> responses = <String, String>{};
  final List<Uri> requested = <Uri>[];

  @override
  Future<String> fetchText(Uri url) async {
    requested.add(url);
    final body = responses[url.toString()];
    if (body == null) {
      throw SourceException(SourceErrorKind.network, 'HTTP 404：$url');
    }
    return body;
  }

  @override
  void dispose() {}
}
