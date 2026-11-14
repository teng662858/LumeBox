import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';
import 'package:lume_box/features/search/global_search_page.dart';

void main() {
  const results = GlobalSearchResults(
    content: [
      GlobalContentHit(
        section: Section.comic,
        hit: SearchHit(
          sourceId: 'comic',
          sourceName: 'Comic source',
          item: SourceItem(id: '1', title: 'Comic result'),
        ),
      ),
      GlobalContentHit(
        section: Section.video,
        hit: SearchHit(
          sourceId: 'video',
          sourceName: 'Video source',
          item: SourceItem(id: '2', title: 'Video result'),
        ),
      ),
      GlobalContentHit(
        section: Section.cat,
        kind: 'video',
        hit: SearchHit(
          sourceId: 'cat',
          sourceName: 'Cat source',
          item: SourceItem(id: '3', title: 'Cat result'),
        ),
      ),
    ],
    music: [
      MusicTrack(
        pluginId: 'music',
        id: '4',
        title: 'Music result',
        artist: 'Artist',
      ),
    ],
    failures: ['Unavailable source'],
  );
  testWidgets(
    'one query returns cross-board results; filters retain all results without another request',
    (tester) async {
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: GlobalSearchPage(
            search: (query) async {
              queries.add(query);
              return results;
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      for (final title in [
        'Comic result',
        'Video result',
        'Cat result',
        'Music result',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('1 项搜索未完成'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '音乐'));
      await tester.pumpAndSettle();
      expect(find.text('Music result'), findsOneWidget);
      expect(find.text('Comic result'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '视频'));
      await tester.pumpAndSettle();
      expect(find.text('Video result'), findsOneWidget);
      expect(find.text('Cat result'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      expect(find.text('Comic result'), findsOneWidget);
      expect(queries, ['test']);
    },
  );
  testWidgets('a slow superseded request cannot replace a newer query', (
    tester,
  ) async {
    final first = Completer<GlobalSearchResults>(),
        second = Completer<GlobalSearchResults>();
    await tester.pumpWidget(
      MaterialApp(
        home: GlobalSearchPage(
          search: (query) => query == 'first' ? first.future : second.future,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'first');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'second');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    second.complete(results);
    await tester.pumpAndSettle();
    first.complete(const GlobalSearchResults());
    await tester.pumpAndSettle();
    expect(find.text('Comic result'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
