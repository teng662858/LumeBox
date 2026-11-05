import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/search/search_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/aggregate_search_results.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';

import 'support/fake_reading_source.dart';

class _FallbackSource extends FakeReadingDataSource {
  _FallbackSource(this.items) : super(section: Section.video);
  final List<SourceItem> items;
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => SourceList(items: items, hasMore: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SearchSettings.instance;
  setUp(() {
    settings.exact = false;
    settings.simplify = true;
  });
  tearDown(() {
    settings.exact = false;
    settings.simplify = true;
  });

  test('burst results coalesce progress while preserving the final complete snapshot', () async {
    final updates = <AggregateSearchProgress>[];
    final result = await AggregateSearch.run(
      sources: [
        for (var i = 0; i < 20; i++)
          SourceDescriptor(
            id: 'site$i',
            name: '站点$i',
            version: '1',
            enabled: true,
          ),
      ],
      open: (_) async =>
          _FallbackSource(const [SourceItem(id: '1', title: '作品')]),
      keyword: '作品',
      onProgress: updates.add,
    );
    expect(result.hits, hasLength(20));
    expect(updates.last.completed, 20);
    expect(updates.last.hits, hasLength(20));
    expect(updates.length, lessThan(5));
  });

  test(
    'aggregate titles must contain the query, including every search term',
    () {
      expect(settings.acceptsAggregate('今日热门推荐', '龙马'), isFalse);
      expect(settings.acceptsAggregate('龍馬 第二部', '龙马'), isTrue);
      expect(settings.acceptsAggregate('斗罗大陆 第二季', '斗罗 大陆'), isTrue);
      expect(settings.acceptsAggregate('斗破苍穹', '斗罗 大陆'), isFalse);
      expect(settings.acceptsAggregate('Spirited Away', 'IT'), isFalse);
      expect(settings.acceptsAggregate('IT 第二章', 'it'), isTrue);
      expect(settings.acceptsAggregate('ＭＡＴＲＩＸ：Reloaded', 'matrix'), isTrue);
      expect(settings.acceptsAggregate('首页推荐', ' !!! '), isFalse);
      expect(settings.acceptsAggregate('', '作品'), isFalse);
      settings.exact = true;
      expect(settings.acceptsAggregate('龙马第二部', '龙马'), isFalse);
    },
  );

  test(
    'recommendations are removed before deduplication, truncation and progress',
    () async {
      final source = _FallbackSource([
        for (var i = 0; i < 35; i++) SourceItem(id: '$i', title: '首页推荐$i'),
        const SourceItem(id: '0', title: '龍馬 第二部'),
      ]);
      final progress = <AggregateSearchProgress>[];
      final result = await AggregateSearch.run(
        sources: const [
          SourceDescriptor(
            id: 'site',
            name: '测试站点',
            version: '1',
            enabled: true,
          ),
        ],
        keyword: '龙马',
        open: (_) async => source,
        onProgress: progress.add,
      );
      expect(result.hits.map((h) => h.item.title), ['龍馬 第二部']);
      expect(result.failed, 0);
      expect(
        progress.expand((p) => p.hits).every((h) => h.item.title == '龍馬 第二部'),
        isTrue,
      );
      final empty = await AggregateSearch.run(
        sources: const [
          SourceDescriptor(
            id: 'site',
            name: '测试站点',
            version: '1',
            enabled: true,
          ),
        ],
        keyword: '不存在的作品',
        open: (_) async => source,
      );
      expect(empty.hits, isEmpty);
      expect(empty.failed, 0);
    },
  );

  testWidgets(
    'finished sites without hits disappear and an emptied selection resets',
    (tester) async {
      Widget scene({required bool done, required List<SearchHit> hits}) =>
          MaterialApp(
            home: Scaffold(
              body: AggregateSearchResults(
                section: Section.video,
                hits: hits,
                sites: const [
                  SourceDescriptor(
                    id: 'match',
                    name: '有结果站点',
                    version: '1',
                    enabled: true,
                  ),
                  SourceDescriptor(
                    id: 'empty',
                    name: '无结果站点',
                    version: '1',
                    enabled: true,
                  ),
                ],
                completed: done ? const {'match', 'empty'} : const {'match'},
                failed: const {},
                loading: !done,
                onOpen: (_) {},
                onRetry: () {},
              ),
            ),
          );
      const hit = SearchHit(
        sourceId: 'match',
        sourceName: '有结果站点',
        item: SourceItem(id: '1', title: '命中作品'),
      );
      await tester.pumpWidget(scene(done: false, hits: [hit]));
      await tester.pump();
      expect(find.byKey(const ValueKey('search-filter-empty')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-filter-empty')));
      await tester.pump();
      await tester.pumpWidget(scene(done: true, hits: [hit]));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-filter-empty')), findsNothing);
      expect(find.byKey(const ValueKey('search-hit-match-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
