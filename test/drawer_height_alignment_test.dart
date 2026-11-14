import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/browse_choice_access.dart';
import 'package:lume_box/features/reading/history_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-drawers-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    await root.delete(recursive: true);
  });
  for (final height in [667.0, 844.0]) {
    testWidgets(
      'classification reaches the island while history retains its existing height at $height',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(390, height);
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.reset);
        late BuildContext page;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                page = context;
                return const Scaffold();
              },
            ),
          ),
        );
        unawaited(
          showBrowseFilters(
            context: page,
            categories: const [SourceCategory(id: 'all', title: '全部')],
            groups: const [],
            category: null,
            filters: const {},
          ),
        );
        await tester.pumpAndSettle();
        final bounds = tester.getRect(
          find.byKey(const Key('classification-drawer-frame')),
        );
        expect(bounds.top, 49);
        Navigator.pop(page);
        await tester.pumpAndSettle();
        for (final tab in HistoryDrawerTab.values) {
          unawaited(
            showReadingHistorySheet(
              context: page,
              section: Section.video,
              library: library,
              initialTab: tab,
              onResume: (_, progress) {},
            ),
          );
          await tester.pumpAndSettle();
          final history = tester.getRect(
            find.byKey(const Key('history-drawer-frame')),
          );
          expect(history.top, greaterThan(bounds.top));
          expect(history.bottom, bounds.bottom);
          expect(tester.takeException(), isNull);
          Navigator.pop(page);
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
