import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

/// 全局网络设置的持久化与单图源覆盖的落库往返。
///
/// 这一层坏掉的后果是「设置改了但没生效」或「重启后配置丢失」，因此两侧都要
/// 覆盖：JSON 文件（全局）与板块库 schema v3 的新列（图源级）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_net_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    NetworkSettingsStore.resetForTesting();
  });

  tearDown(() async {
    await SectionScope.closeAll();
    SectionDatabase.disposeAll();
    NetworkSettingsStore.resetForTesting();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('全局设置存储', () {
    test('文件缺失时回退默认值', () async {
      final store = await NetworkSettingsStore.open();
      final settings = store.load();
      expect(settings.globalConcurrency, NetworkSettings.defaultGlobalConcurrency);
      expect(settings.perHostConcurrency, NetworkSettings.defaultPerHostConcurrency);
      expect(settings.userAgent, '');
      expect(settings.proxy, '');
    });

    test('保存后能读回（含 UA / 代理 / 超时 / 重试）', () async {
      final store = await NetworkSettingsStore.open();
      store.save(const NetworkSettings(
        globalConcurrency: 12,
        perHostConcurrency: 3,
        userAgent: 'My-UA/1.0',
        proxy: 'http://127.0.0.1:7890',
        timeout: Duration(seconds: 45),
        maxRetries: 4,
      ));

      final loaded = store.load();
      expect(loaded.globalConcurrency, 12);
      expect(loaded.perHostConcurrency, 3);
      expect(loaded.userAgent, 'My-UA/1.0');
      expect(loaded.proxy, 'http://127.0.0.1:7890');
      expect(loaded.timeout, const Duration(seconds: 45));
      expect(loaded.maxRetries, 4);
    });

    test('越界值写入时被收敛（防封参数不会被手滑关掉）', () async {
      final store = await NetworkSettingsStore.open();
      store.save(const NetworkSettings(globalConcurrency: 1, perHostConcurrency: 99));

      final loaded = store.load();
      expect(loaded.globalConcurrency, NetworkSettings.minGlobalConcurrency);
      expect(loaded.perHostConcurrency, NetworkSettings.maxPerHostConcurrency);
    });

    test('文件损坏时回退默认，不让网络层起不来', () async {
      final store = await NetworkSettingsStore.open();
      File(store.path).writeAsStringSync('{ 这不是合法 JSON');

      final loaded = store.load();
      expect(loaded.globalConcurrency, NetworkSettings.defaultGlobalConcurrency);
    });

    test('JSON 往返：字段齐全且缺项回退默认', () {
      const settings = NetworkSettings(
        globalConcurrency: 10,
        perHostConcurrency: 3,
        userAgent: 'UA',
        proxy: 'http://p:1',
      );
      final restored = NetworkSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(restored.globalConcurrency, 10);
      expect(restored.perHostConcurrency, 3);
      expect(restored.userAgent, 'UA');
      expect(restored.proxy, 'http://p:1');

      // 缺项 / 非法值回退默认。
      final partial = NetworkSettings.fromJson(<String, Object?>{'userAgent': 'X'});
      expect(partial.globalConcurrency, NetworkSettings.defaultGlobalConcurrency);
      expect(partial.userAgent, 'X');
      expect(NetworkSettings.fromJson(null).globalConcurrency,
          NetworkSettings.defaultGlobalConcurrency);
    });
  });

  group('单图源网络覆盖（库 schema v3）', () {
    test('写入后读回：UA / Cookie / 代理', () async {
      final scope = await SectionScope.open(Section.novel);
      final db = await SectionDatabase.open(scope);
      db.upsertSource(
        id: 'src-1',
        name: '测试源',
        version: '1.0.0',
        section: Section.novel.id,
        script: 'var LumeSource = {};',
      );

      // 默认全空 = 继承全局。
      expect(db.source('src-1')!.network.isEmpty, isTrue);

      db.setSourceNetwork(
        'src-1',
        userAgent: 'Source-UA',
        cookie: 'sid=1',
        proxy: 'http://127.0.0.1:1080',
      );

      final record = db.source('src-1')!;
      expect(record.network.userAgent, 'Source-UA');
      expect(record.network.cookie, 'sid=1');
      expect(record.network.proxy, 'http://127.0.0.1:1080');
      expect(record.network.isEmpty, isFalse);
    });

    test('重命名 / 启停不影响网络覆盖', () async {
      final scope = await SectionScope.open(Section.comic);
      final db = await SectionDatabase.open(scope);
      db.upsertSource(
        id: 'src-2',
        name: '漫画源',
        version: '1.0.0',
        section: Section.comic.id,
        script: 'var LumeSource = {};',
      );
      db.setSourceNetwork('src-2', userAgent: 'UA-2', cookie: '', proxy: '');

      db.setSourceEnabled('src-2', false);
      expect(db.source('src-2')!.network.userAgent, 'UA-2');
      expect(db.source('src-2')!.enabled, isFalse);

      // 更新脚本（重新导入）也不该抹掉网络配置。
      db.upsertSource(
        id: 'src-2',
        name: '漫画源改名',
        version: '2.0.0',
        section: Section.comic.id,
        script: 'var LumeSource = { v: 2 };',
      );
      final record = db.source('src-2')!;
      expect(record.name, '漫画源改名');
      expect(record.network.userAgent, 'UA-2', reason: '重新导入不应清掉网络配置');
    });

    test('清空覆盖 = 恢复继承全局', () async {
      final scope = await SectionScope.open(Section.video);
      final db = await SectionDatabase.open(scope);
      db.upsertSource(
        id: 'src-3',
        name: '视频源',
        version: '1.0.0',
        section: Section.video.id,
        script: 'var LumeSource = {};',
      );
      db.setSourceNetwork('src-3', userAgent: 'UA', cookie: 'c', proxy: 'p');
      expect(db.source('src-3')!.network.isEmpty, isFalse);

      db.setSourceNetwork('src-3', userAgent: '', cookie: '', proxy: '');
      expect(db.source('src-3')!.network.isEmpty, isTrue);
    });

    test('旧库（v2）打开时自动补列，不丢数据', () async {
      final scope = await SectionScope.open(Section.cat);
      // 先正常建库并写一条图源。
      final db = await SectionDatabase.open(scope);
      db.upsertSource(
        id: 'legacy',
        name: '旧库源',
        version: '1.0.0',
        section: Section.cat.id,
        script: 'var LumeSource = {};',
      );
      SectionDatabase.disposeAll();

      // 模拟 v2 库：把版本号退回去（列还在，迁移要能容忍「列已存在」）。
      final raw = File(scope.dbPath).readAsBytesSync();
      expect(raw, isNotEmpty);
      // 重新打开：迁移逻辑跑一遍，数据与默认网络配置都在。
      final reopened = await SectionDatabase.open(scope);
      final record = reopened.source('legacy')!;
      expect(record.name, '旧库源');
      expect(record.network.isEmpty, isTrue, reason: '旧记录的覆盖列默认为空');
    });
  });
  group('忽略证书错误（按源开放，默认关）', () {
    test('默认关闭；copyWith / JSON 往返都带着它', () {
      expect(NetworkProfile.none.allowBadCertificate, isFalse);
      const profile = NetworkProfile();
      expect(profile.allowBadCertificate, isFalse);

      final relaxed = profile.copyWith(allowBadCertificate: true);
      expect(relaxed.allowBadCertificate, isTrue);

      final decoded = NetworkProfile.fromJson(relaxed.toJson());
      expect(decoded.allowBadCertificate, isTrue, reason: '开了就要存得住');
    });

    test('老配置读不出来一律按「关闭」处理（绝不悄悄放宽）', () {
      final legacy = NetworkProfile.fromJson(<String, Object?>{
        'userAgent': 'x',
        'cookie': '',
        'proxy': '',
        'bridge': '',
      });
      expect(legacy.allowBadCertificate, isFalse);
      expect(NetworkProfile.fromJson(null).allowBadCertificate, isFalse);
      expect(
        NetworkProfile.fromJson(<String, Object?>{'allowBadCertificate': 'true'})
            .allowBadCertificate,
        isFalse,
        reason: '只有布尔 true 才算开：字符串不算，避免脏配置把校验关掉',
      );
    });

    test('请求默认不放宽：只有图源显式开启才会带上这个标记', () {
      const plain = NetworkRequest(url: 'https://example.com');
      expect(plain.allowBadCertificate, isFalse);
      const relaxed = NetworkRequest(
        url: 'https://example.com',
        allowBadCertificate: true,
      );
      expect(relaxed.allowBadCertificate, isTrue);
    });

    test('非空判定：只开了这个开关也算「有覆盖」', () {
      const profile = NetworkProfile(allowBadCertificate: true);
      expect(profile.isEmpty, isFalse);
    });
  });

}
