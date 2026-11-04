import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/source/source_package.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/source/total_subscription.dart';
import 'package:lume_box/features/settings/total_subscription_page.dart';

import 'support/fake_source_manager.dart';

void main() {
  testWidgets('总订阅可切换 Cloudflare、国内 CDN 与原站，地址跟随选择', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TotalSubscriptionPage()));
    await tester.tap(find.text('国内 CDN'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      SubscriptionCatalog.totalCdnUrl,
    );
    await tester.tap(find.text('Cloudflare'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      SubscriptionCatalog.totalPagesUrl,
    );
    await tester.tap(find.text('GitHub 原站'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      SubscriptionCatalog.totalUrl,
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Map<Section, _Manager> managers;
  late Map<String, String> remote;
  late TotalSubscriptionService service;
  final total = TotalSubscription({
    for (final section in SubscriptionCatalog.sections)
      section: [
        (
          url:
              '${SubscriptionCatalog.base}${SubscriptionCatalog.names[section]}',
          enabled: true,
        ),
      ],
  });
  setUp(() async {
    root = Directory.systemTemp.createTempSync('total-subscription-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    managers = {
      for (final section in SubscriptionCatalog.sections)
        section: _Manager(section),
    };
    remote = {SubscriptionCatalog.totalUrl: '\ufeff${total.encode()}'};
    for (final section in SubscriptionCatalog.sections) {
      final scriptUrl = 'https://repo.test/${section.id}.js';
      remote[total.entries[section]!.single.url] = scriptUrl;
      remote[scriptUrl] =
          '// LumeSource: ${jsonEncode({'id': section.id, 'name': section.label, 'version': '1', 'category': section.id})}\nvar LumeSource = {};';
    }
    service = TotalSubscriptionService(
      managers: managers,
      fetch: (url) async {
        if (!remote.containsKey(url)) throw StateError('HTTP 503');
        final text = remote[url]!;
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );
  });
  tearDown(() async {
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });

  Future<Map<Section, SubscriptionSyncResult>> importAndApprove(
    TotalSubscription total,
  ) async {
    final results = await service.import(total);
    for (final section in results.keys) {
      if (results[section]!.pending == 0) continue;
      final stored = await SourceSubscriptionSync.open(
        section,
        manager: managers[section],
      );
      for (final record in stored.subscriptions) {
        record.approvedUrls.addAll(record.pending.keys);
      }
      await stored.save();
      results[section] = await SourceSubscriptionSync.refresh(
        section,
        force: true,
        manager: managers[section],
        fetch: service.fetch,
      );
    }
    return results;
  }

  test('总订阅新源保持待安装，不会直接写入源管理器', () async {
    final results = await service.import(total);
    expect(results[Section.video]!.pending, 1);
    expect(managers[Section.video]!.sources, isEmpty);
  });

  test('一键导入全部源不改变自动安装偏好', () async {
    final results = await service.import(total, installAll: true);
    expect(results[Section.video]!.added, 1);
    expect(results[Section.video]!.pending, 0);
    final stored = await SourceSubscriptionSync.open(
      Section.video,
      manager: managers[Section.video],
    );
    expect(stored.subscriptions.single.autoInstallNew, isFalse);
  });

  test('批量导入报告排除项，仅恢复用户选择的源', () async {
    await service.import(total, installAll: true);
    final stored = await SourceSubscriptionSync.open(
      Section.video,
      manager: managers[Section.video],
    );
    final original = managers[Section.video]!.sources.single;
    await stored.markRemoved([original]);
    await managers[Section.video]!.remove(original.id);
    final result = await service.import(total, installAll: true);
    expect(
      result[Section.video]!.excluded,
      containsPair(original.id, original.name),
    );
    expect(managers[Section.video]!.sources, isEmpty);
    final restored = await service.restoreExcluded(total, {
      Section.video: {original.id},
    });
    expect(restored[Section.video]!.added, 1);
    expect(managers[Section.video]!.sources.single.id, original.id);
  });

  test('重试仅重新检查失败的订阅，已成功的订阅不再下载', () async {
    const first = 'https://repo.test/first.txt';
    const second = 'https://repo.test/second.txt';
    const a = 'https://repo.test/a.js';
    const b = 'https://repo.test/b.js';
    final custom = TotalSubscription({
      Section.video: [
        (url: first, enabled: true),
        (url: second, enabled: true),
      ],
    });
    remote[first] = a;
    remote[second] = b;
    remote[a] = '// LumeSource: {"id":"a","name":"A","version":"1","category":"video"}\nvar LumeSource={};';
    var calls = <String>[];
    final injected = TotalSubscriptionService(
      managers: managers,
      fetch: (url) async {
        calls.add(url);
        if (!remote.containsKey(url)) throw StateError('HTTP 503');
        final text = remote[url]!;
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );
    final firstRun = await injected.import(custom, installAll: true);
    expect(firstRun[Section.video]!.failedSubscriptions, contains(second));
    remote[b] = '// LumeSource: {"id":"b","name":"B","version":"1","category":"video"}\nvar LumeSource={};';
    calls = [];
    final retry = await injected.retryFailed(custom, firstRun);
    expect(retry[Section.video]!.errors, isEmpty);
    expect(calls, contains(second));
    expect(calls, isNot(contains(first)));
    expect(
      managers[Section.video]!.sources.map((source) => source.id),
      containsAll(['a', 'b']),
    );
  });

  test('总订阅递归影视清单保留 Python 源和运行时', () async {
    const scriptUrl = 'https://repo.test/movie/gulu.py';
    remote[total.entries[Section.video]!.single.url] = scriptUrl;
    remote[scriptUrl] =
        '# LumeSource: {"id":"gulu_python_video","name":"咕噜咕噜","version":"1.0.1","category":"video","contentCategory":"movie"}\n'
        '# LumeRuntime: python\nclass Spider: pass\n';
    final results = await importAndApprove(
      await service.read(SubscriptionCatalog.totalUrl),
    );
    expect(results[Section.video]!.errors, isEmpty);
    expect(results[Section.video]!.added, 1);
    final manager = managers[Section.video]!;
    expect(manager.sources.single.id, 'gulu_python_video');
    expect(
      SourcePackage.kindOf(manager.scripts['gulu_python_video']!),
      SourcePackageKind.python,
    );
    expect(manager.sources.single.originUrl, scriptUrl);
  });

  test('总地址分配三个版块、保留手动源，导出保留地址和停用状态', () async {
    managers[Section.video]!.sources.add(
      const SourceDescriptor(
        id: 'manual',
        name: '手动',
        version: '1',
        enabled: true,
      ),
    );
    final results = await importAndApprove(
      await service.read(SubscriptionCatalog.totalUrl),
    );
    for (final section in SubscriptionCatalog.sections) {
      expect(results[section]!.added, 1);
      expect(results[section]!.errors, isEmpty);
      expect(managers[section]!.sources.any((s) => s.id == section.id), isTrue);
    }
    expect(
      managers[Section.video]!.sources.any((s) => s.id == 'manual'),
      isTrue,
    );
    final video = await SourceSubscriptionSync.open(
      Section.video,
      manager: managers[Section.video],
    );
    video.subscriptions.single.enabled = false;
    await video.save();
    final exported = TotalSubscription.decode(
      (await service.export()).encode(),
    );
    expect(exported.entries[Section.video]!.single.enabled, isFalse);
    expect(
      exported.entries[Section.video]!.single.url,
      total.entries[Section.video]!.single.url,
    );
    expect(exported.encode(), isNot(contains('manual')));
  });

  test('旧六类订阅合并，保留成员、排除清单与启用状态', () async {
    final scope = await SectionScope.open(Section.comic);
    final file = File(scope.resolve('subscriptions.json'));
    file.writeAsStringSync(
      jsonEncode({
        'migrationVersion': 3,
        'subscriptions': [
          {
            'url': '${SubscriptionCatalog.base}photos',
            'enabled': false,
            'members': {'photo': 'https://repo.test/photo.js'},
            'excludedIds': ['photo'],
          },
          {
            'url': '${SubscriptionCatalog.base}comics',
            'enabled': true,
            'members': {'comic': 'https://repo.test/comic.js'},
          },
        ],
      }),
    );
    final stored = await SourceSubscriptionSync.open(
      Section.comic,
      manager: managers[Section.comic],
    );
    expect(stored.subscriptions.length, 1);
    final record = stored.subscriptions.single;
    expect(
      record.url,
      '${SubscriptionCatalog.base}${SubscriptionCatalog.names[Section.comic]}',
    );
    expect(record.members.keys, containsAll(['photo', 'comic']));
    expect(record.excludedIds, {'photo'});
    expect(record.enabled, isTrue);
    expect(jsonDecode(file.readAsStringSync())['subscriptions'].length, 1);
    expect(
      SubscriptionCatalog.canonical(
        '${SubscriptionCatalog.base}movies',
        Section.video,
      ),
      '${SubscriptionCatalog.base}${SubscriptionCatalog.names[Section.video]}',
    );
    expect(
      SubscriptionCatalog.canonical(
        '${SubscriptionCatalog.base}movies',
        Section.video,
      ),
      '${SubscriptionCatalog.base}${SubscriptionCatalog.names[Section.video]}',
    );
  });

  test('错误总订阅在写入前拒绝；单板块网络失败不阻止其他板块', () async {
    await expectLater(
      importAndApprove(
        TotalSubscription({
          Section.video: [(url: 'file:///bad', enabled: true)],
        }),
      ),
      throwsFormatException,
    );
    expect(managers.values.every((m) => m.sources.isEmpty), isTrue);
    expect(
      () => TotalSubscription.decode(
        '{"format":"lume.total-subscription","version":1,"sections":{"other":[]}}',
      ),
      throwsFormatException,
    );
    remote.remove(total.entries[Section.comic]!.single.url);
    final results = await importAndApprove(total);
    expect(results[Section.comic]!.errors, isNotEmpty);
    expect(results[Section.video]!.added, 1);
    expect(results[Section.video]!.added, 1);
  });

  testWidgets('总订阅入口预览确认，取消不导入，支持生成和复制导出', (tester) async {
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
    final fixture = _UiService(total);
    await tester.pumpWidget(
      MaterialApp(home: TotalSubscriptionPage(service: fixture)),
    );
    await tester.tap(find.text('导入总订阅'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '漫画：1 个订阅\n视频：1 个订阅\n\n按板块保存并检查。已有源正常更新，新源先进入待安装列表，请勾选后安装。保留其他订阅和手动导入的源。',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.imported, 0);
    await tester.tap(find.text('导入总订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(fixture.imported, 1);
    await tester.ensureVisible(find.text('生成总订阅导出'));
    await tester.tap(find.text('生成总订阅导出'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('复制总订阅'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('复制总订阅'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == '总订阅已复制'),
      findsOneWidget,
    );
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      total.encode(),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

class _Manager extends FakeSourceManager implements SubscriptionImportManager {
  _Manager(this.section);
  final Section section;
  @override
  Future<SourceImportResult> importSubscription(
    String script, {
    required String originUrl,
  }) async {
    final metadata = SourceMetadata.parseHeader(script)!;
    if (metadata.sectionMismatch(section) != null) {
      return const SourceImportResult.failure('板块不匹配');
    }
    final next = SourceDescriptor(
      id: metadata.id,
      name: metadata.name,
      version: metadata.version,
      enabled: true,
      originUrl: originUrl,
    );
    sources.removeWhere((s) => s.id == next.id);
    sources.add(next);
    scripts[next.id] = script;
    return SourceImportResult.success(next);
  }
}

class _UiService extends TotalSubscriptionService {
  _UiService(this.total);
  final TotalSubscription total;
  int imported = 0;
  @override
  Future<TotalSubscription> read(String input) async => total;
  @override
  Future<TotalSubscription> export() async => total;
  @override
  Future<Map<Section, SubscriptionSyncResult>> import(
    TotalSubscription total, {
    bool installAll = false,
  }) async {
    imported++;
    return {
      for (final section in total.entries.keys)
        section: SubscriptionSyncResult()..added = 1,
    };
  }
}
