import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/music/music_page.dart';
import 'package:lume_box/shared/widgets/global_search_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lume-music-page-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    await MusicLibrary.instance.load();
  });
  tearDownAll(() async {
    await root.delete(recursive: true);
  });
  testWidgets(
    'music tabs, empty states, global search and import dialog survive a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var searched = false;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(),
            home: GlobalSearchScope(
              onSearch: () => searched = true,
              child: const MusicPage(),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('先添加 MusicFree 或 LX 音乐源，再开始搜索。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('global-search-button')));
      expect(searched, true);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.text('我的收藏'), findsOneWidget);
      await tester.tap(find.text('音乐源'));
      await tester.pumpAndSettle();
      expect(find.text('优先音质'), findsOneWidget);
      await tester.tap(find.byTooltip('添加音乐源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('脚本 / 订阅链接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://example.com/source.js',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
