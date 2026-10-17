import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

void main() {
  for (final columns in [1, 2]) {
    testWidgets('cat site kinds keep separate sections, columns=$columns', (
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
      expect(
        find.byKey(const ValueKey('cat-picker-group-video')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cat-picker-group-comic')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cat-picker-group-novel')),
        findsNothing,
      );
      expect(find.byType(SourceIcon), findsNWidgets(3));
      expect(find.byType(GridView), findsNothing);
      final first = tester.getRect(find.byKey(const ValueKey('v1')));
      final second = tester.getRect(find.byKey(const ValueKey('v2')));
      final comic = tester.getRect(find.byKey(const ValueKey('c1')));
      expect(first.left, second.left);
      expect(second.top, greaterThan(first.bottom));
      if (columns == 2) {
        expect(comic.top, first.top);
        expect(comic.left - first.right, 10);
      } else {
        expect(comic.top, greaterThan(second.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
