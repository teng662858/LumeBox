import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

/// 假运行时：记录调用并返回预设结果。
///
/// 有了它，JS 适配器在没有图源引擎的平台上（Windows / Android）也能被
/// 完整验证：断言方法名、入参裁剪、结果解析与错误归一。
class _FakeRuntime implements JsSourceRuntime {
  _FakeRuntime(this.reply);

  final Future<Object?> Function(String method, Object? argument) reply;
  final List<String> methods = <String>[];
  final List<Object?> arguments = <Object?>[];

  @override
  Future<Object?> call(String method, [Object? argument]) {
    methods.add(method);
    arguments.add(argument);
    return reply(method, argument);
  }
}

void main() {
  group('模拟实现：四个板块共用一套接口', () {
    for (final section in Section.values) {
      test('${section.label}：分类 / 列表 / 详情 / 章节 / 内容', () async {
        final typed = MockDataSource(section: section);
        expect(typed.id, 'lume.mock.${section.id}');
        expect(typed.name, '${section.label}模拟源');
        expect(typed.section, section);

        final categories = await typed.categories();
        expect(categories, isNotEmpty);
        expect(
          categories.map((category) => category.id).toSet().length,
          categories.length,
        );

        final list = await typed.list(categoryId: categories.first.id);
        expect(list.items, isNotEmpty);
        expect(list.hasMore, isTrue, reason: '第一页应还有下一页');
        expect(list.items.first.title, contains(categories.first.title));

        final search = await typed.list(keyword: ' 关键词 ');
        expect(search.items.first.title, contains('搜索 关键词'));

        final detail = await typed.detail(list.items.first.id);
        expect(detail, isNotNull);
        expect(detail!.id, list.items.first.id);
        expect(detail.title, contains(list.items.first.id));
        expect(await typed.detail('   '), isNull);

        final chapters = await typed.chapters('item-1');
        expect(chapters.length, MockDataSource.chapterCount);
        expect(chapters.first.title, '第 1 章');

        final content = await typed.content(
          itemId: list.items.first.id,
          chapterId: chapters.first.id,
        );
        switch (section) {
          case Section.novel:
            expect(content, isA<TextContent>());
          case Section.comic:
            expect(content, isA<ImageContent>());
          case Section.video:
          case Section.cat:
            expect(content, isA<VideoContent>());
        }
      });
    }

    test('页码语义：第一页还有更多，第二页到底', () async {
      const source = MockDataSource(section: Section.novel);
      expect((await source.list(page: 1)).hasMore, isTrue);
      expect((await source.list(page: 2)).hasMore, isFalse);
      expect((await source.list(page: 0)).items.first.id, 'novel-1-1');
    });

    test('失败注入：所有调用都抛 SourceException', () async {
      const source = MockDataSource(section: Section.cat, fail: true);
      await expectLater(source.categories(), throwsA(isA<SourceException>()));
      await expectLater(source.list(), throwsA(isA<SourceException>()));
      await expectLater(source.detail('x'), throwsA(isA<SourceException>()));
      await expectLater(source.chapters('x'), throwsA(isA<SourceException>()));
      await expectLater(
        source.content(itemId: 'x', chapterId: 'y'),
        throwsA(isA<SourceException>()),
      );
    });

    test('延迟可配置：调用仍然正常返回', () async {
      const source = MockDataSource(
        section: Section.novel,
        latency: Duration(milliseconds: 1),
      );
      expect((await source.categories()).length, 3);
    });
  });

  group('JS 适配器：接口语义 → JS 契约', () {
    JsDataSource build(_FakeRuntime runtime) => JsDataSource(
          id: 'demo',
          name: '示例源',
          section: Section.novel,
          runtime: runtime,
        );

    test('分类：无入参，结果按模型解析', () async {
      final runtime = _FakeRuntime((method, argument) async {
        expect(method, JsSourceContract.categories);
        return <Object?>[
          <String, Object?>{'id': 'c1', 'title': '分类一'},
          <String, Object?>{'id': 'c2'},
          'x',
        ];
      });
      final categories = await build(runtime).categories();
      expect(categories.length, 2);
      expect(categories.first.title, '分类一');
      expect(categories.last.title, 'c2');
      expect(runtime.arguments.single, isNull);
    });

    test('列表：空分类与空关键词不进参数，页码归一', () async {
      final runtime = _FakeRuntime((method, argument) async {
        return <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'id': 'a', 'title': '条目 A'},
          ],
          'hasMore': true,
        };
      });
      final result = await build(runtime).list(
        categoryId: '  ',
        keyword: '',
        page: 0,
      );
      expect(result.items.single.id, 'a');
      expect(result.hasMore, isTrue);
      expect(runtime.methods.single, JsSourceContract.list);
      expect(runtime.arguments.single, <String, Object?>{'page': 1});
    });

    test('列表：分类与关键词裁剪后进入参数', () async {
      final runtime = _FakeRuntime(
        (method, argument) async => const <String, Object?>{'items': <Object?>[]},
      );
      await build(runtime).list(categoryId: 'c1', keyword: ' 关键词 ', page: 3);
      expect(runtime.arguments.single, <String, Object?>{
        'page': 3,
        'categoryId': 'c1',
        'keyword': '关键词',
      });
    });

    test('列表：裸数组结果按空信封处理', () async {
      final runtime = _FakeRuntime(
        (method, argument) async => <Object?>[
          <String, Object?>{'id': 'a', 'title': '条目 A'},
        ],
      );
      final result = await build(runtime).list();
      expect(result.items.single.id, 'a');
      expect(result.hasMore, isFalse);
    });

    test('详情：脚本显式返回 null 时得到 null', () async {
      final runtime = _FakeRuntime((method, argument) async => null);
      expect(await build(runtime).detail('a'), isNull);
      expect(runtime.arguments.single, <String, Object?>{'id': 'a'});
    });

    test('章节与内容：入参正确，缺标题回退到 id', () async {
      final runtime = _FakeRuntime((method, argument) async {
        if (method == JsSourceContract.chapters) {
          return <Object?>[
            <String, Object?>{'id': 'ch-1'},
          ];
        }
        return <String, Object?>{
          'kind': 'video',
          'url': 'https://example.invalid/v.mp4',
        };
      });
      final source = build(runtime);

      final chapters = await source.chapters('a');
      expect(chapters.single.title, 'ch-1');
      expect(runtime.arguments.first, <String, Object?>{'id': 'a'});

      final content = await source.content(itemId: 'a', chapterId: 'ch-1');
      expect(content, isA<VideoContent>());
      expect(runtime.arguments.last, <String, Object?>{
        'id': 'a',
        'chapterId': 'ch-1',
      });
    });

    test('内容不符合契约时归一到 callFailed', () async {
      final runtime = _FakeRuntime(
        (method, argument) async => <String, Object?>{'kind': 'pdf'},
      );
      await expectLater(
        build(runtime).content(itemId: 'a', chapterId: 'b'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.kind,
            'kind',
            SourceErrorKind.callFailed,
          ),
        ),
      );
    });

    test('运行时异常归一：SourceException 透传，其余包成 callFailed', () async {
      final passthrough = _FakeRuntime(
        (method, argument) async =>
            throw const SourceException(SourceErrorKind.notFound, '图源不可用'),
      );
      await expectLater(
        build(passthrough).categories(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.kind,
            'kind',
            SourceErrorKind.notFound,
          ),
        ),
      );

      final unexpected = _FakeRuntime(
        (method, argument) async => throw StateError('boom'),
      );
      await expectLater(
        build(unexpected).categories(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.kind,
            'kind',
            SourceErrorKind.callFailed,
          ),
        ),
      );
    });
  });

  group('门面：平台降级', () {
    test('无图源运行时的平台一律降级为空与 null', () async {
      if (Platform.isIOS) return; // 该断言只在没有图源引擎的平台成立
      expect(LumeSources.runtimeAvailable, isFalse);
      expect(await LumeSources.list(Section.novel), isEmpty);
      expect(await LumeSources.open(Section.novel, 'demo'), isNull);

      final imported = await LumeSources.importScript(
        Section.novel,
        'var LumeSource = {};',
      );
      expect(imported.isSuccess, isFalse);
      expect(imported.descriptor, isNull);
      expect(imported.message, contains('图源运行时'));

      await LumeSources.setEnabled(Section.novel, 'demo', false);
      await LumeSources.remove(Section.novel, 'demo');
      LumeSources.close(Section.novel);
    });

    test('管理端口：正式实现在同一平台上给出同一套降级语义', () async {
      if (Platform.isIOS) return;
      final manager = LumeSources.manager(Section.comic);
      expect(manager.runtimeAvailable, isFalse);
      expect(await manager.list(), isEmpty);
      expect(await manager.open('demo'), isNull);
      expect(await manager.current(), isNull);
      expect(await manager.select('demo'), isNull);

      final imported = await manager.importScript('var LumeSource = {};');
      expect(imported.isSuccess, isFalse);
      expect(imported.message, isNotNull);

      await manager.setEnabled('demo', false);
      await manager.remove('demo');
      manager.close();
    });

    test('门面：当前图源在无运行时平台上同样降级', () async {
      if (Platform.isIOS) return;
      expect(await LumeSources.currentSource(Section.novel), isNull);
      expect(await LumeSources.selectSource(Section.novel, 'demo'), isNull);
    });
  });

  /// 读缓存（本轮新增）：分类 / 详情 / 章节按板块进缓存，列表与内容不进。
  ///
  /// 缓存由组合根注入（生产走 [SectionMemoryCache]，测试不传就没有缓存行为），
  /// 因此这里显式传缓存来验证「命中 / 不缓存 / 失败不写 / 清空后重取」四条口径。
  group('读缓存：元数据进缓存，列表与内容不进', () {
    final cache = SectionMemoryCache.instance;

    setUp(cache.clearAll);
    tearDown(cache.clearAll);

    JsDataSource build(_FakeRuntime runtime) => JsDataSource(
          id: 'demo',
          name: '示例源',
          section: Section.novel,
          runtime: runtime,
          cache: cache,
        );

    int callsOf(_FakeRuntime runtime, String method) =>
        runtime.methods.where((name) => name == method).length;

    test('分类：第二次读命中缓存，不再调脚本', () async {
      final runtime = _FakeRuntime((method, argument) async => <Object?>[
            <String, Object?>{'id': 'c1', 'title': '分类一'},
          ]);
      final source = build(runtime);

      expect((await source.categories()).single.title, '分类一');
      expect((await source.categories()).single.title, '分类一');
      expect(callsOf(runtime, JsSourceContract.categories), 1);
      expect(cache.usageOf(Section.novel).entries, 1);
    });

    test('详情与章节按 itemId 分开缓存', () async {
      final runtime = _FakeRuntime((method, argument) async {
        final id = (argument as Map)['id'];
        return switch (method) {
          JsSourceContract.detail => <String, Object?>{
              'id': id,
              'title': '条目 $id',
            },
          JsSourceContract.chapters => <Object?>[
              <String, Object?>{'id': '$id-e1', 'title': '第 1 集'},
            ],
          _ => null,
        };
      });
      final source = build(runtime);

      await source.detail('1');
      await source.detail('1');
      await source.detail('2');
      expect(
        callsOf(runtime, JsSourceContract.detail),
        2,
        reason: '同一个 itemId 第二次命中，换 id 要重新取',
      );

      await source.chapters('1');
      await source.chapters('1');
      expect(callsOf(runtime, JsSourceContract.chapters), 1);
    });

    test('列表与内容永不缓存：每次都走脚本', () async {
      final runtime = _FakeRuntime(
        (method, argument) async => switch (method) {
          JsSourceContract.list => <String, Object?>{
              'items': <Object?>[
                <String, Object?>{'id': 'a', 'title': 'A'},
              ],
            },
          JsSourceContract.content => <String, Object?>{
              'kind': 'video',
              'url': 'https://example.com/a.mp4',
            },
          _ => null,
        },
      );
      final source = build(runtime);

      await source.list();
      await source.list();
      await source.content(itemId: 'a', chapterId: 'a-1');
      await source.content(itemId: 'a', chapterId: 'a-1');

      expect(callsOf(runtime, JsSourceContract.list), 2);
      expect(callsOf(runtime, JsSourceContract.content), 2);
      expect(cache.usageOf(Section.novel).isEmpty, isTrue, reason: '一条都不该进缓存');
    });

    test('失败不进缓存：抛错之后重试仍然走脚本', () async {
      var attempts = 0;
      final runtime = _FakeRuntime((method, argument) async {
        attempts++;
        if (attempts == 1) {
          throw const SourceException(SourceErrorKind.callFailed, '脚本报错');
        }
        return <Object?>[
          <String, Object?>{'id': 'c1', 'title': '分类一'},
        ];
      });
      final source = build(runtime);

      await expectLater(source.categories(), throwsA(isA<SourceException>()));
      expect(cache.usageOf(Section.novel).isEmpty, isTrue, reason: '失败不写缓存');
      expect((await source.categories()).single.title, '分类一');
    });

    test('清空板块缓存后重新走脚本（设置页「清空」的效果）', () async {
      final runtime = _FakeRuntime((method, argument) async => <Object?>[
            <String, Object?>{'id': 'c1', 'title': '分类一'},
          ]);
      final source = build(runtime);

      await source.categories();
      await source.categories();
      expect(callsOf(runtime, JsSourceContract.categories), 1);

      cache.clear(Section.novel);
      await source.categories();
      expect(callsOf(runtime, JsSourceContract.categories), 2);
    });

    test('不传 cache 的适配器（测试与旧调用方）没有缓存行为', () async {
      final runtime = _FakeRuntime((method, argument) async => <Object?>[
            <String, Object?>{'id': 'c1', 'title': '分类一'},
          ]);
      final source = JsDataSource(
        id: 'demo',
        name: '示例源',
        section: Section.novel,
        runtime: runtime,
      );

      await source.categories();
      await source.categories();
      expect(callsOf(runtime, JsSourceContract.categories), 2);
      expect(cache.usageOf(Section.novel).isEmpty, isTrue);
    });
  });
}
