import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/source/source_subscription_page.dart';

import 'dart:convert';

import 'package:lume_box/core/source/source_subscription_catalog.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/net/network_settings.dart';

import 'support/fake_source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Manager manager;
  late SourceSubscriptionSync service;
  late Map<String, String> remote;
  var now = DateTime(2026, 10, 13);
  const manifest = 'https://repo.example/sources.txt';
  setUp(() async {
    root = Directory.systemTemp.createTempSync('subscription-sync');
    manager = _Manager();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    remote = {};
    service = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: File('${root.path}/subscriptions.json'),
      clock: () => now,
      fetch: (url) async {
        final text = remote[url];
        if (text == null) throw StateError('HTTP 503');
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );
    await service.register([manifest], autoInstallNew: true);
  });
  tearDown(() async {
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  String script(String id, int version) =>
      'var LumeSource = {id:"$id", name:"$id", version:"$version"};';

  test('新源默认待选择，批准后才安装并保持后续更新', () async {
    SourceSubscriptionSync.attachNoticeFile(
      Section.video,
      File('${root.path}/notice.txt'),
    );
    SourceSubscriptionSync.acknowledge(Section.video);
    final record = service.subscriptions.single;
    record.autoInstallNew = false;
    remote[manifest] = 'https://repo.example/new.js';
    remote['https://repo.example/new.js'] = script('new', 1);
    final pending = await service.sync(force: true);
    expect(pending.pending, 1);
    expect(SourceSubscriptionSync.changeCount(Section.video).value, 1);
    expect(
      SourceSubscriptionSync.notices(Section.video).single['status'],
      '新源待安装',
    );
    expect(manager.sources, isEmpty);
    expect(record.pending.keys, contains('https://repo.example/new.js'));
    SourceSubscriptionSync.acknowledge(Section.video);
    await service.sync(force: true);
    expect(
      SourceSubscriptionSync.changeCount(Section.video).value,
      0,
      reason: '同一个待安装源已读后不反复亮角标',
    );
    await service.save();
    await service.load();
    final saved = service.subscriptions.single;
    expect(saved.pending, isNotEmpty);
    saved.approvedUrls.add('https://repo.example/new.js');
    expect((await service.sync(force: true)).added, 1);
    expect(SourceSubscriptionSync.changeCount(Section.video).value, 1);
    expect(
      SourceSubscriptionSync.notices(Section.video).single['status'],
      '已新增',
    );
    expect(saved.pending, isEmpty);
    remote['https://repo.example/new.js'] = script('new', 2);
    expect((await service.sync(force: true)).updated, 1);
  });

  test('单个源设置声明错误不会中断后续源，错误定位到具体文件', () async {
    remote[manifest] =
        'https://repo.example/bad.js\nhttps://repo.example/good.js';
    remote['https://repo.example/bad.js'] =
        '// LumeSource: {"id":"bad","name":"坏源","version":"1","settings":[{"key":"password","type":"password","title":"密码"}]}\n${script('bad', 1)}';
    remote['https://repo.example/good.js'] = script('good', 1);
    final result = await service.sync(force: true);
    expect(result.errors.join(), contains('https://repo.example/bad.js'));
    expect(result.errors.join(), isNot(contains('$manifest:')));
    expect(manager.sources.map((source) => source.id), contains('good'));
    expect(result.removed, 0);
  });

  test('旧 CDN 快照订阅迁移并合并成员与用户排除项', () async {
    const stable = '${SubscriptionCatalog.cdnBase}subscriptions/cdn/video.txt';
    service.subscriptions.clear();
    service.subscriptions.addAll([
      SavedSourceSubscription(
        '${SubscriptionCatalog.cdnBase}subscriptions/cdn/video.11111111.txt',
        members: {'retired': '${SubscriptionCatalog.cdnBase}video/retired.js'},
        excludedIds: {'excluded'},
      ),
      SavedSourceSubscription(
        stable,
        members: {'active': '${SubscriptionCatalog.cdnBase}video/active.js'},
      ),
    ]);
    await service.save();
    await service.load();
    expect(service.subscriptions, hasLength(1));
    expect(
      service.subscriptions.single.url,
      '${SubscriptionCatalog.base}subscriptions/video.txt',
    );
    expect(
      service.subscriptions.single.members.keys,
      containsAll(['retired', 'active']),
    );
    expect(service.subscriptions.single.excludedIds, {'excluded'});
    expect(service.subscriptions.single.checkedAt, isNull);
  });

  test('旧版本成员表缺失时恢复官方归属并移除远端已下架源，保留手动与外部源', () async {
    final official = SubscriptionCatalog.sectionUrl(Section.video);
    service.subscriptions.clear();
    await service.register([official], autoInstallNew: true);
    manager.sources.addAll([
      const SourceDescriptor(
        id: 'retired',
        name: '旧订阅源',
        version: '1',
        enabled: true,
        originUrl: '${SubscriptionCatalog.cdnBase}video/retired.js',
      ),
      const SourceDescriptor(
        id: 'manual',
        name: '手动源',
        version: '1',
        enabled: true,
      ),
      const SourceDescriptor(
        id: 'external',
        name: '外部源',
        version: '1',
        enabled: true,
        originUrl: 'https://external.example/source.js',
      ),
    ]);
    remote[official] = '${SubscriptionCatalog.base}video/active.js';
    remote['${SubscriptionCatalog.base}video/active.js'] = script('active', 1);
    final result = await service.sync(force: true);
    expect(result.errors, isEmpty);
    expect(result.removed, 1);
    expect(
      manager.sources.map((s) => s.id),
      containsAll(['active', 'manual', 'external']),
    );
    expect(manager.removed, ['retired']);
  });

  test('成员表与源保存的 GitHub/CDN 地址不同仍识别同一源并清理下架项', () async {
    const raw = '${SubscriptionCatalog.base}video/retired.js';
    const cdn = '${SubscriptionCatalog.cdnBase}video/retired.js';
    service.subscriptions.single.members['retired'] = raw;
    manager.sources.add(
      const SourceDescriptor(
        id: 'retired',
        name: '旧源',
        version: '1',
        enabled: true,
        originUrl: cdn,
      ),
    );
    remote[manifest] = '# 已清空';
    expect((await service.sync(force: true)).removed, 1);
  });

  test('旧源保存根订阅地址时，按成员表清理下架项', () async {
    manager.sources.add(
      const SourceDescriptor(
        id: 'retired',
        name: '旧源',
        version: '1',
        enabled: true,
        originUrl: manifest,
      ),
    );
    remote[manifest] = '# 已清空';
    expect((await service.sync(force: true)).removed, 1);
  });

  test('恢复归属后遇到不完整订阅仍保留全部旧源', () async {
    final official = SubscriptionCatalog.sectionUrl(Section.video);
    service.subscriptions.clear();
    await service.register([official]);
    manager.sources.add(
      const SourceDescriptor(
        id: 'retired',
        name: '旧源',
        version: '1',
        enabled: true,
        originUrl: '${SubscriptionCatalog.base}video/retired.js',
      ),
    );
    remote[official] = '${SubscriptionCatalog.base}video/missing.js';
    final result = await service.sync(force: true);
    expect(result.errors, isNotEmpty);
    expect(result.removed, 0);
    expect(manager.sources.map((s) => s.id), contains('retired'));
  });

  test('150 个源批量同步仅刷新页面一次，未读变更更新也不重复刷新', () async {
    SourceSubscriptionSync.attachNoticeFile(
      Section.video,
      File('${root.path}/notice.txt'),
    );
    SourceSubscriptionSync.acknowledge(Section.video);
    final ids = List.generate(150, (i) => 'batch-$i');
    remote[manifest] = ids
        .map((id) => 'https://repo.example/$id.js')
        .join('\n');
    final revision = SourceSubscriptionSync.revision(Section.video);
    final count = SourceSubscriptionSync.changeCount(Section.video);
    var reloads = 0;
    var countChanges = 0;
    void onReload() => reloads++;
    void onCount() => countChanges++;
    revision.addListener(onReload);
    count.addListener(onCount);
    addTearDown(() {
      revision.removeListener(onReload);
      count.removeListener(onCount);
    });
    for (var version = 1; version <= 2; version++) {
      for (final id in ids) {
        remote['https://repo.example/$id.js'] = script(id, version);
      }
      final result = await service.sync(force: true);
      expect(result.errors, isEmpty);
      expect(version == 1 ? result.added : result.updated, 150);
      expect(reloads, version, reason: '每轮整批完成后只刷新一次');
      expect(countChanges, 1, reason: '首次新增合并通知，已有未读变更不重复写入计数');
      expect(count.value, 150);
      expect(SourceSubscriptionSync.notices(Section.video), hasLength(150));
    }
    final saved = jsonDecode(
      File('${root.path}/notice.txt.json').readAsStringSync(),
    ) as Map;
    expect(saved, hasLength(150));
    expect(saved['batch-0']['status'], contains('1 → 2'));
    final unchanged = await service.sync(force: true);
    expect(unchanged.unchanged, 150);
    expect(reloads, 2, reason: '脚本没有变化不刷新页面');
  });

  test('手动同步等待后台检查后强制刷新，不沿用六小时内跳过的结果', () async {
    final stored = await SourceSubscriptionSync.open(
      Section.video,
      manager: manager,
    );
    await stored.register([manifest], autoInstallNew: true);
    stored.subscriptions.single.checkedAt = DateTime.now();
    await stored.save();
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 2);
    final background = SourceSubscriptionSync.refresh(
      Section.video,
      manager: manager,
      fetch: service.fetch,
    );
    final manual = SourceSubscriptionSync.refresh(
      Section.video,
      force: true,
      manager: manager,
      fetch: service.fetch,
    );
    final repeatedTap = SourceSubscriptionSync.refresh(
      Section.video,
      force: true,
      manager: manager,
      fetch: service.fetch,
    );
    expect(identical(manual, repeatedTap), isTrue);
    expect((await background).skipped, 1);
    final result = await manual;
    expect(result.checked, 1);
    expect(result.added, 1);
    expect(manager.sources.single.version, '2');
    await SourceSubscriptionSync.waitForIdle(Section.video);
  });

  test('没有启用订阅时明确说明，不返回无变化的假成功', () async {
    service.subscriptions.clear();
    final result = await service.sync(force: true);
    expect(result.summary, contains('请先添加订阅地址'));
    expect(result.checked, 0);
  });

  test('部分脚本拉取失败报告具体链接和原因，仍导入其余脚本', () async {
    remote[manifest] =
        'https://repo.example/a.js\nhttps://repo.example/missing.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    final result = await service.sync(force: true);
    expect(result.added, 1);
    expect(
      result.errors.join('\n'),
      contains('https://repo.example/missing.js'),
    );
    expect(result.errors.join('\n'), contains('HTTP 503'));
  });

  test('普通订阅同步也可按板块展开总订阅 JSON，忽略其他板块和停用条目', () async {
    remote[manifest] = jsonEncode({
      'format': 'lume.total-subscription',
      'version': 1,
      'sections': {
        'comic': ['https://repo.example/comics'],
        'video': [
          'https://repo.example/videos',
          {'url': 'https://repo.example/disabled', 'enabled': false},
          'https://repo.example/audiobooks',
        ],
      },
    });
    remote['https://repo.example/videos'] = 'https://repo.example/v.js';
    remote['https://repo.example/audiobooks'] = 'https://repo.example/a.js';
    remote['https://repo.example/v.js'] = script('video', 1);
    remote['https://repo.example/a.js'] = script('audio', 1);
    final result = await service.sync(force: true);
    expect(result.added, 2);
    expect(result.errors, isEmpty);
    expect(manager.sources.map((s) => s.id), containsAll(['video', 'audio']));
  });

  test('损坏的总订阅不触发已导入源移除', () async {
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await service.sync(force: true);
    remote[manifest] = jsonEncode({
      'format': 'lume.total-subscription',
      'version': 1,
      'sections': {'video': 'invalid-list'},
    });
    final result = await service.sync(force: true);
    expect(result.errors, isNotEmpty);
    expect(result.removed, 0);
    expect(manager.sources.single.id, 'a');
    remote[manifest] = jsonEncode({
      'format': 'lume.total-subscription',
      'version': 1,
      'sections': {'vidoe': []},
    });
    final typo = await service.sync(force: true);
    expect(typo.errors.join(), contains('未知板块'));
    expect(typo.removed, 0);
    expect(manager.sources.single.id, 'a');
  });

  test('手动删除不被同步装回，其他源继续更新；重新添加订阅可恢复', () async {
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/b.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    await service.sync();
    final removed = manager.sources.firstWhere((source) => source.id == 'a');
    await manager.remove('a');
    await service.markRemoved([removed]);
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: service.fetch,
    );
    await restarted.load();
    remote['https://repo.example/b.js'] = script('b', 2);
    await restarted.sync(force: true);
    expect(manager.sources.map((source) => source.id), ['b']);
    expect(manager.sources.single.version, '2');
    expect(restarted.subscriptions.single.excludedIds, {'a'});
    await restarted.register([manifest]);
    await restarted.sync(force: true);
    expect(manager.sources.map((source) => source.id), containsAll(['a', 'b']));
  });

  test('清空订阅后重开不会从已清理站点迁移恢复', () async {
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await service.sync();
    await manager.remove('a');
    await service.clearSavedSubscriptions();
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: service.fetch,
    );
    await restarted.load();
    await restarted.sync(force: true);
    expect(restarted.subscriptions, isEmpty);
    expect(manager.sources, isEmpty);
  });

  test('地址与清单成员落盘；自动新增更新移除，保留手动源和停用状态', () async {
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/b.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    expect((await service.sync()).added, 2);
    await manager.setEnabled('a', false);
    manager.sources.add(
      const SourceDescriptor(
        id: 'local',
        name: '手动',
        version: '1',
        enabled: true,
      ),
    );
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: service.fetch,
    );
    await restarted.load();
    expect(restarted.subscriptions.single.url, manifest);
    expect(
      restarted.subscriptions.single.members.keys,
      containsAll(['a', 'b']),
    );
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/c.js';
    remote['https://repo.example/a.js'] = script('a', 2);
    remote['https://repo.example/c.js'] = script('c', 1);
    final result = await restarted.sync(force: true);
    expect(result.updated, 1);
    expect(result.added, 1);
    expect(result.removed, 1);
    expect(manager.sources.map((s) => s.id), containsAll(['a', 'c', 'local']));
    expect(manager.sources.firstWhere((s) => s.id == 'a').enabled, false);
  });
  test('清单注释两种写法都认（# 与 //）——源仓库的 sources.js 用的是 //', () async {
    // 真机踩过：严格清单只跳过 `#` 注释，而源仓库三份清单是 `.js`、注释用 `//`，
    // 于是同步把整份清单判成「非地址内容」→ 新增源一个都进不来（推送了也看不到）。
    remote[manifest] = [
      '// LumeBox 订阅清单（本行是 // 注释）',
      'https://repo.example/a.js',
      '# 本行是 # 注释',
      'https://repo.example/b.js',
    ].join('\n');
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    final result = await service.sync(force: true);
    expect(result.errors, isEmpty);
    expect(result.added, 2);
    expect(manager.sources.map((s) => s.id).toList()..sort(), ['a', 'b']);
  });

  test('拉取部分失败不把暂时取不到的源误删；健康检查六小时内去重', () async {
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/b.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    await service.sync();
    remote.remove('https://repo.example/b.js');
    expect((await service.sync()).errors, isEmpty, reason: '未到检查时间');
    final result = await service.sync(force: true);
    expect(result.errors, isNotEmpty);
    expect(manager.removed, isEmpty);
    expect(manager.sources.map((s) => s.id), contains('b'));
  });
  test('HTML错误页不执行移除；可信空清单仅移除该订阅成员', () async {
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await service.sync();
    remote[manifest] = '<html>Access denied</html>';
    expect((await service.sync(force: true)).errors, isNotEmpty);
    expect(manager.removed, isEmpty);
    remote[manifest] = '# 该订阅已清空\n';
    expect((await service.sync(force: true)).removed, 1);
    expect(manager.removed, ['a']);
  });
  test('取消订阅持久化，重启后不重新拉取或清除手动源', () async {
    service.subscriptions.clear();
    await service.save();
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: (_) async => throw StateError('不应请求'),
    );
    await restarted.load();
    expect((await restarted.sync(force: true)).errors, isEmpty);
    expect(restarted.subscriptions, isEmpty);
  });
  test('禁用订阅不会拉取，手动导入同ID保护由专门导入端口保证', () async {
    service.subscriptions.single.enabled = false;
    expect((await service.sync(force: true)).errors, isEmpty);
    expect(manager.imported, isEmpty);
  });
  test('升级保留已保存根订阅，不额外恢复成员地址，立即拉取新版脚本', () async {
    const scriptUrl = 'https://repo.example/a.js';
    manager.sources.add(
      const SourceDescriptor(
        id: 'a',
        name: 'a',
        version: '1',
        enabled: true,
        originUrl: scriptUrl,
      ),
    );
    service.subscriptions.single.members['a'] = scriptUrl;
    service.subscriptions.single.checkedAt = now;
    remote[manifest] = scriptUrl;
    remote[scriptUrl] = script('a', 2);
    await service.save();
    expect((await service.sync()).updated, 1);
    expect(service.subscriptions.map((s) => s.url), [manifest]);
    expect(manager.sources.single.version, '2');
  });

  testWidgets('官方综合订阅选择线路后直接添加，自定义地址保留', (tester) async {
    final official = SubscriptionCatalog.mixedFor(SubscriptionRoute.cloudflare);
    remote[official] = 'https://repo.example/mixed.js';
    remote['https://repo.example/mixed.js'] = script('mixed', 1);
    await tester.pumpWidget(
      MaterialApp(
        home: SourceSubscriptionPage(
          section: Section.video,
          manager: manager,
          fetchSubscription: service.fetch,
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.enterText(
      find.byType(TextField),
      'https://custom.example/list.txt',
    );
    await tester.tap(find.text('综合源订阅'));
    await settle();
    await tester.tap(find.text('Cloudflare'));
    await settle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://custom.example/list.txt',
    );
    final stored = await tester.runAsync(
      () => SourceSubscriptionSync.open(Section.video, manager: manager),
    );
    expect(
      stored!.subscriptions.map((record) => record.url),
      contains(official),
    );
    await tester.scrollUntilVisible(
      find.textContaining('个新源待选择安装'),
      250,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.textContaining('个新源待选择安装'), findsOneWidget);
  });

  testWidgets('常驻订阅入口：添加一次、返回重进保留链接、无需粘贴即可更新', (tester) async {
    await tester.runAsync(
      () => SourceSubscriptionSync.open(Section.video, manager: manager),
    );
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SourceSubscriptionPage(
                    section: Section.video,
                    manager: manager,
                    fetchSubscription: service.fetch,
                  ),
                ),
              ),
              child: const Text('订阅'),
            ),
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('订阅管理 · 添加订阅链接'), findsNothing);
    await tester.tap(find.text('订阅'));
    await settle();
    await tester.enterText(find.byType(TextField), manifest);
    await tester.tap(find.text('综合源订阅'));
    await settle();
    await tester.tap(find.text('全部视频订阅'));
    await settle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      manifest,
    );
    await tester.enterText(find.byType(TextField), manifest);
    await tester.tap(find.text('添加订阅并检查可安装源'));
    await settle();
    expect(manager.sources, isEmpty);
    await tester.tap(find.text('选择安装'));
    await settle();
    await tester.tap(find.text('全部导入'));
    await settle();
    expect(manager.sources.single.version, '1');
    expect(find.text(manifest), findsOneWidget);
    await tester.pageBack();
    await settle();
    expect(find.textContaining('已保存 1 个订阅'), findsNothing);
    await tester.tap(find.text('订阅'));
    await settle();
    expect(find.text(manifest), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('检查更新与增减'), findsOneWidget);
    expect(find.text('更新已保存的订阅'), findsNothing);
    expect(find.byTooltip('同步订阅'), findsNothing);
    remote['https://repo.example/a.js'] = script('a', 2);
    await tester.tap(find.text('检查更新与增减'));
    await settle();
    expect(manager.sources.single.version, '2');
    remote.remove('https://repo.example/a.js');
    await tester.tap(find.text('检查更新与增减'));
    await settle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.textContaining('HTTP 503'), findsWidgets);
    expect(manager.sources.single.version, '2', reason: '失败时保留原源');
  });
}

class _Manager extends FakeSourceManager implements SubscriptionImportManager {
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {
    final old = sources.firstWhere((s) => s.id == sourceId);
    sources.remove(old);
    sources.add(
      SourceDescriptor(
        id: old.id,
        name: old.name,
        version: old.version,
        enabled: enabled,
        originUrl: old.originUrl,
        network: old.network,
      ),
    );
  }

  @override
  Future<SourceImportResult> importSubscription(
    String script, {
    required String originUrl,
  }) async {
    final id = RegExp('id:"([^"]+)"').firstMatch(script)!.group(1)!;
    final version = RegExp('version:"([^"]+)"').firstMatch(script)!.group(1)!;
    final old = sources.where((s) => s.id == id).firstOrNull;
    if (old != null && old.originUrl.isEmpty) {
      return const SourceImportResult.failure('保留手动源');
    }
    sources.removeWhere((s) => s.id == id);
    final next = SourceDescriptor(
      id: id,
      name: id,
      version: version,
      enabled: old?.enabled ?? true,
      originUrl: originUrl,
      network: old?.network ?? const NetworkProfile(),
    );
    sources.add(next);
    scripts[id] = script;
    imported.add(script);
    return SourceImportResult.success(next);
  }
}
