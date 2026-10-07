import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/js/venera_bridge.dart';
import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';

import '../support/demo_site.dart';
import 'support/js_sandbox_support.dart';

/// Venera 兼容层的端到端验证：**Venera 源脚本不改一行**，在漫画板块导入即可用。
///
/// 覆盖三件事：
/// 1. 元信息与板块自报：类里的 key/name/version 变成图源身份，板块自报为漫画
///    （所以导入小说板块会被既有校验拦下）；
/// 2. 契约映射：explore / search / loadInfo / loadEp 各自翻译到
///    分类 / 列表 / 详情 / 章节 / 图片，返回值形状按本项目契约归一；
/// 3. 能力边界：支持项（Network、loadData/saveData、Convert.md5、HtmlDocument
///    子集）真的能用；未支持项（sha256、登录）给出**点名到能力**的可读错误。
///
/// 原生桥缺失时整组跳过（Windows 需先 `flutter build windows`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  HttpOverrides? savedOverrides;
  late Directory root;
  late DemoSite site;

  /// 脚本里的 BASE_URL 指到本地示例站点（等价于用户填自己的站点地址）。
  String scriptFor(String file) => fixture(file).replaceFirst(
        "var BASE_URL = 'http://127.0.0.1:8080';",
        "var BASE_URL = '${site.baseUrl}';",
      );

  Future<DataSource> importAndOpen(String file, Section section) async {
    await ensureSectionScope(section);
    final manager = LumeSources.manager(section);
    final result = await manager.importScript(scriptFor(file));
    expect(result.isSuccess, isTrue, reason: result.message ?? '导入应成功');
    final source = await LumeSources.open(section, result.descriptor!.id);
    expect(source, isNotNull, reason: '导入后应能打开数据源');
    return source!;
  }

  setUp(() async {
    enableEngineOnThisPlatform();
    // 本组用例要连本机回环上的示例站点：先摘掉 flutter_test 的「一律 400」替身。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('lume_box_venera');
    await installTempSectionRoot(root);
    site = await DemoSite.start();
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    await site.stop();
    HttpOverrides.global = savedOverrides;
    LumeNet.closeSharedClientForTesting();
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('脚本识别（纯 Dart）', () {
    test('读出 `class X extends ComicSource` 的类名', () {
      final script = fixture('venera_demo_json.js');
      expect(VeneraScriptSource.looksVenera(script), isTrue);
      expect(VeneraScriptSource.classNameOf(script), 'VeneraDemoJson');
      expect(
        VeneraScriptSource.classNameOf(fixture('venera_demo_html.js')),
        'VeneraDemoHtml',
      );
      // 我们自己的契约脚本不该被误认成 Venera 源。
      expect(
        VeneraScriptSource.looksVenera(fixture('demo_comic_source.js')),
        isFalse,
      );
      expect(VeneraScriptSource.classNameOf('var x = 1;'), isNull);
    });
  });

  group('JSON 型 Venera 源：导入即可用', () {
    test(
      '元信息取自类字段，板块自报为漫画',
      () async {
        await ensureSectionScope(Section.comic);
        final manager = LumeSources.manager(Section.comic);
        final result = await manager.importScript(scriptFor('venera_demo_json.js'));

        expect(result.isSuccess, isTrue, reason: result.message ?? '');
        expect(result.descriptor!.id, 'venera-demo-json');
        expect(result.descriptor!.name, 'Venera 示例源（JSON）');
        expect(result.descriptor!.version, '1.0.0');

        // 跨板块导入照样被拦：垫片把板块自报写成了 comic。
        await ensureSectionScope(Section.novel);
        final novel = LumeSources.manager(Section.novel);
        final rejected =
            await novel.importScript(scriptFor('venera_demo_json.js'));
        expect(rejected.isSuccess, isFalse, reason: 'Venera 源属于漫画，不许进小说板块');
        expect(rejected.message, contains('跨板块'));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '分类（explore）/ 列表 / 搜索 / 详情 / 章节 / 图片 全链路',
      () async {
        final source =
            await importAndOpen('venera_demo_json.js', Section.comic);

        // 分类来自 explore 的标题（Venera 的首页就是个列表页）。
        final categories = await source.categories();
        expect(categories, hasLength(1));
        expect(categories.first.title, '最新');
        final exploreId = categories.first.id;

        // 列表：走 explore.load(page) → {comics, maxPage}。
        final list = await source.list(categoryId: exploreId, page: 1);
        expect(list.items, isNotEmpty);
        expect(list.items.first.title, contains('示例小说 1'));
        expect(list.items.first.cover, startsWith(site.baseUrl));
        expect(list.hasMore, isTrue, reason: 'maxPage=3，第 1 页后面还有');

        final lastPage = await source.list(categoryId: exploreId, page: 3);
        expect(lastPage.hasMore, isFalse, reason: '到 maxPage 就没有下一页了');

        // 搜索：走 search.load(keyword, options, page)。
        final searched = await source.list(keyword: '剑');
        expect(searched.items.first.title, contains('搜索：剑'));
        expect(
          site.queries.any((query) => query['keyword'] == '剑'),
          isTrue,
          reason: '关键词要真的发到站点',
        );

        // 详情：loadInfo → {title, cover, description, tags, chapters: {id: 标题}}。
        final detail = await source.detail('12');
        expect(detail?.title, '示例漫画 12');
        expect(detail?.description, isNotNull);
        expect(detail?.subtitle, '连载中 · 示例站', reason: 'tags 的第一组拼成副标题');

        // 章节：映射里的 key 就是章节 id。
        final chapters = await source.chapters('12');
        expect(chapters.map((item) => item.id), containsAll(<String>['ch-1', 'ch-2']));
        expect(chapters.first.title, '第 1 话');

        // 正文：loadEp → {images} → 本项目的图片内容。
        final content = await source.content(itemId: '12', chapterId: 'ch-1');
        expect(content, isA<ImageContent>());
        final images = (content! as ImageContent).images;
        expect(images, hasLength(3));
        expect(images.first, startsWith(site.baseUrl));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

  });

  group('HTML 型 Venera 源：HtmlDocument 子集', () {
    test(
      '列表页用 querySelectorAll 抓取，详情与图片走 JSON',
      () async {
        final source =
            await importAndOpen('venera_demo_html.js', Section.comic);

        final categories = await source.categories();
        expect(categories.first.title, '列表页');

        final list = await source.list(categoryId: categories.first.id, page: 1);
        expect(list.items, hasLength(2), reason: '列页面上的两条');
        expect(list.items.first.id, '12');
        expect(list.items.first.title, '示例漫画 A', reason: '标题取自 img 的 alt');
        expect(
          list.items.first.cover,
          startsWith(site.baseUrl),
          reason: '相对地址要补成绝对地址',
        );

        final chapters = await source.chapters('12');
        expect(chapters, hasLength(2));

        final content = await source.content(itemId: '12', chapterId: 'ch-1');
        expect((content! as ImageContent).images, hasLength(3));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  /// 驱动脚本里的探针方法。
  ///
  /// 探针不是五个契约方法之一——垫片会把**实例自己的方法一并挂到桥接全局**
  /// （见 `venera_bridge.dart` 的认领段），因此这里用同一条调用链拿得到，
  /// 与将来的可选能力（如弹幕）走的是同一条路。
  Future<Map<Object?, Object?>> callProbe(
    String file,
    String method, {
    Object? arguments,
  }) async {
    final engine = await openEngine(
      sourceId: 'venera-probe-$method',
      script: scriptFor(file),
      section: Section.comic,
    );
    addTearDown(engine.dispose);
    final result = await engine.callResult(method, arguments);
    expect(result.isOk, isTrue, reason: result.error?.message ?? '探针调用失败');
    return result.value! as Map<Object?, Object?>;
  }

  group('getter 读设置的源：认领不得执行 getter（真机 MH18 崩溃的回归）', () {
    /// 真机实测：18漫画（venera-configs 的 mh18.js）导入报
    /// 「Venera 源认领失败（MH18）：TypeError: not a function」。
    /// 根因在兼容层的认领段——它用 `typeof instance[name] === 'function'`
    /// 遍历「脚本自己的方法」，那一句会把属性**读出来**，于是
    /// `get baseUrl() { return 'https://' + this.loadSetting('domains') }`
    /// 被顺带执行；而当时垫片里没有 loadSetting → TypeError → 整份源认领失败。
    ///
    /// 两条都要守住：① 认领只挂**数据属性里的函数**（不碰 getter）；
    /// ② `loadSetting` 同步可用（脚本在 getter 里直接调它）。
    test(
      '导入成功且元信息正确（原先是认领失败）',
      () async {
        await ensureSectionScope(Section.comic);
        final manager = LumeSources.manager(Section.comic);
        final result =
            await manager.importScript(scriptFor('venera_getter_settings.js'));

        expect(result.isSuccess, isTrue, reason: result.message ?? '导入应成功');
        expect(result.descriptor!.id, 'venera-getter-settings');
        expect(result.descriptor!.name, 'Venera 夹具（getter 设置）');
        expect(result.descriptor!.version, '1.0.0');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'getter 求值正常：loadSetting 同步给出声明 default，未声明的键为 null',
      () async {
        final value = await callProbe('venera_getter_settings.js', 'probeRead');
        expect(
          value['domains'],
          'example.com',
          reason: '没保存过时应回落到脚本声明的 default',
        );
        expect(
          value['baseUrl'],
          'https://example.com',
          reason: 'getter 里同步用 loadSetting，认领后必须能正常求值',
        );
        expect(value['missing'], isNull, reason: '未声明的键不应抛错');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'saveSetting 之后：同会话内读回新值，getter 跟着变',
      () async {
        final value = await callProbe(
          'venera_getter_settings.js',
          'probeSave',
          arguments: <String, Object?>{'value': 'saved.example'},
        );
        expect(value['after'], 'saved.example');
        expect(value['baseUrl'], 'https://saved.example');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('兼容层的能力边界（如实报错，不假装支持）', () {
    test(
      'HtmlDocument：类 / 属性 / id 选择器可用，伪类明确报错',
      () async {
        final value = await callProbe('venera_demo_html.js', 'probeSelectors');
        expect(value['matched'], '甲,乙', reason: '.a 命中两个');
        expect(value['attributeText'], '乙', reason: '[data-x="2"] 精确匹配');
        expect(value['idText'], '丙', reason: '#id 匹配');
        expect(
          value['unsupported'],
          allOf(contains('暂不支持'), contains('nth-child')),
          reason: '伪类要明确报错，并点名是哪个选择器',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'Convert.md5 走宿主实现（标准向量）；sha256 / 登录点名报错；沙盒存储可读写',
      () async {
        // 同一个引擎里：先读一次详情（脚本会 saveData），再跑探针读回来。
        final engine = await openEngine(
          sourceId: 'venera-probe-detail',
          script: scriptFor('venera_demo_json.js'),
          section: Section.comic,
        );
        addTearDown(engine.dispose);
        await engine.callResult('detail', <String, Object?>{'id': '12'});

        final result = await engine.callResult('probe');
        expect(result.isOk, isTrue, reason: result.error?.message ?? '');
        final value = result.value! as Map<Object?, Object?>;

        expect(
          value['md5'],
          '900150983cd24fb0d6963f7d28e17f72',
          reason: 'md5("abc") 的标准向量：由宿主 Dart 实现算出来',
        );
        expect(
          value['unsupported'],
          allOf(contains('尚未接入'), contains('sha256')),
          reason: '未接入的算法要指名道姓',
        );
        expect(
          value['loginError'],
          allOf(contains('尚未接入'), contains('login')),
          reason: '账号能力未接入：调用即报可读错误',
        );
        expect(value['hasHtmlDocument'], isTrue);
        expect(
          value['cached'],
          '12',
          reason: 'loadData 读回同一引擎里 saveData 写进沙盒存储的值',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
