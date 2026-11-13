import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/media/media_resource_service.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/cat/cat_preloader.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/video/video_download_center.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CatService service;
  late HttpServer remote;
  late HttpServer node;
  late Uri remoteBase, nodeBase;
  Map<String, dynamic>? runtime;
  final secrets = <String, String>{};
  var starts = 0;
  var index = 'module.exports={start:async()=>{}}';
  var advertised = '';
  var failDownload = false;
  Future<Map<String, dynamic>> bridge(
    String action,
    Map<String, dynamic> opt, {
    String? id,
  }) async {
    final spec = runtime!;
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${spec['bridgePort']}/msg'),
      );
      req.headers.contentType = ContentType.json;
      req.headers.set('x-catvod-token', spec['token']);
      if (id != null) req.headers.set('x-lume-cat-source', id);
      req.write(jsonEncode({'action': action, 'opt': opt}));
      final response = await req.close();
      return catMap(jsonDecode(await utf8.decoder.bind(response).join()));
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    HttpOverrides.global =
        null; // These contract tests use only loopback fixture servers.
    root = Directory.systemTemp.createTempSync('cat-contract');
    secrets.clear();
    starts = 0;
    runtime = null;
    failDownload = false;
    index = 'module.exports={start:async()=>{}}';
    advertised = md5.convert(utf8.encode(index)).toString();
    remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    remoteBase = Uri.parse('http://127.0.0.1:${remote.port}');
    remote.listen((req) async {
      final path = req.uri.path;
      if (failDownload) {
        req.response.statusCode = 503;
      } else if (path.endsWith('.config.js.md5')) {
        req.response.statusCode = 404;
      } else if (path.endsWith('.js.md5')) {
        req.response.write(advertised);
      } else if (path.endsWith('.config.js')) {
        req.response.write('module.exports={video:{sites:[]}}');
      } else {
        req.response.write(index);
      }
      await req.response.close();
    });
    node = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    nodeBase = Uri.parse('http://127.0.0.1:${node.port}');
    node.listen((req) async {
      final body = catMap(
        jsonDecode(
          await utf8.decoder.bind(req).join().then((s) => s.isEmpty ? '{}' : s),
        ),
      );
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path.endsWith('/_health')) {
        req.response.write('{"ok":true,"service":"local-danmaku"}');
      } else if (req.uri.path == '/ctl/source') {
        await bridge('sourceStarted', {
          'id': body['id'],
          'address': nodeBase.toString(),
        });
        req.response.write('{}');
      } else if (req.uri.path == '/website') {
        req.response.write(
          '{}',
        ); // JSON placeholder must not be treated as the config page.
      } else if (req.uri.path == '/website/index.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>网盘登录</html>');
      } else if (req.uri.path == '/config') {
        req.response.write(
          jsonEncode({
            'video': {
              'sites': [
                {'key': 'nodejs_demo', 'name': '测试站点', 'type': 3},
                {'key': 'disabled', 'name': '禁用', 'enable': false},
              ],
            },
          }),
        );
      } else if (req.uri.path.endsWith('/home')) {
        req.response.write(
          jsonEncode({
            'class': [
              {'type_id': 'movie', 'type_name': '电影'},
            ],
            'filters': {
              'movie': [
                {
                  'key': 'area',
                  'name': '地区',
                  'value': [
                    {'n': '全部', 'v': ''},
                    {'n': '国产', 'v': 'cn'},
                  ],
                },
              ],
            },
          }),
        );
      } else if (req.uri.path.endsWith('/play')) {
        expect(body['id'], 'episode-2');
        req.response.write(jsonEncode({
          'url': '/fixture.mp4',
          'headers': {'Referer': 'https://site.example/watch'},
        }));
      } else if (req.uri.path == '/fixture.mp4') {
        expect(req.headers.value('referer'), 'https://site.example/watch');
        req.response.headers.contentType = ContentType('video', 'mp4');
        req.response.add([0, 0, 0, 8, 102, 116, 121, 112]);
      } else if (req.uri.path.endsWith('/category')) {
        expect(body['id'], 'movie');
        expect(body['page'], isA<int>());
        expect(body['filters'], anyOf(isNull, isA<Map>()));
        expect(body['tid'], body['id']);
        expect(body['pg'], '${body['page']}');
        expect(body['extend'], body['filters'] ?? {});
        req.response.write(
          jsonEncode({
            'list': [
              {'vod_id': 'same', 'vod_name': '影片', 'vod_pic': '/poster.jpg'},
            ],
            'pagecount': 2,
          }),
        );
      } else {
        req.response.write('{}');
      }
      await req.response.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CatService.channel, (call) async {
          final args = catMap(call.arguments);
          if (call.method == 'readSecret') return secrets[args['key']];
          if (call.method == 'writeSecret') {
            if (args['value'] == null) {
              secrets.remove(args['key']);
            } else {
              secrets[args['key']] = args['value'];
            }
          }
          if (call.method == 'isSupported') return true;
          if (call.method == 'start') {
            starts++;
            runtime = catMap(
              jsonDecode(await File(args['spec']).readAsString()),
            );
            await bridge('controlReady', {'address': nodeBase.toString()});
            final source = catMaps(runtime!['sources']).first;
            await bridge('sourceStarted', {
              'id': source['id'],
              'address': nodeBase.toString(),
            });
            return true;
          }
          return null;
        });
    service = CatService.testing();
  });
  tearDown(() async {
    await service.closeForTesting();
    await remote.close(force: true);
    await node.close(force: true);
    root.deleteSync(recursive: true);
  });
  test('本地ZIP保存并启动、同名替换保留身份，跳过在线更新且重启可用', () async {
    Uint8List pack(String script) => Uint8List.fromList(ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile.string('dist/index.js', script))
      ..addFile(ArchiveFile.string('dist/index.config.js', 'module.exports={}'))));
    final record = await service.importLocal('本地测试', pack(index));
    expect(record.isLocal, isTrue);
    expect(record.automatic, isFalse);
    expect(await service.hasBundle(record), isTrue);
    expect(CatSubscription.fromJson(record.toJson()).isLocal, isTrue);
    await service.refreshSites(record);
    expect(record.sites, isNotEmpty);
    final id = record.id;
    final oldHash = record.hash;
    final oldSites = record.sites.map((s) => s.id).toList();
    final replaced = await service.importLocal('本地测试', pack('$index; // updated'));
    expect(replaced.id, id);
    expect(replaced.hash, isNot(oldHash));
    expect(replaced.sites.map((s) => s.id), oldSites);
    expect(service.subscriptions.length, 1);
    failDownload = true;
    await service.update(replaced);
    await service.checkUpdates();
    expect(replaced.error, isEmpty);
    await service.closeForTesting();
    service = CatService.testing();
    await service.boot();
    final restored = service.subscriptions.single;
    expect(restored.id, id);
    expect(restored.isLocal, isTrue);
    expect(await service.hasBundle(restored), isTrue);
  });

  test('损坏的本地ZIP不新增记录、不替换旧包', () async {
    final archive = Archive()..addFile(ArchiveFile.string('index.js', index));
    await expectLater(service.importLocal('坏包', Uint8List.fromList(ZipEncoder().encode(archive))),
      throwsFormatException);
    expect(service.subscriptions, isEmpty);
  });

  test('猫源订阅在媒体库重新取址，并在下载队列重启后按原板块离线播放', () async {
    await service.closeForTesting();
    service = CatService.instance;
    final record = await service.add('下载测试', remoteBase.resolve('/source.js.md5').toString());
    await service.refreshSites(record);
    final site = record.sites.single;
    final item = jsonEncode([site.id, 'show']);
    final chapters = CatDataSource.parseChapters({
      'vod_play_from': 'A', 'vod_play_url': r'第2集$episode-2',
    });
    final library = MediaLibrary();
    await library.boot(directory: root);
    final resource = await MediaResourceService(library: library).source(
      source: CatDataSource(service, site), item: SourceItem(id: item, title: '猫源音频'),
      chapters: chapters, deferContent: true, hint: ResourceKind.audioBook,
    );
    expect(resource.originSection, Section.cat);
    final persisted = MediaLibrary();
    await persisted.boot(directory: root);
    final saved = persisted.byId(resource.id)!;
    final track = MediaResourceService(library: persisted).audioTracks(saved).single;
    final resolved = await track.resolve!();
    expect(resolved.url, nodeBase.resolve('/fixture.mp4'));
    expect(resolved.headers['Referer'], 'https://site.example/watch');
    final queue = VideoDownloadCenter(directory: () async => root);
    await queue.enqueue(section: Section.cat, sourceId: site.id, itemId: item,
        title: '猫源下载', chapters: chapters);
    final task = queue.tasks.single;
    final finished = Stopwatch()..start();
    while ((task.state == 'queued' || task.running) && finished.elapsed < const Duration(seconds: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.state, 'done', reason: task.error);
    await queue.flush();
    final restored = VideoDownloadCenter(directory: () async => root);
    await restored.boot();
    expect(restored.tasks.single.section, Section.cat);
    final playback = await restored.completedPlayback(site.id, item, chapters.single.id, section: Section.cat);
    expect(await File.fromUri(playback!.uri).readAsBytes(), [0, 0, 0, 8, 102, 116, 121, 112]);
    expect(await restored.completedPlayback(site.id, item, chapters.single.id), isNull);
    await playback.close();
  });

  test('内置服务安装校验、随机地址、重复启动复用，且不进入猫源订阅表', () async {
    final first = await service.startLocalDanmaku();
    expect(first.host, '127.0.0.1');
    expect(first.path, matches(RegExp(r'^/[a-f0-9]{64}$')));
    expect(starts, 1);
    expect(service.subscriptions, isEmpty);
    final specification = catMaps(runtime!['sources']).single;
    final bytes = await File(
      '${File(specification['index']).parent.path}/upstream.cjs',
    ).readAsBytes();
    expect(
      sha256.convert(bytes).toString(),
      jsonDecode(
        await File('assets/local_danmaku/manifest.json').readAsString(),
      )['patchedSha256'],
    );
    expect(await service.startLocalDanmaku(), first);
    expect(starts, 1);
    await service.stopLocalDanmaku();
    final second = await service.startLocalDanmaku();
    expect(second, first);
    expect(starts, 1, reason: '停止服务不停止共享 Node 进程');
    expect(service.subscriptions, isEmpty);
  });

  test('猫源批量移除收藏与历史互不影响，保持其他站点记录', () async {
    final site = CatSite(
      subscriptionId: 'collection',
      key: 'a',
      name: 'A',
      api: '/spider/a',
    );
    for (final id in ['one', 'two']) {
      await service.toggleFavorite(site, {'id': id, 'title': id});
      await service.remember(site, {'id': id, 'title': id});
    }
    await service.removeCollection({'${site.id}|one'}, favorites: true);
    expect(service.favoriteItems.map((e) => e['id']), ['two']);
    expect(service.history.length, 2);
    await service.removeCollection({'${site.id}|two'}, favorites: false);
    expect(service.history.single['id'], 'one');
    expect(service.favoriteItems.single['id'], 'two');
  });

  test('猫源记住历史不会自动收藏；只有 toggleFavorite 才进收藏', () async {
    final site = CatSite(
      subscriptionId: 'history-only',
      key: 'a',
      name: 'A',
      api: '/spider/a',
    );
    await service.remember(site, {'id': 'viewed', 'title': '只看过'});

    expect(service.history.map((e) => e['id']), ['viewed']);
    expect(service.favoriteItems, isEmpty, reason: '打开内容不是收藏');

    await service.toggleFavorite(site, {'id': 'liked', 'title': '手点收藏'});
    expect(service.favoriteItems.map((e) => e['id']), ['liked']);
    expect(service.history.map((e) => e['id']), ['viewed']);
  });

  test('记住最后选择的订阅与站点，正常重开精准恢复，不落到第一个订阅', () async {
    final first = await service.add(
      '第一',
      remoteBase.resolve('/one.js.md5').toString(),
    );
    final second = await service.add(
      '第二',
      remoteBase.resolve('/two.js.md5').toString(),
    );
    await service.refreshSites(first);
    await service.refreshSites(second);
    await service.select(second.sites.single);
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.needsSiteSelection, isFalse);
    expect(restored.selectedSiteId, second.sites.single.id);
    expect(CatPreloader.selectedSite(restored)!.subscriptionId, second.id);
    await restored.closeForTesting();
  });
  test('删除猫站点持久化，刷新和重启不会恢复，订阅及历史保留', () async {
    final record = await service.add(
      '保留订阅',
      remoteBase.resolve('/delete.js.md5').toString(),
    );
    await service.refreshSites(record);
    final site = record.sites.single;
    await service.select(site);
    await service.remember(site, {'id': 'viewed', 'title': '历史条目'});
    await service.removeSite(site);
    expect(service.selectedSiteId, isNull);
    await service.refreshSites(record);
    expect(record.sites, isEmpty);
    expect(record.error, isEmpty);
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.subscriptions.single.removedSiteIds, contains(site.id));
    expect(restored.subscriptions.single.sites, isEmpty);
    expect(restored.history.single['id'], 'viewed');
    await restored.closeForTesting();
  });

  test('包丢失时自动重新下载，不留下启用但无法读取站点的状态', () async {
    final record = await service.add(
      '修复',
      remoteBase.resolve('/index.js.md5').toString(),
    );
    final bundle = Directory(
      '${root.path}/sections/cat/node/bundles/${record.id}/${record.hash}-${record.configHash}',
    );
    await bundle.delete(recursive: true);
    expect(await service.hasBundle(record), isFalse);
    await service.refreshSites(record);
    expect(await service.hasBundle(record), isTrue);
    expect(record.sites, isNotEmpty);
    expect(record.error, isEmpty);
  });
  test('原生启动中断后的持久化恢复不会自动重启问题源', () async {
    final record = await service.add(
      '恢复',
      remoteBase.resolve('/index.js.md5').toString(),
    );
    await service.refreshSites(record);
    await service.select(record.sites.single);
    final file = File('${root.path}/sections/cat/node/subscriptions.json');
    final stored = catMap(jsonDecode(await file.readAsString()));
    stored['pendingSources'] = [record.id];
    await file.writeAsString(jsonEncode(stored));
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.needsSiteSelection, isTrue);
    expect(restored.selectedSiteId, isNull);
    expect(starts, 1, reason: '恢复只读配置，不启动Node');
    expect(restored.subscriptions.single.error, contains('上次站点启动未完成'));
    final recovered = catMap(jsonDecode(await file.readAsString()));
    expect(recovered['pendingSources'], isEmpty);
    await restored.closeForTesting();
  });
  test('旧版记住泥潭源的用户升级后先进入安全选择页，保留订阅', () async {
    final record = await service.add(
      '泥潭',
      remoteBase.resolve('/index.js.md5').toString(),
    );
    await service.refreshSites(record);
    await service.select(record.sites.single);
    final file = File('${root.path}/sections/cat/node/subscriptions.json');
    final stored = catMap(jsonDecode(await file.readAsString()));
    stored.remove('startupRecoveryVersion');
    catMaps(stored['subscriptions']);
    (stored['subscriptions'] as List).first['url'] = 'https://ghfast.top/https://raw.githubusercontent.com/nitan-tv/nitan/refs/heads/main/js/index.js.md5';
    await file.writeAsString(jsonEncode(stored));
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.needsSiteSelection, isTrue);
    expect(
      restored.subscriptions.single.enabled,
      isTrue,
      reason: '保留用户订阅，可显式重试',
    );
    expect(restored.selectedSiteId, isNull);
    await restored.closeForTesting();
  });
  test('兔佬备用版本仅允许已核实的同作者快照和发布MD5', () {
    final uri = Uri.parse(
      'https://raw.githubusercontent.com/xiaobaitulele/xptv/refs/heads/main/jstv/index.js.md5',
    );
    expect(
      CatService.verifiedBundleFallback(
        uri,
        'eae292d3319ef56fa34a57c6bc459b61',
      )!.path,
      contains('9d15140196c4653fc3dbdc39a648eea9b627bcb8'),
    );
    expect(
      CatService.verifiedBundleFallback(
        uri,
        '00000000000000000000000000000000',
      ),
      isNull,
    );
    expect(
      CatService.verifiedBundleFallback(
        Uri.parse('https://other.example/index.js.md5'),
        'eae292d3319ef56fa34a57c6bc459b61',
      ),
      isNull,
    );
  });
  test('包装在data里的分类列表可解析，不误报空列表', () {
    expect(
      catPayload({
        'data': {
          'list': [
            {'vod_id': '1'},
          ],
        },
      })['list'],
      isNotEmpty,
    );
    expect(
      catPayload({'data': '{"list":[{"vod_id":"1"}]}'})['list'],
      isNotEmpty,
    );
  });
  test('站点列数独立保存并在重启后恢复', () async {
    await service.boot();
    await service.setSiteColumns(2);
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.siteColumns, 2);
    await restored.setSiteColumns(99);
    expect(restored.siteColumns, 2);
    await restored.closeForTesting();
  });
  test('订阅持久化、校验失败保留旧包、首次失败仍保留链接供重试', () async {
    final record = await service.add(
      '包',
      remoteBase.resolve('/index.js.md5').toString(),
    );
    final old = record.hash;
    index = 'corrupt';
    advertised = '00000000000000000000000000000000';
    await expectLater(service.update(record), throwsFormatException);
    expect(record.hash, old);
    expect(record.error, contains('MD5'));
    failDownload = true;
    await expectLater(
      service.add('稍后重试', remoteBase.resolve('/other.js.md5').toString()),
      throwsA(isA<HttpException>()),
    );
    expect(service.subscriptions.length, 2);
    final stored = catMap(
      jsonDecode(
        await File('${root.path}/sections/cat/node/subscriptions.json')
            .readAsString(),
      ),
    );
    expect(
      catMaps(stored['subscriptions']).last['url'],
      endsWith('/other.js.md5'),
    );
  });
  test('一次 Node 启动、多订阅账号隔离、真实配置页探测和筛选映射', () async {
    final first = await service.add(
      '一',
      remoteBase
          .resolve('/one.js.md5')
          .replace(userInfo: 'user:password')
          .toString(),
    );
    final second = await service.add(
      '二',
      remoteBase.resolve('/two.js.md5').toString(),
    );
    expect(first.id, isNot(second.id));
    expect(first.hash, second.hash);
    await service.activate(first);
    await service.activate(second);
    expect(starts, 1);
    expect(first.sites.single.key, 'demo');
    await bridge('saveProfile', {'cookie': 'account-one'}, id: first.id);
    await bridge('saveProfile', {'cookie': 'account-two'}, id: second.id);
    expect(
      (await bridge('queryProfile', {}, id: first.id))['cookie'],
      'account-one',
    );
    expect(
      (await bridge('queryProfile', {}, id: second.id))['cookie'],
      'account-two',
    );
    await bridge('saveProfile', {}, id: second.id);
    expect(
      await bridge('queryProfile', {}, id: second.id),
      isEmpty,
      reason: '退出账号不能重新恢复已删除的凭证',
    );
    final page = await service.configurationUrl(second);
    expect(page.path, '/website/index.html');
    final source = CatDataSource(service, first.sites.single);
    expect(
      (await source.filtersFor(categoryId: 'movie')).single.options.last.id,
      'cn',
    );
    final list = await source.list(
      categoryId: 'movie',
      filters: {'area': 'cn'},
    );
    expect(list.hasMore, true);
    expect((await source.list(categoryId: 'movie', page: 2)).hasMore, false);
    expect(source.rawItemId(list.items.single.id), 'same');
    expect(list.items.single.cover, nodeBase.resolve('/poster.jpg').toString());
    final stored = await File(
      '${root.path}/sections/cat/node/subscriptions.json',
    ).readAsString();
    expect(stored, isNot(contains('password')));
    expect(stored, isNot(contains('account-one')));
  });
  test('播放线路先分隔后还原网址，集数与站点身份不串', () {
    final configured = CatSite.fromJson('config', {
      'key': 'nodejs_configured',
      'name': '有配置的站点',
      'api': 'http://127.0.0.1:9988/spider/configured/3?mode=local',
      'ext': {
        'headers': {'User-Agent': 'fixture'},
        'enabled': true,
      },
    });
    expect(configured.ext, isA<Map>());
    expect(configured.api, '/spider/configured/3?mode=local');
    expect(CatSite.fromJson('config', configured.toJson()).ext, configured.ext);
    final chapters = CatDataSource.parseChapters({
      'vod_play_from': '线路一',
      'vod_play_url':
          '第一集\$https://video.test/a?token=a＃b＄c#第二集\$https://video.test/b',
    });
    expect(chapters.length, 2);
    expect(
      catMap(jsonDecode(chapters.first.id))['id'],
      'https://video.test/a?token=a#b\$c',
    );
    final a = CatSite(
      subscriptionId: 'a',
      key: 'same',
      name: 'A',
      api: '/spider/same/3',
    );
    final b = CatSite(
      subscriptionId: 'b',
      key: 'same',
      name: 'B',
      api: '/spider/same/3',
    );
    expect(
      CatDataSource(service, a).item({'vod_id': '1', 'vod_name': 'A'})!.id,
      isNot(
        CatDataSource(service, b).item({'vod_id': '1', 'vod_name': 'B'})!.id,
      ),
    );
  });
}
