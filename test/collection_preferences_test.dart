import 'package:lume_box/features/reading/collection_panel.dart';
import 'package:lume_box/shared/widgets/column_list.dart';
import 'package:flutter/material.dart';
import 'package:lume_box/features/reading/history_privacy.dart';

import 'dart:convert';

import 'package:lume_box/core/session/configuration_backup.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/favorite_folders.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_order.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('collection-prefs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  testWidgets(
    'saved double grid becomes a double list with row actions intact',
    (tester) async {
      final library = (await tester.runAsync(
        () => ReadingLibrary.open(Section.novel),
      ))!;
      library.setSetting('collection.history.layout', 'grid2');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 667);
      addTearDown(tester.view.reset);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionPanel(
              title: '历史',
              ids: const ['a', 'b'],
              library: library,
              storageKey: 'collection.history.layout',
              onDelete: (_) async {},
              itemBuilder: (index) => ListTile(
                title: Text('row $index'),
                onTap: () => tapped = true,
              ),
              gridBuilder: (_) => const Text('poster grid'),
            ),
          ),
        ),
      );
      expect(find.byType(ColumnList), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('poster grid'), findsNothing);
      await tester.tap(find.text('row 1'));
      expect(tapped, isTrue);
      await tester.tap(find.byTooltip('显示模式'));
      await tester.pumpAndSettle();
      expect(find.text('双列列表'), findsWidgets);
      expect(find.text('双列网格'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'dragging a filtered subset preserves hidden sources and section isolation',
    () async {
      await ReadingLibrary.open(Section.novel);
      await SourceOrder.move(
        Section.novel,
        ['a', 'hidden', 'b', 'c'],
        ['a', 'b', 'c'],
        0,
        2,
      );
      expect(SourceOrder.read(Section.novel), ['b', 'hidden', 'c', 'a']);
      expect(SourceOrder.read(Section.comic), isEmpty);
      ReadingLibrary.close(Section.novel);
      await ReadingLibrary.open(Section.novel);
      expect(SourceOrder.read(Section.novel), ['b', 'hidden', 'c', 'a']);
    },
  );
  test('folder moves persist, duplicate names are rejected, deleting a folder retains favorites', () async {
    final library = await ReadingLibrary.open(Section.comic);
    library.shelve(sourceId: 's', itemId: 'i', title: '作品');
    final folders = FavoriteFolders(library);
    expect(folders.create('追更'), isTrue);
    expect(folders.create('追更'), isFalse);
    folders.create('看完');
    folders.move('i', '追更');
    folders.move('i', '看完');
    expect(folders.load()['追更'], isEmpty);
    expect(folders.load()['看完'], ['i']);
    folders.remove('看完');
    expect(library.item('i'), isNotNull);
    expect(
      FavoriteFolders(await ReadingLibrary.open(Section.video)).load(),
      isEmpty,
    );
  });
  test(
    'incognito skips progress writes and preserves earlier saved progress',
    () async {
      final library = await ReadingLibrary.open(Section.video);
      library.shelve(sourceId: 's', itemId: 'i', title: '作品');
      VideoProgress at(int seconds) => VideoProgress(
        section: Section.video,
        itemId: 'i',
        chapterIndex: 0,
        chapterId: '1',
        chapterTitle: '1',
        updatedAt: DateTime.now(),
        position: Duration(seconds: seconds),
        duration: const Duration(minutes: 5),
      );
      library.saveProgress(at(10));
      library.setSetting('history.incognito', 'true');
      library.saveProgress(at(90));
      expect(library.videoProgress('i')?.position, const Duration(seconds: 10));
      library.setSetting('history.incognito', 'false');
      library.saveProgress(at(100));
      expect(
        library.videoProgress('i')?.position,
        const Duration(seconds: 100),
      );
    },
  );
  test('configuration backup roundtrips preferences without exporting history locks or cookies', () async {
    final library = await ReadingLibrary.open(Section.novel);
    library.setSetting('reader.fontSize', '22');
    library.setSetting('history.lock', 'secret');
    library.setSetting('waf.cookies.site', 'credential');
    final service = ConfigurationBackup();
    final encoded = await service.export();
    final decoded = jsonDecode(encoded) as Map;
    expect(decoded['sections']['novel']['reader.fontSize'], '22');
    expect(encoded, isNot(contains('credential')));
    expect(encoded, isNot(contains('secret')));
    library.setSetting('reader.fontSize', '16');
    await service.restore(encoded);
    expect(library.setting('reader.fontSize'), '22');
    decoded['files']['../escape.json'] = {};
    await expectLater(
      service.restore(jsonEncode(decoded)),
      throwsFormatException,
    );
    expect(File('${root.parent.path}/escape.json').existsSync(), isFalse);
  });
  testWidgets(
    'locked history hides when leaving the foreground and requires PIN on return',
    (tester) async {
      final library = (await tester.runAsync(
        () => ReadingLibrary.open(Section.video),
      ))!;
      library.setSetting(
        HistoryPrivacy.lockKey,
        'test:${HistoryPrivacy.digest('test', '123456')}',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HistoryPrivacyGuard(
              library: library,
              enabled: true,
              child: const Text('私密历史'),
            ),
          ),
        ),
      );
      expect(find.text('私密历史'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('私密历史'), findsNothing);
      expect(find.text('历史记录已锁定'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('私密历史'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
