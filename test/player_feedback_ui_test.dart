import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/compact_browse_header.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';

void main() {
  for (final landscape in [false, true]) {
    testWidgets('选集面板可定位当前、正倒序切换并保持真实集序 $landscape', (tester) async {
      await tester.binding.setSurfaceSize(
        landscape ? const Size(900, 430) : const Size(430, 900),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capture = Platform.environment['LUME_CAPTURE_PREVIEW'] == '1';
      if (capture && Platform.isWindows) {
        await tester.runAsync(() async {
          final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
          await (FontLoader(
            'PreviewChinese',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          await (FontLoader(
            'Ahem',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          final icons = await File(
            'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes();
          await (FontLoader(
            'MaterialIcons',
          )..addFont(Future.value(ByteData.sublistView(icons)))).load();
        });
      }
      var selected = -1;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build().copyWith(
            textTheme: LumeTheme.build().textTheme.apply(
              fontFamily: capture ? 'PreviewChinese' : null,
            ),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              backgroundColor: const Color(0xFF25303D),
              body: PlayerSourceSheet(
                address: 'https://fixture.invalid/video.mp4',
                onSelectQuality: (_) {},
                currentChapterId: '160',
                qualities: [
                  VideoQuality(
                    label: '线路一',
                    url: Uri.parse('https://fixture.invalid/a'),
                  ),
                  VideoQuality(
                    label: '线路二',
                    url: Uri.parse('https://fixture.invalid/b'),
                  ),
                ],
                loadEpisodes: () async => List.generate(
                  200,
                  (i) => SourceChapter(id: '${i + 1}', title: '第${i + 1}集'),
                ),
                onSelectEpisode: (index) async {
                  selected = index;
                  return false;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('共 200 集'), findsOneWidget);
      await tester.tap(find.byTooltip('定位当前'));
      await tester.pumpAndSettle();
      expect(find.text('第160集'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '第160集'))
            .selected,
        isTrue,
      );
      if (capture) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('.cache/feedback-preview').create(recursive: true);
          await File(
            '.cache/feedback-preview/episodes-${landscape ? 'landscape' : 'portrait'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('正序'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('定位当前'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第160集'));
      await tester.pumpAndSettle();
      expect(selected, 159);
      expect(find.text('切集失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('搜索与底栏联动缩小、恢复及隐藏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ShellDockController();
    addTearDown(controller.dispose);
    var collapsed = false;
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return ShellDockScope(
              controller: controller,
              searchBesideDock: true,
              collapsed: collapsed,
              child: Scaffold(
                body: Stack(children: [BrowseSearchButton(onPressed: () {})]),
              ),
            );
          },
        ),
      ),
    );
    final surface = find.byKey(const ValueKey('browse-search-surface'));
    final expanded = tester.getSize(surface);
    refresh(() => collapsed = true);
    await tester.pumpAndSettle();
    expect(tester.getSize(surface).width, lessThan(expanded.width));
    expect(tester.getSize(surface).width, tester.getSize(surface).height);
    refresh(() => collapsed = false);
    await tester.pumpAndSettle();
    expect(tester.getSize(surface), expanded);
    controller.hide('player');
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
