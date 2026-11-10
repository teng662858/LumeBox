import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/settings/preload_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('preload-settings-ui-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await MediaPreload.instance.boot(directory: root);
    MediaPreload.instance.update(video: true, audio: true, images: true);
  });
  tearDown(() async {
    MediaPreload.instance.update(video: true, audio: true, images: true);
    await MediaPreload.instance.flush();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('预载设置在 $size 可操作且不溢出，清空历史取消时不改变记录', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final library = await tester.runAsync(
        () => ReadingLibrary.open(Section.video),
      );
      library!.recordHistoryItem(sourceId: 's', itemId: 'keep', title: '保留历史');
      await tester.pumpWidget(const MaterialApp(home: PreloadSettingsPage()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('视频下一集预载'), 150);
      await Scrollable.ensureVisible(
        tester.element(find.text('视频下一集预载')),
        alignment: .3,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频下一集预载'));
      await tester.pump();
      expect(MediaPreload.instance.video, false);
      await tester.scrollUntilVisible(find.text('清空观看与阅读历史'), 200);
      await Scrollable.ensureVisible(
        tester.element(find.text('清空观看与阅读历史')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空观看与阅读历史'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.history().single.itemId, 'keep');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      var flushed = false;
      MediaPreload.instance.flush().then((_) => flushed = true);
      for (var i = 0; i < 50 && !flushed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(flushed, isTrue);
    });
  }
}
