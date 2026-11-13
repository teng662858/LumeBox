import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/cat/cat_local_bundle.dart';
import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/js/source_engine.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/source_import_input.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_package.dart';
import 'package:lume_box/core/web/html_home_import.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

// Frozen exports come from the desktop tool. App CI validates these bytes without
// invoking the local-only SourceMaker toolchain or its Python dependencies.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  late Directory root;
  late Directory exports;
  late Map<String, dynamic> pages;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lumebox-maker-contract-');
    exports = Directory('test/fixtures/source_maker_exports');
    pages = jsonDecode(
      File('${exports.path}/pages.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    enableEngineOnThisPlatform();
    await installTempSectionRoot(root);
  });
  tearDownAll(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    restoreEnginePlatformGate();
    await root.delete(recursive: true);
  });

  for (final target in ['audio', 'comic', 'images', 'video', 'module']) {
    test('桌面导出 $target：真实导入器、QuickJS 与内容模型', () async {
      final extension = target == 'module' ? 'cjs' : 'js';
      final filename = '$target.$extension';
      final raw = File('${exports.path}/$filename').readAsStringSync();
      final input = SourceImportInput.classify(raw, name: filename);
      expect(input.isScript, isTrue);
      final section = ['audio', 'comic', 'images'].contains(target)
          ? Section.comic
          : Section.video;
      final manager = LumeSources.manager(section);
      final imported = await manager.importScript(input.text);
      expect(imported.isSuccess, isTrue, reason: imported.message);
      final descriptor = imported.descriptor!;
      expect(descriptor.isAudio, target == 'audio');
      expect(
        descriptor.runtimeKind,
        target == 'module' ? 'module' : 'javascript',
      );

      final requests = <Uri>[];
      final engine = await LumeJsEngine.create(
        sourceId: 'maker-$target',
        section: section,
        http: LumeHttp(
          client: MockClient((r) async {
            requests.add(r.url);
            return http.Response(
              pages[r.url.path] as String? ?? 'missing',
              pages.containsKey(r.url.path) ? 200 : 404,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }),
        ),
      );
      addTearDown(engine.dispose);
      final adapter = QuickJsSourceEngine(engine);
      expect(
        await adapter.loadScript(SourcePackage.prepare(input.text)),
        isTrue,
        reason: adapter.loadFailure,
      );
      final source = JsDataSource(
        id: descriptor.id,
        name: descriptor.name,
        section: section,
        runtime: _Runtime(engine),
      );
      final categories = await source.categories();
      expect(categories.last.title, '科普');
      final groups = await source.filters();
      expect(groups.single.id, 'area');
      expect(groups.single.options.last.id, 'cn');
      expect(
        (await source.list(categoryId: categories.last.id)).items,
        isNotEmpty,
      );
      expect(requests.last.path, '/category/science');
      expect((await source.list(filters: {'area': 'cn'})).items, isNotEmpty);
      expect(requests.last.queryParameters['area'], 'cn');
      final list = await source.list();
      expect(list.items.single.title, '测试作品');
      final id = list.items.single.id;
      expect((await source.detail(id))!.title, '作品详情');
      final chapters = await source.chapters(id);
      final content = await source.content(
        itemId: id,
        chapterId: chapters.first.id,
      );
      if (target == 'comic' || target == 'images') {
        expect(content, isA<ImageContent>());
        final image = content as ImageContent;
        expect(
          image.images.single,
          endsWith(target == 'images' ? '/photo.jpg' : '/page.jpg'),
        );
        expect(image.imageHeaders[image.images.single]?['Referer'], isNotEmpty);
      } else {
        expect(content, isA<VideoContent>());
        expect((content as VideoContent).audioOnly, target == 'audio');
        expect(
          content.url.path,
          target == 'audio' ? '/book.mp3' : '/movie.mp4',
        );
      }
    }, skip: available ? false : 'QuickJS 原生桥不可用');
  }

  test('桌面导出 Kazumi：实际 JSON 转换器、API 配置与标签识别', () async {
    final raw = File('${exports.path}/kazumi.json').readAsStringSync();
    final input = SourceImportInput.classify(raw, name: 'kazumi.json');
    expect(input.isScript, isTrue);
    final manager = LumeSources.manager(Section.comic);
    final imported = await manager.importScript(input.text);
    expect(imported.isSuccess, isTrue, reason: imported.message);
    expect(imported.descriptor!.isKazumi, isTrue);
    final engine = await LumeJsEngine.create(
      sourceId: 'maker-kazumi',
      section: Section.comic,
      http: LumeHttp(
        client: MockClient(
          (r) async => http.Response(
            pages['/api'] as String,
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    addTearDown(engine.dispose);
    expect(
      await engine.loadScript(input.text),
      isTrue,
      reason: '${engine.lastLoadFailure}',
    );
    final source = JsDataSource(
      id: 'kazumi',
      name: 'Kazumi',
      section: Section.comic,
      runtime: _Runtime(engine),
    );
    final list = await source.list(keyword: '测试');
    expect(list.items.single.title, '接口作品');
    final id = list.items.single.id;
    expect((await source.detail(id))!.title, '接口作品');
    final chapter = (await source.chapters(id)).single;
    final content =
        await source.content(itemId: id, chapterId: chapter.id) as VideoContent;
    expect(content.url.toString(), 'https://media.invalid/movie.mp4');
    final html = SourceImportInput.classify(
      File('${exports.path}/kazumi-html.json').readAsStringSync(),
      name: 'html.json',
    );
    expect(html.isScript, isTrue);
    expect((await manager.importScript(html.text)).isSuccess, isTrue);
  }, skip: available ? false : 'QuickJS 原生桥不可用');

  test('桌面动态 JS：通过 App 网页渲染桥获取列表与内容', () async {
    const channel = MethodChannel('lumebox/source_web');
    final rendered = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'render') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final url = args['url'] as String;
            rendered.add(url);
            expect(args['script'], contains('document.contentType'));
            final html = pages[Uri.parse(url).path] as String;
            return {'url': url, 'html': html, 'result': html};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final engine = await LumeJsEngine.create(
      sourceId: 'maker-browser',
      section: Section.video,
      http: LumeHttp(
        client: MockClient((_) async => throw StateError('动态源应调用网页渲染桥')),
      ),
    );
    addTearDown(engine.dispose);
    final script = File('${exports.path}/browser.js').readAsStringSync();
    expect(
      await engine.loadScript(script),
      isTrue,
      reason: '${engine.lastLoadFailure}',
    );
    final source = JsDataSource(
      id: 'maker-browser',
      name: '动态测试',
      section: Section.video,
      runtime: _Runtime(engine),
    );
    final item = (await source.list()).items.single;
    expect(item.title, '测试作品');
    expect((await source.detail(item.id))!.title, '作品详情');
    final chapter = (await source.chapters(item.id)).first;
    final content = await source.content(
      itemId: item.id,
      chapterId: chapter.id,
    ) as VideoContent;
    expect(content.url.toString(), 'https://media.invalid/movie.mp4');
    expect(rendered, contains('https://fixture.invalid/chapter/1'));
  }, skip: available ? false : 'QuickJS 原生桥不可用');

  test('桌面导出 PY：真实 SourcePackage 识别 Python 运行环境', () {
    final bytes = File('${exports.path}/python.py').readAsBytesSync();
    final prepared = SourcePackage.fromBytes(bytes, name: 'python.py');
    expect(SourcePackage.kindOf(prepared), SourcePackageKind.python);
    expect(prepared, contains('class Spider:'));
  });

  test('桌面导出猫源：真实 ZIP 解析器与 MD5 校验', () {
    final bundle = CatLocalBundle.fromZip(
      base64Decode(
        File('${exports.path}/cat.zip.base64').readAsStringSync().trim(),
      ),
    );
    expect(utf8.decode(bundle.index), contains('module.exports.start='));
    expect(utf8.decode(bundle.config), contains('module.exports'));
  });

  test('桌面导出网页：真实 HTML 导入器及安全 HTML 内容', () {
    final source = HtmlHomeImport.decode(
      'web.html',
      File('${exports.path}/web.html').readAsBytesSync(),
    );
    expect(source.isLocal, isTrue);
    expect(source.name, '制源测试');
    expect(source.html, contains('https://fixture.invalid/item/1'));
    expect(source.html, isNot(contains('<script')));
  });
}

class _Runtime implements JsSourceRuntime {
  _Runtime(this.engine);
  final LumeJsEngine engine;
  @override
  Future<Object?> call(String method, [Object? argument]) async {
    return engine.call(method, argument);
  }

  @override
  Future<Set<String>> contractMethods() => engine.contractMethods();
}
