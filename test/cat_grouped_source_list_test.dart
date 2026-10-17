import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

void main() {
  for (final columns in [1, 2]) {
    testWidgets('cat all kinds share one continuous panel, columns=$columns', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CatGroupedSourceList(
                columns: columns,
                sites: const [
                  CatSite(
                    subscriptionId: 's',
                    key: 'v1',
                    name: '视频甲',
                    api: '',
                    kind: 'video',
                  ),
                  CatSite(
                    subscriptionId: 's',
                    key: 'c1',
                    name: '漫画甲',
                    api: '',
                    kind: 'comic',
                  ),
                  CatSite(
                    subscriptionId: 's',
                    key: 'v2',
                    name: '视频乙',
                    api: '',
                    kind: 'video',
                  ),
                ],
                itemBuilder: (context, site) => ListTile(
                  key: ValueKey(site.key),
                  leading: SourceIcon(
                    name: site.name,
                    siteIcon: site.iconUrl,
                    size: 28,
                  ),
                  title: Text(site.name),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final kind in ['video', 'comic', 'novel', 'live']) {
        expect(find.byKey(ValueKey('cat-picker-group-$kind')), findsNothing);
      }
      for (final title in ['视频', '漫画', '小说', '直播']) {
        expect(find.text(title), findsNothing);
      }
      expect(find.byType(SourceIcon), findsNWidgets(3));
      expect(find.byType(GridView), findsNothing);
      expect(find.byType(Scrollable), findsOneWidget);
      final first = tester.getRect(find.byKey(const ValueKey('v1')));
      final second = tester.getRect(find.byKey(const ValueKey('v2')));
      final comic = tester.getRect(find.byKey(const ValueKey('c1')));
      if (columns == 2) {
        expect(comic.top, first.top);
        expect(comic.left - first.right, 10);
        expect(second.left, first.left);
        expect(second.top, greaterThan(first.bottom));
      } else {
        expect(first.left, comic.left);
        expect(comic.top, greaterThan(first.bottom));
        expect(second.top, greaterThan(comic.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
