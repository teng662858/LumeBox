import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/repo/comic_repo_fetcher.dart';
import 'package:lume_box/features/comic/repo/comic_repo_models.dart';
import 'package:lume_box/features/comic/repo/comic_repo_service.dart';
import 'package:lume_box/features/comic/repo/comic_repo_store.dart';

import 'support/fake_source_manager.dart';

/// 漫画扩展仓库服务的验证：添加 / 刷新 / 安装 / 启停 / 卸载全流程，
/// 失败路径的可读提示，以及板块守卫（非漫画板块构造即拒绝）。
///
/// 抓取与图源端口都注入替身，存储用真实 sqlite（临时目录），
/// 因此整套流程在 Windows 上就能跑完。
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
  {"name": "拷贝漫画", "fileName": "copy_manga.js", "key": "copy_manga", "version": "1.4.2"},
  {"name": "其他来源", "fileName": "other.js", "key": "other", "version": "2.0.0"}
]
''';

  const mihonIndex = '''
[
  {"name": "MangaDex", "pkg": "eu.mangadex", "apk": "mangadex-v1.5.0.apk", "lang": "all", "version": "1.5.0", "nsfw": 0, "sources": [{"name": "MangaDex", "lang": "en", "id": "1", "baseUrl": "https://mangadex.org"}]}
]
''';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_repo_service');
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
          'var LumeSource = {id: "lume.copy"};';
    manager = FakeSourceManager(
      sources: const <SourceDescriptor>[/* 初始为空 */],
    );
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

  /// 按 id 取扩展：列表按名称排序（中文按码点），不能靠顺序假设。
  Future<RepoExtension> extensionOf(String repoId, String extensionId) async {
    final extensions = await service.extensions(repoId);
    return extensions.firstWhere((item) => item.id == extensionId);
  }

  test('添加仓库：补全索引地址、独立解析、落库并返回计数', () async {
    final repo = await service.addRepo(
      url: 'https://repo.example',
      kind: RepoKind.venera,
    );

    expect(fetcher.requested.single.toString(), indexUrl);
    expect(repo.extensionCount, 2);
    expect(repo.name, 'repo.example', reason: '没填名字时用主机名');
    expect((await service.repos()).single.id, indexUrl);
    expect(
      (await service.extensions(indexUrl)).map((item) => item.id).toSet(),
      <String>{'copy_manga.js', 'other.js'},
    );
  });

  test('添加 Mihon 仓库：根地址先探 index.pb，缺 .pb 退回 index.min.json（APK 载体）', () async {
    fetcher.responses['https://repo.example/mihon/index.min.json'] = mihonIndex;

    final repo = await service.addRepo(
      url: 'https://repo.example/mihon',
      kind: RepoKind.mihon,
      name: ' Mihon 官方 ',
    );

    expect(
      fetcher.requested.map((uri) => uri.path).toList(),
      <String>['/mihon/index.pb', '/mihon/index.min.json'],
      reason: '先试新格式 index.pb，404 后回退旧格式',
    );
    expect(repo.url.path, '/mihon/index.min.json');
    expect(repo.name, 'Mihon 官方', reason: '首尾空白被去掉');
    final extension = (await service.extensions(repo.id)).single;
    expect(extension.artifact, ExtensionArtifact.apk);
    expect(extension.isRunnable, isFalse);
  });

  test('添加 Mihon 仓库：直接给 index.pb 地址时按 protobuf 解析', () async {
    const pbUrl = 'https://repo.example/mihon/index.pb';
    fetcher.binaries[pbUrl] = _samplePbIndex();

    final repo = await service.addRepo(url: pbUrl, kind: RepoKind.mihon);

    expect(fetcher.requested.single.toString(), pbUrl, reason: '不再往 .pb 后面拼 index.min.json');
    expect(repo.url.toString(), pbUrl);
    expect(repo.extensionCount, 2);
    final extension = await extensionOf(repo.id, 'eu.example.one');
    expect(extension.artifact, ExtensionArtifact.apk);
    expect(extension.url.toString(), 'https://repo.example/apk/one-v1.2.3.apk');
  });

  test('添加 Mihon 仓库：根地址优先取 index.pb，缺 .pb 再退回 index.min.json', () async {
    // 有 .pb：只用 .pb。
    fetcher.binaries['https://repo.example/pbonly/index.pb'] = _samplePbIndex();
    final pbRepo = await service.addRepo(
      url: 'https://repo.example/pbonly',
      kind: RepoKind.mihon,
    );
    expect(pbRepo.url.path, '/pbonly/index.pb');
    expect(pbRepo.extensionCount, 2);

    // 只有 JSON（老仓库）：先试 .pb 拿 404，再退回 index.min.json。
    fetcher.responses['https://repo.example/mihon/index.min.json'] = mihonIndex;
    final jsonRepo = await service.addRepo(
      url: 'https://repo.example/mihon',
      kind: RepoKind.mihon,
    );
    expect(jsonRepo.url.path, '/mihon/index.min.json');
    expect(jsonRepo.extensionCount, 1);
    expect(
      fetcher.requested.map((uri) => uri.path).toList(),
      <String>['/pbonly/index.pb', '/mihon/index.pb', '/mihon/index.min.json'],
      reason: '根地址先探 .pb，404 后回退 JSON',
    );
  });

  test('indexUriFor：点名了索引文件就原样用（.json / .pb）', () {
    expect(
      ComicRepoService.indexUriFor('https://repo.example/a/index.pb', RepoKind.mihon)
          .toString(),
      'https://repo.example/a/index.pb',
    );
    expect(
      ComicRepoService.indexUriFor('https://repo.example/a', RepoKind.mihon).toString(),
      'https://repo.example/a/index.min.json',
    );
    expect(
      ComicRepoService.indexUriFor('https://repo.example/a', RepoKind.venera).toString(),
      'https://repo.example/a/index.json',
    );
  });

  test('添加仓库：地址已带 .json 时原样使用；地址非法时拒绝', () async {
    await service.addRepo(url: 'https://repo.example/index.json', kind: RepoKind.venera);
    expect(fetcher.requested.single.path, '/index.json');

    await expectLater(
      service.addRepo(url: 'ftp://repo.example/x', kind: RepoKind.venera),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      service.addRepo(url: '  ', kind: RepoKind.venera),
      throwsA(isA<SourceException>()),
    );
  });

  test('刷新仓库：重新抓取并更新计数；不存在的仓库报 notFound', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    fetcher.responses[indexUrl] = '''
[{"name": "只剩一个", "fileName": "only.js", "key": "only", "version": "1.0.0"}]
''';

    final updated = await service.refresh(repo.id);
    expect(updated.extensionCount, 1);
    expect((await service.extensions(repo.id)).single.id, 'only.js');

    await expectLater(
      service.refresh('https://repo.example/missing.json'),
      throwsA(isA<SourceException>()),
    );
  });

  test('安装 JS 扩展：下载脚本 → 走图源导入 → 记录安装', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    final extension = await extensionOf(repo.id, 'copy_manga.js');

    final result = await service.install(repo, extension);

    expect(result.isSuccess, isTrue);
    expect(result.sourceName, '新图源');
    expect(
      manager.imported.single,
      'var LumeSource = {id: "lume.copy"};',
      reason: '落到源表的就是下载到的脚本',
    );
    final installed = await service.installed(repo.id);
    expect(installed.keys, <String>['copy_manga.js']);
    expect(installed['copy_manga.js']!.sourceId, 'lume.new');
    expect(installed['copy_manga.js']!.version, '1.4.2');
  });

  test('安装 APK 扩展：如实拒绝且不碰图源表', () async {
    fetcher.responses['https://repo.example/mihon/index.min.json'] = mihonIndex;
    final repo = await service.addRepo(
      url: 'https://repo.example/mihon/index.min.json',
      kind: RepoKind.mihon,
    );
    final extension = (await service.extensions(repo.id)).single;

    final result = await service.install(repo, extension);

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('APK'));
    expect(result.message, contains('Android'));
    expect(manager.imported, isEmpty);
    expect(await service.installed(repo.id), isEmpty);
  });

  test('安装失败路径：下载失败与图源导入失败都给可读原因，不落记录', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    final extension = await extensionOf(repo.id, 'copy_manga.js');

    // 下载失败：脚本地址没有响应。
    fetcher.responses.remove('https://repo.example/copy_manga.js');
    final downloadFailure = await service.install(repo, extension);
    expect(downloadFailure.isSuccess, isFalse);
    expect(downloadFailure.message, contains('下载失败'));

    // 导入失败：脚本校验没过（替身按配置返回失败）。
    fetcher.responses['https://repo.example/copy_manga.js'] =
        'var LumeSource = {id: "lume.copy"};';
    manager.importFailure = '脚本载入失败：语法错误或运行异常';
    final importFailure = await service.install(repo, extension);
    expect(importFailure.isSuccess, isFalse);
    expect(importFailure.message, contains('安装失败'));
    expect(await service.installed(repo.id), isEmpty);
  });

  test('启停与卸载：都作用在漫画板块的图源上', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    final extension = await extensionOf(repo.id, 'copy_manga.js');
    await service.install(repo, extension);
    final installed = (await service.installed(repo.id))['copy_manga.js']!;

    await service.setEnabled(installed, false);
    expect(manager.toggled.single, ('lume.new', false));

    await service.uninstall(installed);
    expect(manager.removed.single, 'lume.new');
    expect(await service.installed(repo.id), isEmpty);
  });

  test('删除仓库：不卸载已安装的扩展', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    final extension = await extensionOf(repo.id, 'copy_manga.js');
    await service.install(repo, extension);

    await service.removeRepo(repo.id);

    expect(manager.removed, isEmpty, reason: '已安装扩展是独立源，不随仓库删除');
    expect(await service.repos(), isEmpty);
    expect(await service.extensions(repo.id), isEmpty);
  });

  test('启用状态来自漫画板块图源表', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    final extension = await extensionOf(repo.id, 'copy_manga.js');
    await service.install(repo, extension);

    expect((await service.enabledStates())['lume.new'], isTrue);
  });

  test('抓取失败：添加仓库报可读错误，且不落库', () async {
    await expectLater(
      service.addRepo(url: 'https://repo.example/nope', kind: RepoKind.venera),
      throwsA(isA<SourceException>()),
    );
    expect(await service.repos(), isEmpty);
  });

  test('板块守卫：非漫画板块构造即拒绝', () async {
    expect(
      () => ComicRepoService(
        store: store,
        sources: manager,
        fetcher: fetcher,
        section: Section.novel,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('只服务漫画板块'),
        ),
      ),
    );
  });

  test('close：释放仓库库；注入的抓取器不由服务释放', () async {
    final repo = await service.addRepo(url: indexUrl, kind: RepoKind.venera);
    expect(await service.repos(), isNotEmpty);

    service.close();

    expect(ComicRepoStore.find(), isNull);
    expect(fetcher.disposed, isFalse, reason: '注入进来的抓取器由调用方持有');
    expect(repo.id, indexUrl);
  });
}

/// 替身抓取器：按地址返回预置文本，记录请求，可注入缺失地址模拟网络失败。
class _FakeFetcher implements RepoFetcher {
  final Map<String, String> responses = <String, String>{};
  final List<Uri> requested = <Uri>[];
  bool disposed = false;

  @override
  Future<String> fetchText(Uri url) async {
    requested.add(url);
    final body = responses[url.toString()];
    if (body == null) {
      throw SourceException(SourceErrorKind.network, 'HTTP 404：$url');
    }
    return body;
  }

  /// 二进制索引（Mihon 的 index.pb）：单独一张表，缺省即 404。
  final Map<String, Uint8List> binaries = <String, Uint8List>{};

  @override
  Future<Uint8List> fetchBytes(Uri url) async {
    requested.add(url);
    final body = binaries[url.toString()];
    if (body == null) {
      throw SourceException(SourceErrorKind.network, 'HTTP 404：$url');
    }
    return body;
  }

  @override
  void dispose() => disposed = true;
}

/// 与真实索引同构的最小样例：Index{1:name, 101:{1:Extension…}}。
Uint8List _samplePbIndex() {
  List<int> varint(int value) {
    final out = <int>[];
    var remaining = value;
    while (remaining > 0x7f) {
      out.add((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    out.add(remaining & 0x7f);
    return out;
  }

  List<int> str(int field, String value) {
    final payload = utf8.encode(value);
    return <int>[...varint((field << 3) | 2), ...varint(payload.length), ...payload];
  }

  List<int> msg(int field, List<int> child) =>
      <int>[...varint((field << 3) | 2), ...varint(child.length), ...child];

  final first = <int>[
    ...str(1, '示例扩展'),
    ...str(2, 'eu.example.one'),
    ...msg(3, str(1, 'https://repo.example/apk/one-v1.2.3.apk')),
    ...str(6, '1.2.3'),
    ...msg(8, <int>[...str(2, '示例扩展'), ...str(3, 'all')]),
  ];
  final second = <int>[
    ...str(1, '第二个扩展'),
    ...str(2, 'eu.example.two'),
    ...msg(3, str(1, 'https://repo.example/apk/two-v1.0.0.apk')),
    ...str(6, '1.0.0'),
  ];
  final list = <int>[...msg(1, first), ...msg(1, second)];
  return Uint8List.fromList(<int>[...str(1, '示例仓库'), ...msg(101, list)]);
}
