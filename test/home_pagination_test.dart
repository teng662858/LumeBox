import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/source_home_view.dart';

class _Home extends Fake implements DataSource, HomeCapable {
  _Home(this.section, {this.id = 'paged', this.repeat = false});
  @override
  final Section section;
  @override
  final String id;
  @override
  String get name => id;
  final bool repeat;
  final pages = <int>[];
  bool fail = false;
  Completer<SourceList>? pending;
  @override
  Future<bool> supportsHome() async => true;
  @override
  Future<SourceHome> home() async => const SourceHome(
    items: [SourceItem(id: 'recommended', title: '推荐条目')],
  );
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    pages.add(page);
    if (fail) {
      fail = false;
      throw StateError('temporary');
    }
    if (pending != null) return pending!.future;
    if (repeat) {
      return const SourceList(
        items: [SourceItem(id: 'recommended', title: '推荐条目')],
        hasMore: true,
      );
    }
    return page == 1
        ? const SourceList(
            items: [
              SourceItem(id: 'recommended', title: '推荐条目'),
              SourceItem(id: 'new1', title: '目录第一页'),
            ],
            hasMore: true,
          )
        : const SourceList(
            items: [SourceItem(id: 'new2', title: '目录第二页')],
            hasMore: false,
          );
  }
}

class _Cat extends CatService {
  _Cat() : super.testing();
  final requests = <String>[];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> call(
    CatSite site,
    String operation, [
    Map<String, dynamic> body = const {},
  ]) async {
    if (operation == 'home') {
      return {
        'class': [
          {'type_id': 'a', 'type_name': 'A'},
          {'type_id': 'b', 'type_name': 'B'},
        ],
        'list': [
          {'vod_id': 'recommend', 'vod_name': '推荐'},
        ],
      };
    }
    final category = '${body['id']}', page = body['page'] as int;
    requests.add('$category:$page');
    if (fail) {
      fail = false;
      throw StateError('temporary');
    }
    return {
      'page': page,
      'pagecount': category == 'a' ? 2 : 1,
      'list': [
        {'vod_id': '$category$page', 'vod_name': '$category$page'},
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => BrowseLayoutSettings.instance.resetForTesting());
  Future<void> pump(WidgetTester tester, _Home source) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceHomeView(
            source: source,
            pipeline: null,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final section in [Section.comic, Section.video]) {
    testWidgets(
      '${section.id} recommendations continue from catalog page one and deduplicate overlaps',
      (tester) async {
        final source = _Home(section);
        await pump(tester, source);
        expect(source.pages, isEmpty);
        await tester.tap(find.text('继续浏览站点内容'));
        await tester.pumpAndSettle();
        expect(source.pages, [1, 2]);
        expect(find.text('推荐条目'), findsOneWidget);
        expect(find.text('目录第一页'), findsOneWidget);
        expect(find.text('目录第二页'), findsOneWidget);
        expect(find.text('已显示本源返回的内容'), findsOneWidget);
      },
    );
  }
  testWidgets('a source ignoring page numbers stops after one repeated page', (
    tester,
  ) async {
    final source = _Home(Section.video, repeat: true);
    await pump(tester, source);
    await tester.tap(find.text('继续浏览站点内容'));
    await tester.pumpAndSettle();
    expect(source.pages, [1, 2]);
    expect(find.text('推荐条目'), findsOneWidget);
  });
  testWidgets(
    'failed continuation retains recommendations and retries the same page',
    (tester) async {
      final source = _Home(Section.video)..fail = true;
      await pump(tester, source);
      await tester.tap(find.text('继续浏览站点内容'));
      await tester.pumpAndSettle();
      expect(source.pages, [1]);
      expect(find.text('推荐条目'), findsOneWidget);
      await tester.tap(find.text('加载更多失败，点击重试'));
      await tester.pumpAndSettle();
      expect(source.pages, [1, 1, 2]);
      expect(find.text('目录第二页'), findsOneWidget);
    },
  );
  testWidgets('switching a source cancels and ignores late catalog responses', (
    tester,
  ) async {
    final first = _Home(Section.video)..pending = Completer<SourceList>();
    await pump(tester, first);
    await tester.tap(find.text('继续浏览站点内容'));
    await tester.pump();
    final second = _Home(Section.video, id: 'second');
    await pump(tester, second);
    first.pending!.complete(
      const SourceList(
        items: [SourceItem(id: 'old', title: '旧源迟到内容')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧源迟到内容'), findsNothing);
    expect(second.pages, isEmpty);
  });
  test('TVBox recommendations continue through each real category without skipping page one', () async {
    final service = _Cat();
    final source = CatDataSource(
      service,
      const CatSite(
        subscriptionId: 'test',
        key: 'site',
        name: 'Test',
        api: '/site',
      ),
    );
    expect((await source.homeList()).hasMore, true);
    final titles = <String>[];
    for (var page = 2; page <= 4; page++) {
      final result = await source.homeList(page: page);
      titles.addAll(result.items.map((item) => item.title));
      expect(result.hasMore, page < 4);
    }
    expect(service.requests, ['a:1', 'b:1', 'a:2']);
    expect(titles, ['a1', 'b1', 'a2']);
    expect((await source.homeList(page: 5)).items, isEmpty);
    await service.messages.close();
    service.dispose();
  });
  test(
    'TVBox category continuation retries the same cursor after a failure',
    () async {
      final service = _Cat();
      final source = CatDataSource(
        service,
        const CatSite(
          subscriptionId: 'test',
          key: 'site',
          name: 'Test',
          api: '/site',
        ),
      );
      await source.homeList();
      service.fail = true;
      await expectLater(source.homeList(page: 2), throwsStateError);
      expect((await source.homeList(page: 2)).items.single.title, 'a1');
      expect(service.requests, ['a:1', 'a:1']);
      await service.messages.close();
      service.dispose();
    },
  );
  test('legacy pagination uses metadata and honors explicit end flags', () {
    expect(sourceHasMore({}, page: 1, itemCount: 3), true);
    expect(sourceHasMore({'hasMore': false}, page: 1, itemCount: 30), false);
    expect(sourceHasMore({'hasMore': true}, page: 1, itemCount: 0), false);
    expect(sourceHasMore({'pagecount': '4'}, page: 3, itemCount: 12), true);
    expect(sourceHasMore({'pagecount': 4}, page: 4, itemCount: 12), false);
    expect(
      sourceHasMore({'total': 60, 'pageSize': 20}, page: 3, itemCount: 20),
      false,
    );
  });
}
