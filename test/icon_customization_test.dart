import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/icon_catalog.dart';
import 'package:lume_box/core/theme/icon_customization.dart';
import 'package:lume_box/features/settings/icon_library_page.dart';
import 'package:lume_box/features/video/player_control_glyph.dart';
import 'package:lume_box/shared/widgets/lume_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final store = IconCustomization.instance;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume-icons-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await store.resetForTesting();
    await store.boot();
  });
  tearDown(() async {
    await store.resetForTesting();
    root.deleteSync(recursive: true);
  });

  // Start file writes in the real async zone as well as awaiting them there.
  // Waiting outside FakeAsync cannot drain IO futures created inside it.
  Future<void> changeIcons(WidgetTester tester, void Function() change) async {
    await tester.runAsync(() async {
      change();
      await store.flush();
    });
  }

  test('catalog has unique constant IDs and default navigation slots before visiting pages', () {
    expect(builtInIcons.length, greaterThan(300));
    expect(builtInIcons.map((e) => e.id).toSet().length, builtInIcons.length);
    expect(iconSlots.map((e) => e.id).toSet().length, iconSlots.length);
    expect(iconSlots.any((s) => s.id == 'dock.novel.normal'), isTrue);
    expect(iconSlots.any((s) => s.id == 'dock.video.selected'), isTrue);
    final pause = store.slotKey('player.stroke', Icons.pause, true);
    expect(store.slots.singleWhere((s) => s.id == pause).name, '全屏 · 暂停');
  });

  test('changes before startup finishes persist and restoring does not resurrect saved choices', () async {
    store.set('dock.novel.normal', const IconChoice('ios.heart'));
    store.set('dock.cat.normal', const IconChoice('ios.star'));
    await store.flush();
    await store.resetForTesting();
    store.set('dock.novel.normal', null);
    store.set('dock.video.selected', const IconChoice('ios.heart'));
    await store.flush();
    final reopened = IconCustomization();
    await reopened.boot();
    expect(reopened.choice('dock.novel.normal'), isNull);
    expect(reopened.choice('dock.cat.normal')?.id, 'ios.star');
    expect(reopened.choice('dock.video.selected')?.id, 'ios.heart');
    reopened.dispose();
    await store.resetForTesting();
    store.resetAll();
    await store.flush();
    expect(store.overrides, isEmpty);
    expect(
      jsonDecode(
        File('${root.path}/custom_icons.json').readAsStringSync(),
      )['overrides'],
      isEmpty,
    );
  });

  test('import validates merged limits atomically and rejects unsupported versions', () async {
    Map<String, Object?> pack(int start, int end) => {
      'format': 'lumebox-icons',
      'version': 1,
      'images': [],
      'overrides': {
        for (var i = start; i < end; i++) 'slot.$i': {'id': 'ios.heart'},
      },
    };
    await store.importPack(jsonEncode(pack(0, 1500)));
    final before = store.exportPack();
    await expectLater(
      store.importPack(jsonEncode(pack(1500, 3001))),
      throwsFormatException,
    );
    expect(store.exportPack(), before);
    final unknown = pack(0, 1)..['version'] = 2;
    await expectLater(
      store.importPack(jsonEncode(unknown)),
      throwsFormatException,
    );
    expect(store.exportPack(), before);
  });

  testWidgets(
    'library searches and filters changed slots without building the whole catalog',
    (tester) async {
      await changeIcons(
        tester,
        () => store.set('dock.novel.normal', const IconChoice('ios.heart')),
      );
      await tester.pumpWidget(const MaterialApp(home: IconLibraryPage()));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.enterText(
        find.byKey(const Key('icons.search')),
        'dock.novel',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('icon-slot:dock.novel.normal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('icon-slot:dock.novel.selected')),
        findsOneWidget,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('icon-slot:dock.novel.selected')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('icons.edit-mode')));
      await tester.pumpAndSettle();
      expect(store.editMode, isTrue);
    },
  );

  testWidgets(
    'picker scrolls on narrow screens with large text and an open keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 240),
              ),
              child: child!,
            ),
            home: const IconPickerPage(
              slot: 'dock.novel.normal',
              original: Icons.menu_book_outlined,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const Key('icons.picker-search')),
          'no-matching-icon',
        );
        await tester.pumpAndSettle();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(find.text('没有找到图标，试试其他关键词或导入自己的图片。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
  test('each item and selected state stay independent; restart persists choices but ends edit mode', () async {
    store.set('dock.novel.normal', const IconChoice('ios.heart'));
    store.set('dock.video.selected', const IconChoice('ios.star'));
    store.setEditMode(true);
    await store.flush();
    final reopened = IconCustomization();
    await reopened.boot();
    expect(reopened.choice('dock.novel.normal')?.id, 'ios.heart');
    expect(reopened.choice('dock.novel.selected'), isNull);
    expect(reopened.choice('dock.video.selected')?.id, 'ios.star');
    expect(reopened.editMode, isFalse);
    reopened.dispose();
    store.set('dock.novel.normal', null);
    expect(store.choice('dock.novel.normal'), isNull);
    expect(store.choice('dock.video.selected'), isNotNull);
  });

  testWidgets(
    'changing only the drawn icon preserves tap, semantics and dimensions',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IconButton(
              tooltip: '原按钮功能',
              onPressed: () => taps++,
              icon: const LumeIcon(
                Icons.search,
                slot: 'test.search',
                size: 28,
                semanticLabel: '搜索',
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(IconButton));
      await changeIcons(
        tester,
        () => store.set('test.search', const IconChoice('ios.heart')),
      );
      await tester.pump();
      final glyph = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(LumeIcon),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(
        (glyph.text as TextSpan).text,
        String.fromCharCode(
          store.glyph(const IconChoice('ios.heart'))!.codePoint,
        ),
      );
      expect(tester.getRect(find.byType(IconButton)), rect);
      await tester.tap(find.byTooltip('原按钮功能'));
      expect(taps, 1);
      expect(find.bySemanticsLabel('搜索'), findsOneWidget);
    },
  );

  testWidgets(
    'long press edits only in explicit edit mode; normal long press is retained',
    (tester) async {
      var originalLongPress = 0;
      final edits = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppIconEditingScope(
            onEdit: (_, id, _) => edits.add(id),
            child: Scaffold(
              body: TextButton(
                onPressed: () {},
                onLongPress: () => originalLongPress++,
                child: const LumeIcon(Icons.search, slot: 'test.edit'),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(LumeIcon));
      expect(originalLongPress, 1);
      expect(edits, isEmpty);
      store.setEditMode(true);
      await tester.pump();
      await tester.longPress(find.byType(LumeIcon));
      expect(originalLongPress, 1);
      expect(edits, ['test.edit']);
    },
  );

  testWidgets(
    'fullscreen hand-painted player controls can be replaced and restored',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlayerControlGlyph(Icons.pause)),
        ),
      );
      final original = find.byType(PlayerControlGlyph);
      final size = tester.getSize(original);
      final key = store.slotKey('player.stroke', Icons.pause, true);
      await changeIcons(
        tester,
        () => store.set(key, const IconChoice('ios.heart')),
      );
      await tester.pump();
      expect(tester.getSize(original), size);
      expect(
        find.descendant(of: original, matching: find.byType(RichText)),
        findsOneWidget,
      );
      await changeIcons(tester, () => store.set(key, null));
      await tester.pump();
      expect(
        find.descendant(of: original, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'picker searches, previews, applies one item and restores its default',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editAppIcon(
                  context,
                  'dock.novel.normal',
                  Icons.menu_book_outlined,
                ),
                child: const Text('更换'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => tester.tap(find.text('更换')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('icons.picker-search')),
        'ios.heart',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('icon-choice:ios.heart')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('icons.apply')));
        await store.flush();
      });
      await tester.pumpAndSettle();
      expect(store.choice('dock.novel.normal')?.id, 'ios.heart');
      await tester.runAsync(() => tester.tap(find.text('更换')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('icons.restore')));
        await store.flush();
      });
      await tester.pumpAndSettle();
      expect(store.choice('dock.novel.normal'), isNull);
    },
  );

  testWidgets(
    'self-contained image pack survives export/import and deletion restores default',
    (tester) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 640, 320),
          Paint()..color = Colors.blue,
        );
      expect(canvas, isNotNull);
      final picture = recorder.endRecording();
      final bytes = (await tester.runAsync(() async {
        final image = await picture.toImage(640, 320);
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
        return data;
      }))!;
      final imported = await tester.runAsync(
        () => store.importImage(XFile.fromData(bytes, path: '自己的蓝色图标.png')),
      );
      expect(imported, isNotNull);
      final header = ByteData.sublistView(imported!.bytes);
      expect([header.getUint32(16), header.getUint32(20)], [256, 128]);
      final duplicate = await tester.runAsync(
        () => store.importImage(XFile.fromData(bytes, path: '自己的蓝色图标.png')),
      );
      expect(duplicate!.id, imported.id);
      expect(store.images, hasLength(1));
      await changeIcons(
        tester,
        () => store.set('test.image', IconChoice(imported.id, tint: true)),
      );
      final pack = store.exportPack();
      await tester.runAsync(store.resetForTesting);
      await tester.runAsync(() => store.importPack(pack));
      expect(store.choice('test.image')!.tint, isTrue);
      expect(store.images.single.name, '自己的蓝色图标');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LumeIcon(
              Icons.search,
              slot: 'test.image',
              size: 28,
              color: Colors.red,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).color, Colors.red);
      await changeIcons(tester, () => store.deleteImage(imported.id));
      await tester.pump();
      expect(store.choice('test.image'), isNull);
      expect(find.byType(Image), findsNothing);
    },
  );

  test('invalid import is atomic and corrupt saved customization falls back safely', () async {
    store.set('dock.novel.normal', const IconChoice('ios.heart'));
    final before = store.exportPack();
    final bad = jsonDecode(before) as Map<String, dynamic>;
    bad['overrides'] = {
      'test.invalid': {'id': 'unavailable'},
    };
    await expectLater(store.importPack(jsonEncode(bad)), throwsFormatException);
    expect(store.exportPack(), before);
    await store.flush();
    final file = File('${root.path}/custom_icons.json');
    file.writeAsStringSync('broken');
    final reopened = IconCustomization();
    await reopened.boot();
    expect(reopened.overrides, isEmpty);
    reopened.dispose();
  });
}
