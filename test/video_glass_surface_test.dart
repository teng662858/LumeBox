import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/player_settings_panel.dart';
import 'package:lume_box/shared/widgets/native_glass_surfaces.dart';
import 'package:lume_box/shared/widgets/video_glass_surface.dart';

void main() {
  testWidgets('面板恢复选项底色，普通菜单仍透明', (tester) async {
    for (final filled in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoGlassSurface(
            filledOptions: filled,
            child: const ChoiceChip(
              key: Key('option'),
              label: Text('选项'),
              selected: true,
            ),
          ),
        ),
      );
      final colors = Theme.of(tester.element(find.byKey(const Key('option'))))
          .chipTheme
          .color!;
      for (final states in [
        <WidgetState>{},
        {WidgetState.selected},
      ]) {
        final color = colors.resolve(states)!;
        expect(color.a, filled ? greaterThan(0) : 0);
      }
    }
  });

  testWidgets('玻璃保留背景冷暖颜色，文字图标不参与模糊和透明度', (tester) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Center(
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 300,
              height: 140,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Row(
                    children: [
                      Expanded(child: Container(color: Colors.red)),
                      Expanded(child: Container(color: Colors.blue)),
                    ],
                  ),
                  const VideoGlassSurface(
                    child: Center(child: Text('清晰文字', key: Key('foreground'))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final foreground = find.byKey(const Key('foreground'));
    expect(
      find.ancestor(of: foreground, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(
      find.ancestor(of: foreground, matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      find.ancestor(of: foreground, matching: find.byType(ImageFiltered)),
      findsNothing,
    );
    expect(
      DefaultTextStyle.of(tester.element(foreground)).style.color,
      VideoGlassSurface.foreground,
    );
    expect(Theme.of(tester.element(foreground)).brightness, Brightness.light);
    await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final left = (70 * 300 + 40) * 4, right = (70 * 300 + 260) * 4;
        expect(bytes.getUint8(left), greaterThan(bytes.getUint8(right) + 30));
        expect(
          bytes.getUint8(right + 2),
          greaterThan(bytes.getUint8(left + 2) + 30),
        );
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets('高对比度使用清晰底色，嵌套面板不叠加多层玻璃', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: Center(
            child: VideoGlassSurface(
              child: SizedBox(
                width: 300,
                height: 80,
                child: VideoGlassSurface(child: Text('设置')),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: DanmakuPanelFrame(
              child: VideoGlassSurface(child: Text('设置')),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单条目共用单个玻璃底座，保持线路选择和返回结果', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<String>(
              key: const Key('menu'),
              color: Colors.transparent,
              elevation: 0,
              menuPadding: EdgeInsets.zero,
              onSelected: (value) => selected = value,
              itemBuilder: (_) => videoGlassMenuEntries<String>([
                const CheckedPopupMenuItem(
                  value: 'a',
                  checked: true,
                  child: Text('线路A'),
                ),
                const PopupMenuItem(value: 'b', child: Text('线路B')),
              ]),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tap(find.text('线路B'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(find.byType(VideoGlassSurface), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('二三级设置和对话框保持透明底层，关闭返回仍正常', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPlayerSettingsPanel<void>(
                context: context,
                builder: (_) => Builder(
                  builder: (context) => PlayerSettingsScaffold(
                    title: '设置',
                    body: TextButton(
                      onPressed: () => showGlassDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('确认'),
                          content: const Text('保持清晰'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('弹出确认'),
                    ),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, Colors.transparent);
    await tester.tap(find.text('弹出确认'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(
      DefaultTextStyle.of(tester.element(find.text('保持清晰'))).style.color,
      VideoGlassSurface.foreground,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('弹出确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
