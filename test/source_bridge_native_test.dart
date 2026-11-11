import 'package:flutter/services.dart';
import 'package:lume_box/core/js/source_web_runtime.dart';

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as transport;
import 'package:http/testing.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/qjs_bindings.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/cat/cat_web_parse.dart';
import 'package:lume_box/core/source/web_player_episode.dart';
import 'package:lume_box/core/source/source_extension_settings.dart';
import 'package:lume_box/core/source/source_settings_policy.dart';

/// 真实引擎下的桥接验证（用户反馈的 Bug2）：
///
/// 宿主按严格顺序注入 console / 定时器 / 环境垫片 → **全局桥接对象
/// `LumeSource`** → 才执行用户脚本；因此
/// - 脚本只写顶层 `async function getList(page)` 也能跑通（不再出现
///   「全局对象不存在: LumeSource」）；
/// - 脚本可以直接用 `LumeSource.http.*`（宿主网络）与 `LumeSource.fs.*`
///   （按图源隔离的沙盒存储）；
/// - 对象式脚本（`var LumeSource = { … }`）照旧可用，且合并后桥接能力不丢。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = _resolveBridge();
  if (bridge != null) {
    Qjs.overrideLibrary(bridge);
    // 断言型构建下释放 JSRuntime 会触发插件的泄漏断言，测试进程同样适用。
    Qjs.reclaimRuntime = false;
  }

  final skipReason = Qjs.isAvailable
      ? null
      : '未找到可用的 quickjs 原生桥（${Qjs.availabilityDetail}）';

  group('真实引擎 · LumeSource 桥接', () {
    late _RecordingHttp http;
    late LumeSourceHost host;
    late LumeSandbox sandbox;

    /// 按生产口径建沙箱（同一套策略与垫片登记表），再载入脚本。
    Future<JsDataSource> boot(
      String script, {
      Section section = Section.video,
      LumeHttp? network,
    }) async {
      http = _RecordingHttp();
      host = LumeSourceHost(
        network ?? http,
        timeout: const Duration(seconds: 3),
        section: section,
        sourceId: 'bridge-source',
      );
      sandbox = LumeSandbox.create(
        id: host.expectedSandboxId,
        policy: LumeJsEngine.policy.copyWith(allowHostAccess: true),
        host: host,
        polyfills: LumeSourcePolyfills.forSection(section),
      );
      addTearDown(() {
        sandbox.dispose();
        host.dispose();
      });
      final loaded = await sandbox.load(script);
      expect(loaded.isOk, isTrue, reason: '脚本必须能载入: ${loaded.error}');
      return JsDataSource(
        id: 'bridge-source',
        name: '桥接用例源',
        section: section,
        runtime: _SandboxRuntime(sandbox),
      );
    }

    test('二进制 POST 经 http.request、http.post 和 fetch 原样到达宿主', () async {
      final requests = <transport.Request>[];
      final network = LumeHttp(
        client: MockClient((request) async {
          requests.add(request);
          return transport.Response('', 200);
        }),
      );
      addTearDown(network.dispose);
      final source = await boot(r'''
        var LumeSource = {list: async function(args) {
          if (args.categoryId === 'request') await LumeSource.http.request({url:'https://example.com/pb',method:'POST',bodyBase64:'AP+A',binary:true});
          else if (args.categoryId === 'post') await LumeSource.http.post('https://example.com/pb',null,{bodyBase64:'AP+A',binary:true});
          else await fetch('https://example.com/pb',{method:'POST',bodyBase64:'AP+A'});
          return {items:[]};
        }};
      ''', network: network);
      for (final mode in ['request', 'post', 'fetch']) {
        await source.list(categoryId: mode);
        expect(requests.last.bodyBytes, [0, 255, 128], reason: mode);
      }
      expect(requests, hasLength(3));
    });

    test('橘汁 JS 真 QuickJS 五入口通过原生 RSA/AES 与二进制 protobuf', () async {
      final script = File('sources/video/juzhi4k.js').readAsStringSync();
      final publicKey = RegExp("var JZ_PUBLIC = '([^']+)'")
          .firstMatch(script)![1]!;
      List<int> varint(int value) {
        final out = <int>[];
        do {
          out.add((value & 127) | (value > 127 ? 128 : 0));
          value >>= 7;
        } while (value > 0);
        return out;
      }

      List<int> field(int number, Object value) {
        if (value is int) return [...varint(number * 8), ...varint(value)];
        final bytes = value is String ? utf8.encode(value) : value as List<int>;
        return [...varint(number * 8 + 2), ...varint(bytes.length), ...bytes];
      }

      final paths = <String>[];
      final network = LumeHttp(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.contains('getCategory')) {
            return transport.Response(
              jsonEncode({
                'data': [
                  {'id': 20, 'name': '电影'},
                  {'id': 21, 'name': '剧集'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          expect(request.bodyBytes, isNotEmpty);
          expect(request.headers['Content-Type'], 'application/x-protobuf');
          late List<int> payload;
          if (request.url.path.endsWith('/zone')) {
            payload = field(1, publicKey);
          } else if (request.url.path.endsWith('/category')) {
            payload = field(1, [...field(3, 42), ...field(5, '测试电影')]);
          } else if (request.url.path.endsWith('/getDetail')) {
            payload = [
              ...field(9, '测试电影'),
              ...field(29, [
                ...field(2, '正片'),
                ...field(4, 'https://site.invalid/watch/42.html'),
                ...field(9, 'mgtv'),
                ...field(10, 'M蓝光'),
              ]),
            ];
          } else {
            expect(request.url.path, endsWith('/videoUsableUrl'));
            payload = field(1, 'https://media.invalid/movie.m3u8');
          }
          return transport.Response.bytes([
            ...field(1, 200),
            ...field(3, payload),
          ], 200);
        }),
      );
      addTearDown(network.dispose);
      final source = await boot(script, network: network);
      expect(await source.categories(), hasLength(2));
      final page = await source.list(categoryId: '20');
      expect(page.items.single.title, '测试电影');
      final detail = await source.detail(page.items.single.id);
      expect(detail!.title, '测试电影');
      final chapters = await source.chapters(page.items.single.id);
      expect(chapters.single.line, 'M蓝光');
      final content = await source.content(
        itemId: page.items.single.id,
        chapterId: chapters.single.id,
      );
      expect(
        (content as VideoContent).url.toString(),
        'https://media.invalid/movie.m3u8',
      );
      expect(paths.where((p) => p.endsWith('/getDetail')), hasLength(1));
      expect(
        paths.last,
        endsWith('/videoUsableUrl'),
        reason: 'HTTPS watch pages require resolution',
      );
    });

    test('所有源可直接调用通用工具与同步 pako，赋值不会覆盖宿主', () async {
      final source = await boot(r'''
        var LumeSource = {tools:{},media:{},session:{}};
        async function getList() {
          const digest = await LumeSource.tools.digest('sha256','abc');
          const text = pako.inflate(new Uint8Array([120, 156, 123, 218, 181, 226, 89, 67, 227, 139, 229, 139, 159, 246, 117, 63, 235, 152, 240, 180, 107, 62, 0, 118, 64, 12, 59]),{to:'string'});
          return {items:[{id:digest,title:text}]};
        }
      ''');
      final page = await source.list(page: 1);
      expect(page.items.single.title, '动态解压成功');
      expect(
        page.items.single.id,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('源签名钩子只改本次请求的头与正文，网页播放标记不交给解码器', () async {
      final source = await boot(r'''
        var LumeSource = {
          prepareRequest: async function(request) {
            if (typeof request.bridge.request !== 'function') throw new Error('bridge unavailable');
            return {headers:{'x-source-sign':'local-signature'},body:'signed-body'};
          },
          list: async function() {
            await LumeSource.http.post('https://api.example.com/search','original',{headers:{'x-original':'keep'}});
            return {items:[],hasMore:false};
          },
          content: async function() { return {webPlayer:true,url:'blob:https://site.example/internal',pageUrl:'https://site.example/play/1',headers:{Referer:'https://site.example/'},webPlayerOptions:{episodeSelector:'button.playbtn[data-id="74596"]'}}; }
        };
      ''');
      await source.list();
      expect(http.lastHeaders['x-source-sign'], 'local-signature');
      expect(http.lastHeaders['x-original'], 'keep');
      expect(http.lastBody, 'signed-body');
      await expectLater(
        source.content(itemId: 'one', chapterId: '1'),
        throwsA(
          isA<CatWebParseRequired>()
              .having((e) => e.webPlayer, 'webPlayer', true)
              .having(
                (e) => e.episodeSelector,
                'episodeSelector',
                'button.playbtn[data-id="74596"]',
              )
              .having(
                (e) => e.page.toString(),
                'page',
                'https://site.example/play/1',
              ),
        ),
      );
    });

    test('网页选集脚本只点击当前作品的唯一可见按钮，选择器作为数据传入', () async {
      await boot('var LumeSource = {};');
      await sandbox.eval(r'''
        var clicked=0, nodes=[], location={origin:'https://site.example',pathname:'/play/1'};
        var document={readyState:'complete',querySelectorAll:function(s){globalThis.seenSelector=s;return nodes;}};
        var button={tagName:'BUTTON',type:'button',disabled:false,getClientRects:function(){return [1];},click:function(){clicked++;}};
        nodes=[button];
      ''');
      final script = webPlayerEpisodeScript(
        Uri.parse('https://site.example/play/1'),
        'button[data-id="2"]',
      );
      expect((await sandbox.eval(script)).value, 'selected');
      expect((await sandbox.eval('clicked')).value, 1);
      await sandbox.eval("location.pathname='/play/other';");
      expect((await sandbox.eval(script)).value, 'wrong-page');
      await sandbox.eval("location.pathname='/play/1';nodes=[button,button];");
      expect((await sandbox.eval(script)).value, 'waiting');
      await sandbox.eval('nodes=[button];button.type="submit";');
      expect((await sandbox.eval(script)).value, 'waiting');
      final literal = 'button[data-id="2"];clicked=99;//';
      await sandbox.eval(
        webPlayerEpisodeScript(
          Uri.parse('https://site.example/play/1'),
          literal,
        ),
      );
      expect((await sandbox.eval('seenSelector')).value, literal);
      expect((await sandbox.eval('clicked')).value, 1);
    });

    test('网页选集参数过长时报告契约错误', () async {
      final source = await boot(
        'var LumeSource={content:async function(){return {kind:"webplayer",pageUrl:"https://site.example/play/1",webPlayerOptions:{episodeSelector:"x".repeat(257)}};}};',
      );
      await expectLater(
        source.content(itemId: 'one', chapterId: 'two'),
        throwsA(isA<SourceException>()),
      );
    });

    test('真实JS桥按顺序渲染、CSS提取并返回源列表，宿主能力不会被覆盖', () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SourceWebRuntime.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'render') {
          expect(call.arguments['waitForSelector'], '.card');
          expect(call.arguments['headers']['User-Agent'], isNotEmpty);
          return {
            'html': '<article class="card">示例</article>',
            'url': 'https://fixture.invalid/',
          };
        }
        expect(call.arguments['fields']['title']['selector'], 'a');
        return [
          {'title': '动态结果', 'id': 'https://fixture.invalid/watch/1'},
        ];
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(SourceWebRuntime.channel, null),
      );
      final source = await boot(r'''
        var LumeSource = {web: 'bad', html: 'bad', list: async function() {
          const page = await LumeSource.web.render({url:'https://fixture.invalid/', waitForSelector:'.card'});
          return {items:await LumeSource.html.extract(page.html, {rowSelector:'.card', fields:{title:{selector:'a'}}}), hasMore:false};
        }};
      ''');
      expect((await source.list()).items.single.title, '动态结果');
      expect(calls.map((call) => call.method), ['render', 'extract']);
    });

    test('资源线路和专用设置进入冻结快照，解析地址与操作参数真实可用', () async {
      final source = await boot(r'''
        var LumeSource={
          list:async function(){
            try{LumeSource.config.settings.quality='changed';}catch(_){}
            return {items:[{id:LumeSource.resolveUrl('https://images.example/a.jpg?sig=x%2Fy','image'),title:LumeSource.config.settings.quality}]};
          },
          settingsAction:async function(a){return {message:a.key+':'+a.settings.quality+':'+a.config.domain};}
        };
      ''');
      final config = SourceSiteConfig(
        mirrors: const ['https://site.example'],
        domainOverride: 'https://custom.example',
        images: SourceRoute.parse(['https://images.example'])
            .copyWith(custom: 'https://new-images.example/cdn'),
        video: SourceRoute.parse(['https://video.example'])
            .copyWith(custom: 'https://new-video.example'),
        settingDefinitions: SourceSetting.parseAll([
          {'key': 'quality', 'title': '画质', 'type': 'text', 'default': 'hd'},
        ]),
        commonDefinitions: SourceSettingsPolicy.parseCommon([
          {'key': 'pageSize', 'default': 20},
        ]),
        appSettingValues: const {'pageSize': 42},
      );
      final injected = jsonEncode(jsonEncode(config.toScriptJson(cookie: '')));
      await sandbox.eval('__lumeApplyConfig($injected)');
      final capabilities = await sandbox.eval(r'''JSON.stringify((function(){
        try{LumeSource.config.commonSettings.pageSize=999;}catch(_){}
        try{LumeSource.config.sourceSettings.quality='bad';}catch(_){}
        try{LumeSource.capabilities.settingsFeatures.push('bad');}catch(_){}
        LumeSource={capabilities:{settingsApiVersion:99}};
        return [LumeSource.capabilities.settingsApiVersion,
          LumeSource.capabilities.settingsFeatures.indexOf('actionInputs')>=0,
          Object.isFrozen(LumeSource.capabilities),
          Object.isFrozen(LumeSource.capabilities.settingTypes),
          LumeSource.config.commonSettings.pageSize,
          LumeSource.config.sourceSettings.quality];
      })())''');
      expect(capabilities.value, [2, true, true, true, 42, 'hd']);
      final result = await source.list();
      expect(
        result.items.single.id,
        'https://new-images.example/cdn/a.jpg?sig=x%2Fy',
      );
      expect(result.items.single.title, 'hd');
      expect(
        (await sandbox.eval('Object.isFrozen(LumeSource.config.settings)'))
            .value,
        true,
      );
      expect(
        (await sandbox.eval(
          'LumeSource.resolveUrl("https://video.example/1.m3u8","video")',
        )).value,
        'https://new-video.example/1.m3u8',
      );
      expect(
        (await source.settingsAction(
          'refresh',
          settings: {'quality': 'sd'},
          config: {'domain': 'https://preview.example'},
        ) as Map)['message'],
        'refresh:sd:https://preview.example',
      );
      expect(
        (await sandbox.eval('LumeSource.config.domain')).value,
        'https://custom.example',
        reason: '操作预览参数不修改持久配置',
      );
    });

    test('用户验证脚本：顶层 getList(page) 直接跑通', () async {
      final source = await boot(_userVerificationScript);

      final list = await source.list(page: 2);
      expect(list.items.single.title, '测试视频');
      expect(list.items.single.id, 'https://example.com/demo.mp4');
      expect(list.hasMore, isFalse);
      // 位置参数：函数式契约的第一位就是页码（不是对象）。
      expect((await sandbox.eval('__seenPage')).value, 2);
      expect((await sandbox.eval('typeof __seenPage')).value, 'number');

      // 头部元信息仍由脚本自己声明（桥接对象不冒充 id / name）。
      expect(
        SourceMetadata.parseHeader(_userVerificationScript)?.id,
        'demo-video',
      );
      expect(
        (await sandbox.eval('JSON.stringify({id: LumeSource.id})')).value,
        <String, Object?>{},
      );
    });

    test('函数式契约：分类 / 搜索 / 详情 / 章节 / 内容全套可用', () async {
      final source = await boot(_functionStyleScript);

      final categories = await source.categories();
      expect(categories.single.title, '分类一');

      final page = await source.list(page: 3);
      expect(page.items.single.id, 'v3');

      // 关键词走 getSearch(keyword, page)。
      final search = await source.list(keyword: '关键词', page: 2);
      expect(search.items.single.title, '关键词#2');

      final detail = await source.detail('v3');
      expect(detail?.title, '详情 v3');

      final chapters = await source.chapters('v3');
      expect(chapters.single.id, 'v3-1');

      final content = await source.content(itemId: 'v3', chapterId: 'v3-1');
      expect(content, isA<VideoContent>());
      expect(
        (content! as VideoContent).url.toString(),
        'https://example.com/v3/v3-1.mp4',
      );
    });

    test('桥接宿主能力：http 走宿主网络，fs 落在按图源隔离的沙盒存储', () async {
      final source = await boot(_bridgeCapabilityScript);

      final list = await source.list();
      expect(http.urls.single, 'https://api.example.com/list');
      expect(list.items.single.title, 'cache/list.json');
      expect(list.items.single.id, '列表缓存');
      expect(host.store.read('cache/list.json'), '列表缓存');

      // 脚本删掉之后，宿主侧的存储同步消失（fs 就是这张表的门面）。
      final removed = await sandbox.call(
        'LumeSource.fs.remove',
        '/cache/list.json',
      );
      expect(removed.value, isTrue);
      expect(host.store.read('cache/list.json'), isNull);
    });

    test('对象式脚本合并后桥接能力仍在', () async {
      final source = await boot(_objectStyleScript);

      expect((await sandbox.eval('LumeSource.id')).value, 'obj-source');
      expect(
        (await sandbox.eval('typeof LumeSource.http.get')).value,
        'function',
        reason: '脚本对象不能把宿主 HTTP 能力盖掉',
      );
      expect(
        (await sandbox.eval('typeof LumeSource.fs.readText')).value,
        'function',
      );

      final list = await source.list();
      expect(list.items.single.id, 'o1');
      // 对象式收对象入参（与函数式的位置参数区分开）。
      expect(
        (await sandbox.eval('JSON.stringify(__seenArgument)')).value,
        <String, Object?>{'page': 1},
      );
    });

    test('let / const 声明的 LumeSource 同样被识别', () async {
      final source = await boot(_lexicalScript);
      final list = await source.list();
      expect(list.items.single.id, 'l1');
      expect(
        (await sandbox.eval('LumeSource.id')).value,
        'lex',
        reason: '脚本自己的对象',
      );
    });

    test('反复赋值：非对象忽略、对象合并，桥接能力始终在', () async {
      final source = await boot(_reassignScript);
      final list = await source.list();
      expect(list.items.single.id, 'r1');
      expect((await sandbox.eval('LumeSource.id')).value, 'again');
      expect((await sandbox.eval('LumeSource.name')).value, '二次赋值源');
      expect(
        (await sandbox.eval('typeof LumeSource.http.get')).value,
        'function',
      );
      expect(
        (await sandbox.eval('typeof LumeSource.fs.writeText')).value,
        'function',
      );
    });

    test('严格顺序：脚本执行时桥接与垫片都已就位', () async {
      final source = await boot(_bootOrderScript);
      expect(
        (await sandbox.eval('__boot')).value,
        'object|function|function|function|function|object',
        reason: 'LumeSource / LumeSource.http / LumeSource.fs / console / 定时器 / LumeBridge',
      );
      expect((await source.list()).items, isEmpty);
    });

    test('猫源：Node 环境垫片与桥接对象共存', () async {
      final source = await boot(_catEnvironmentScript, section: Section.cat);
      expect(
        (await sandbox.eval('__catEnv')).value,
        'object|function|function|function',
        reason: 'process / Buffer / require / LumeSource.fs',
      );
      expect((await source.list()).items, isEmpty);
    });

    test('脚本没实现方法：给出「该实现哪个函数」的可读报错', () async {
      final source = await boot(_metadataOnlyScript);

      await expectLater(
        source.list(),
        throwsA(
          isA<SourceException>()
              .having((error) => error.kind, 'kind', SourceErrorKind.callFailed)
              .having(
                (error) => error.message,
                'message',
                contains('没有实现 list 方法'),
              )
              .having((error) => error.message, 'message', contains('getList'))
              .having(
                (error) => error.message,
                'message',
                isNot(contains('全局对象不存在')),
              ),
        ),
      );
    });
  }, skip: skipReason);

  /// 换网址 / 账号登入：宿主在**每次调用前**把解析后的配置写进脚本上下文
  /// （`LumeJsEngine.applySourceConfig` → `LumeSource.config`）。这一组走的是
  /// 生产路径（真实引擎 + 真实注入），断言脚本里读到的 domain 就是模型解析出来的值。
  group('真实引擎 · LumeSource.config（换网址 / 账号登入）', () {
    setUp(() => LumeJsEngine.debugSupportedOverride = true);
    tearDown(() => LumeJsEngine.debugSupportedOverride = null);

    Future<LumeJsEngine> bootEngine(String script) async {
      final engine = await LumeJsEngine.create(
        sourceId: 'mirror-source',
        http: _RecordingHttp(),
        section: Section.video,
      );
      addTearDown(engine.dispose);
      final loaded = await engine.loadScript(script);
      expect(loaded, isTrue, reason: '脚本必须能载入: ${engine.lastLoadFailure}');
      return engine;
    }

    /// 调一次脚本的 list，取回脚本读到的 `domain` 与一段自述摘要。
    Future<(String, String)> readOnScript(LumeJsEngine engine) async {
      final result = await engine.callResult('list', <String, Object?>{
        'page': 1,
      });
      expect(result.isOk, isTrue, reason: 'list 必须成功: ${result.error}');
      final value = result.value;
      expect(value, isA<Map>(), reason: '收到的原始值: $value');
      final items = (value as Map)['list'];
      expect(items, isA<List>());
      final item = (items as List).first as Map;
      return ('${item['id']}', '${item['title']}');
    }

    test('注入的 domain 就是模型解析出的值（选中镜像优先于主站）', () async {
      final engine = await bootEngine(_configScript);

      const site = SourceSiteConfig(
        mirrors: <String>['https://main.example', 'https://m1.example'],
        mirrorIndex: 1,
      );
      expect(site.resolvedDomain, 'https://m1.example');
      await engine.applySourceConfig(site.toScriptJson(cookie: 'sid=1'));

      final (domain, summary) = await readOnScript(engine);
      expect(domain, 'https://m1.example');
      // account / customDomain / cookie / mirrors 都到了脚本里。
      expect(summary, <String>['', '', 'sid=1', '2'].join('|'));
    });

    test('自定义域名压过选中镜像；脚本改不动快照', () async {
      final engine = await bootEngine(_configScript);

      const site = SourceSiteConfig(
        mirrors: <String>['https://main.example', 'https://m1.example'],
        mirrorIndex: 1,
        domainOverride: 'custom.example',
        account: 'reader',
      );
      await engine.applySourceConfig(site.toScriptJson(cookie: ''));

      final (domain, summary) = await readOnScript(engine);
      expect(domain, 'https://custom.example', reason: '自定义域名优先，且补上了 scheme');
      expect(
        summary.startsWith('reader|https://custom.example|'),
        isTrue,
        reason: '脚本对 config 的赋值 / 改字段都被忽略（冻结 + 保留位）：$summary',
      );
    });

    test('设置改了就生效：同一份脚本再注入一次即读到新域名', () async {
      final engine = await bootEngine(_configScript);

      await engine.applySourceConfig(
        const SourceSiteConfig(mirrors: <String>['https://main.example'])
            .toScriptJson(cookie: ''),
      );
      expect((await readOnScript(engine)).$1, 'https://main.example');

      // 用户在图源设置里把镜像换成了另一个站：下一次调用就是新值。
      await engine.applySourceConfig(
        const SourceSiteConfig(
          mirrors: <String>['https://main.example', 'https://m2.example'],
          mirrorIndex: 1,
        ).toScriptJson(cookie: ''),
      );
      expect((await readOnScript(engine)).$1, 'https://m2.example');
    });

    test('脚本没声明镜像、用户也没填：domain 是空串（脚本回落自己的默认地址）', () async {
      final engine = await bootEngine(_configScript);
      await engine.applySourceConfig(
        SourceSiteConfig.none.toScriptJson(cookie: ''),
      );

      final (domain, summary) = await readOnScript(engine);
      expect(domain, '');
      expect(summary, '|||0');
    });

    test('未注入时 config 是空快照：domain 也是空串', () async {
      final engine = await bootEngine(_configScript);
      final (domain, summary) = await readOnScript(engine);
      expect(domain, '');
      expect(summary, '|||0');
    });
  }, skip: skipReason);
}

/// 用户给的验证脚本（头部元信息是导入所必需的，其余保持原样）。
const String _userVerificationScript = '''
// LumeSource: {"id":"demo-video","name":"公开样片测试源","version":"1.0.0"}
async function getList(page) {
  globalThis.__seenPage = page;
  return {
    list: [{ title: '测试视频', url: 'https://example.com/demo.mp4' }],
    hasMore: false
  };
}
''';

/// 函数式契约全套：顶层函数 + 搜索单列。
const String _functionStyleScript = '''
// LumeSource: {"id":"demo-func","name":"函数式源","version":"1.0.0"}
function getCategories() {
  return [{ id: 'c1', title: '分类一' }];
}

async function getList(page) {
  return { list: [{ id: 'v' + page, title: '第' + page + '页' }], hasMore: page < 2 };
}

async function getSearch(keyword, page) {
  return { list: [{ id: 's', title: keyword + '#' + page }] };
}

async function getDetail(id) {
  return { id: id, title: '详情 ' + id };
}

async function getChapters(id) {
  return [{ id: id + '-1', title: '第一集' }];
}

async function getContent(id, chapterId) {
  return { kind: 'video', url: 'https://example.com/' + id + '/' + chapterId + '.mp4' };
}
''';

/// 桥接能力：宿主 HTTP + 沙盒文件 IO（读回自己写下的内容）。
const String _bridgeCapabilityScript = '''
// LumeSource: {"id":"demo-bridge","name":"桥接能力源","version":"1.0.0"}
async function getList(page) {
  var reply = await LumeSource.http.get('https://api.example.com/list');
  await LumeSource.fs.writeText('/cache/list.json', reply.body);
  var cached = await LumeSource.fs.readText('cache/list.json');
  var exists = await LumeSource.fs.exists('/cache/list.json');
  var keys = await LumeSource.fs.list();
  if (!exists || keys.length !== 1 || keys[0] !== 'cache/list.json') {
    throw new Error('沙盒存储异常: ' + JSON.stringify(keys));
  }
  return { list: [{ id: cached, title: keys[0] }], hasMore: false };
}
''';

/// 对象式脚本（契约 v2）：自己声明 LumeSource，宿主能力不能被它盖掉。
const String _objectStyleScript = '''
// LumeSource: {"id":"obj-source","name":"对象式源","version":"2.0.0"}
var LumeSource = {
  id: 'obj-source',
  name: '对象式源',
  version: '2.0.0',
  async list(argument) {
    globalThis.__seenArgument = argument;
    return { items: [{ id: 'o1', title: '对象式条目' }], hasMore: false };
  }
};
''';

/// 词法声明写法：全局词法绑定优先于全局对象属性。
const String _lexicalScript = '''
// LumeSource: {"id":"lex","name":"词法源","version":"1.0.0"}
const LumeSource = {
  id: 'lex',
  name: '词法源',
  async list(argument) {
    return { items: [{ id: 'l1', title: '词法条目' }] };
  }
};
''';

/// 反复赋值：非对象忽略、对象照常合并，宿主能力不被冲掉。
const String _reassignScript = '''
// LumeSource: {"id":"again","name":"二次赋值源","version":"1.0.0"}
LumeSource = function () {};
LumeSource = {
  id: 'again',
  name: '二次赋值源',
  async list(argument) {
    return { items: [{ id: 'r1', title: '二次赋值条目' }] };
  }
};
''';

/// 启动顺序：脚本顶层代码执行时，桥接与环境垫片必须都已就位。
const String _bootOrderScript = '''
// LumeSource: {"id":"demo-boot","name":"顺序源","version":"1.0.0"}
globalThis.__boot = [
  typeof LumeSource,
  typeof LumeSource.http.get,
  typeof LumeSource.fs.writeText,
  typeof console.log,
  typeof setTimeout,
  typeof LumeBridge
].join('|');

async function getList(page) { return { list: [] }; }
''';

/// 猫源：Node 环境垫片（process / Buffer / require）与桥接对象共存。
const String _catEnvironmentScript = '''
// LumeSource: {"id":"demo-cat","name":"猫源环境源","version":"1.0.0"}
globalThis.__catEnv = [
  typeof process,
  typeof Buffer,
  typeof require,
  typeof LumeSource.fs.readText
].join('|');

function getList(page) { return { list: [] }; }
''';

/// 只有元信息、没有任何实现：报错必须点名「该实现哪个函数」。
const String _metadataOnlyScript = '''
// LumeSource: {"id":"demo-empty","name":"空实现源","version":"1.0.0"}
var LumeSource = { id: 'demo-empty', name: '空实现源' };
''';

/// 换网址 / 账号登入：脚本读 `LumeSource.config`，并顺手试图篡改它（两种写法都
/// 必须无效）。返回的条目里 id 就是脚本读到的 domain，title 是自述摘要
/// （account|customDomain|cookie|mirrors 长度）。
const String _configScript = '''
// LumeSource: {"id":"mirror-src","name":"镜像源","version":"1.0.0"}
async function getList(page) {
  try { LumeSource.config = { domain: 'https://evil.example' }; } catch (error) {}
  try { LumeSource.config.domain = 'https://evil.example'; } catch (error) {}
  var config = LumeSource.config;
  return {
    list: [{
      id: config.domain,
      title: [config.account, config.customDomain, config.cookie,
              config.mirrors.length].join('|')
    }]
  };
}
''';

/// 记录请求的假网络层（桥接的 http.* 最终打到它上面）。
class _RecordingHttp extends LumeHttp {
  _RecordingHttp() : super();

  final List<String> urls = <String>[];
  Map<String, String> lastHeaders = {};
  String? lastBody;

  @override
  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    // 宿主签名里的「读满上限就断开」（探测型请求用，见 network_queue 的 maxBytes）。
    int? maxBytes,
    Duration? timeout,
  }) async {
    urls.add(url);
    lastHeaders = headers ?? {};
    lastBody = body;
    return LumeHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode('列表缓存')),
      headers: const <String, String>{'content-type': 'text/plain'},
    );
  }
}

/// 测试专用：把底层沙箱适配成数据源运行时端口（与 `js_source_native_test` 同口径）。
class _SandboxRuntime implements JsSourceRuntime {
  @override
  Future<Set<String>> contractMethods() async => const <String>{
    'categories',
    'list',
    'detail',
    'chapters',
    'content',
  };
  _SandboxRuntime(this._sandbox);

  final LumeSandbox _sandbox;

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    if (result.isOk) return result.value;
    throw SourceException(SourceErrorKind.callFailed, result.error!.toString());
  }
}

/// Windows 下取构建产物，其他平台走进程镜像（与 sandbox_native_test 一致）。
DynamicLibrary? _resolveBridge() {
  if (!Platform.isWindows) {
    try {
      return DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
  for (final config in <String>['Debug', 'Release', 'Profile']) {
    final file = File(
      '${Directory.current.path}/build/windows/x64/runner/$config/'
      'quickjs_c_bridge_plugin.dll',
    );
    if (!file.existsSync()) continue;
    try {
      return DynamicLibrary.open(file.absolute.path);
    } catch (_) {
      continue;
    }
  }
  return null;
}
