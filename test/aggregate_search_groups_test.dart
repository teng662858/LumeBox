import 'package:lume_box/core/source/source_content_rating.dart';
import 'package:lume_box/core/session/privacy_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/search/search_source_filter.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/aggregate_search_results.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';

void main() {
  const sources = [
    SourceDescriptor(
      id: 'js',
      name: 'JS影视',
      version: '1',
      enabled: true,
      contentCategory: 'movie',
    ),
    SourceDescriptor(
      id: 'py',
      name: 'PY影视',
      version: '1',
      enabled: true,
      runtimeKind: 'python',
      contentCategory: 'movie',
    ),
    SourceDescriptor(
      id: 'audio',
      name: '听书站',
      version: '1',
      enabled: true,
      section: Section.comic,
      mediaKind: 'audio',
    ),
    SourceDescriptor(
      id: 'cat',
      name: '猫站',
      version: 'Node',
      enabled: true,
      runtimeKind: 'cat',
      section: Section.video,
      mediaKind: 'video',
    ),
  ];
  test('content and source kinds combine without inferring unknown sources as films', () {
    const filter = SearchSourceFilter(
      content: SearchContentGroup.movie,
      kind: SearchSourceKind.python,
    );
    expect(sources.where(filter.matches).map((s) => s.id), ['py']);
    expect(SearchSourceFilter.contentOf(sources[2]), SearchContentGroup.audio);
    expect(SearchSourceFilter.kindOf(sources[3]), SearchSourceKind.cat);
    expect(
      SearchSourceFilter.kindOf(
        const SourceDescriptor(
          id: 'tvbox_js',
          name: 'TVBOX',
          version: '1',
          enabled: true,
        ),
      ),
      SearchSourceKind.cat,
    );
    expect(
      SearchSourceFilter.kindOf(
        const SourceDescriptor(
          id: 'tvbox_py',
          name: 'Python',
          version: '1',
          enabled: true,
          runtimeKind: 'python',
        ),
      ),
      SearchSourceKind.python,
    );
    expect(SearchSourceFilter.contentOf(sources[3]), SearchContentGroup.movie);
    expect(
      SearchSourceFilter.contentOf(
        const SourceDescriptor(
          id: 'novel',
          name: '站点',
          version: '1',
          enabled: true,
          section: Section.comic,
          group: '小说',
        ),
      ),
      SearchContentGroup.novel,
    );
    const unknown = SourceDescriptor(
      id: 'unknown',
      name: '影视大全',
      version: '1',
      enabled: true,
    );
    expect(SearchSourceFilter.contentOf(unknown), SearchContentGroup.other);
    expect(
      SearchSourceFilter.contentOf(
        const SourceDescriptor(
          id: 'comic',
          name: '漫画',
          version: '1',
          enabled: true,
          section: Section.comic,
        ),
      ),
      SearchContentGroup.comic,
    );
    expect(
      SearchSourceFilter.contentOf(
        const SourceDescriptor(
          id: 'adult',
          name: '站点',
          version: '1',
          enabled: true,
          contentCategory: 'adult',
          runtimeKind: 'python',
        ),
      ),
      SearchContentGroup.adult,
    );
  });
  testWidgets(
    'scope selection applies only checked sites in the selected content and engine',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SearchScopeSelection? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showSearchModeMenu(
                    context,
                    current: SearchMode.aggregate,
                    sources: sources,
                    sitesOnly: true,
                  );
                },
                child: const Text('选源'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选源'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-content-movie')));
      await tester.pumpAndSettle();
      final py = find.byKey(const ValueKey('search-kind-python'));
      await tester.ensureVisible(py);
      await tester.pumpAndSettle();
      await tester.tap(py);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-site-js')), findsNothing);
      expect(find.byKey(const ValueKey('search-site-audio')), findsNothing);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(picked!.sourceIds, {'py'});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('分类筛选不会把隐私设置隐藏的成人源重新加入搜索', (tester) async {
    expect(PrivacySettings.instance.showAdult, false);
    final adult = SourceDescriptor(
      id: SourceContentRating.adultIds.first,
      name: '隐藏站点',
      version: '1',
      enabled: true,
      contentCategory: 'adult',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSearchModeMenu(
                context,
                current: SearchMode.aggregate,
                sources: [adult],
                sitesOnly: true,
              ),
              child: const Text('选源'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选源'));
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('search-content-adult'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('search-site-${adult.id}')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'switching back to single-source mode does not persist an empty aggregate scope',
    (tester) async {
      SearchScopeSelection? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showSearchModeMenu(
                    context,
                    current: SearchMode.aggregate,
                    sources: sources,
                  );
                },
                child: const Text('选源'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选源'));
      await tester.pumpAndSettle();
      final adult = find.byKey(const ValueKey('search-content-adult'));
      await tester.ensureVisible(adult);
      await tester.pumpAndSettle();
      await tester.tap(adult);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(picked!.mode, SearchMode.single);
      expect(picked!.sourceIds, isNull);
    },
  );

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets(
      'result facets filter locally without rerunning search at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var requests = 0;
        SearchHit? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AggregateSearchResults(
                section: Section.video,
                sites: sources,
                hits: [
                  for (final s in sources)
                    SearchHit(
                      sourceId: s.id,
                      sourceName: s.name,
                      item: SourceItem(id: s.id, title: '${s.name}作品'),
                    ),
                ],
                completed: sources.map((s) => s.id).toSet(),
                failed: const {},
                loading: false,
                onOpen: (hit) => opened = hit,
                onRetry: () => requests++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('search-content-movie')));
        await tester.pumpAndSettle();
        final py = find.byKey(const ValueKey('search-kind-python'));
        await tester.ensureVisible(py);
        await tester.pumpAndSettle();
        await tester.tap(py);
        await tester.pumpAndSettle();
        expect(find.text('JS影视作品'), findsNothing);
        expect(find.text('听书站作品'), findsNothing);
        expect(find.text('PY影视作品'), findsOneWidget);
        await tester.ensureVisible(find.text('PY影视作品'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('PY影视作品'));
        await tester.pump();
        expect(opened!.sourceId, 'py');
        expect(requests, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
