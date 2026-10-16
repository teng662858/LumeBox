import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';

import 'support/fake_source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fontFile = File('C:/Windows/Fonts/msyhbd.ttc');
    if (!await fontFile.exists()) return;
    final textBytes = await fontFile.readAsBytes();
    final textFont = FontLoader('ContrastQA')
      ..addFont(Future.value(ByteData.sublistView(textBytes)));
    await textFont.load();
    final icons = File(
      'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final iconBytes = await icons.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(iconBytes)))).load();
    }
  });
  tearDown(() => LumeTheme.applyBrightness(Brightness.light));
  test(
    'glass tint stays readable while the opacity slider remains effective',
    () {
      final low = LumeTheme.readableGlass(Colors.white.withValues(alpha: .1));
      final high = LumeTheme.readableGlass(Colors.white.withValues(alpha: .8));
      expect(low.a, greaterThanOrEqualTo(.60));
      expect(high.a, greaterThan(low.a));
    },
  );
  for (final brightness in Brightness.values) {
    test(
      '$brightness: text, card and state contrast across all accent colors',
      () {
        for (final accent in ThemeAccent.values) {
          final theme = LumeTheme.build(brightness: brightness, accent: accent);
          final palette = LumeTheme.palette;
          for (final background in [
            palette.base,
            palette.surface,
            palette.surfaceAlt,
          ]) {
            for (final text in [
              palette.textPrimary,
              palette.textSecondary,
              palette.textHint,
            ]) {
              expect(text.a, 1);
              expect(
                LumeTheme.contrast(text, background),
                greaterThanOrEqualTo(4.5),
              );
            }
          }
          expect(LumeTheme.cardDecoration().border, isNull);
          expect(LumeTheme.cardDecoration().boxShadow, isNotEmpty);
          expect(LumeTheme.background.color, palette.base);
          expect(
            LumeTheme.contrast(palette.accent, palette.surfaceAlt),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LumeTheme.contrast(palette.onAccent, palette.accent),
            greaterThanOrEqualTo(4.5),
          );
          final chip = WidgetStateProperty.resolveAs<TextStyle>(
            theme.chipTheme.labelStyle!,
            {WidgetState.selected},
          );
          expect(
            LumeTheme.contrast(
              WidgetStateProperty.resolveAs<Color>(chip.color!, {
                WidgetState.selected,
              }),
              theme.chipTheme.selectedColor!,
            ),
            greaterThanOrEqualTo(4.5),
          );
          final disabled = theme.filledButtonTheme.style!.foregroundColor!
              .resolve({WidgetState.disabled})!;
          expect(
            LumeTheme.contrast(disabled, palette.surfaceAlt),
            greaterThanOrEqualTo(4.5),
          );
        }
      },
    );
    test('$brightness: typography grows by one point and stays semibold', () {
      final old = ThemeData(
        useMaterial3: true,
        brightness: brightness,
      ).textTheme;
      final updated = LumeTheme.readableTextTheme(brightness);
      for (final pair in [
        (old.bodyLarge, updated.bodyLarge),
        (old.bodyMedium, updated.bodyMedium),
        (old.bodySmall, updated.bodySmall),
        (old.titleLarge, updated.titleLarge),
        (old.titleMedium, updated.titleMedium),
        (old.titleSmall, updated.titleSmall),
        (old.labelLarge, updated.labelLarge),
        (old.labelMedium, updated.labelMedium),
        (old.labelSmall, updated.labelSmall),
      ]) {
        expect(pair.$2!.fontSize, (pair.$1!.fontSize ?? 14) + 1);
        expect(pair.$2!.fontWeight, FontWeight.w600);
      }
    });
    for (final width in [320.0, 390.0]) {
      testWidgets('$brightness: actual source picker at width $width', (
        tester,
      ) async {
        final root = Directory.systemTemp.createTempSync('ui-contrast');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => root.path,
            );
        await tester.runAsync(() => ReadingLibrary.open(Section.video));
        await tester.binding.setSurfaceSize(Size(width, 844));
        const sources = [
          SourceDescriptor(
            id: 'one',
            name: '示例影视',
            version: '1',
            enabled: true,
          ),
          SourceDescriptor(
            id: 'two',
            name: '高清电影与电视剧',
            version: '1',
            enabled: true,
          ),
          SourceDescriptor(
            id: 'three',
            name: '每日更新',
            version: '1',
            enabled: true,
          ),
        ];
        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('contrast-capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: LumeTheme.build(brightness: brightness).copyWith(
                  textTheme: LumeTheme.readableTextTheme(brightness)
                      .apply(fontFamily: 'ContrastQA'),
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => Center(
                      child: FilledButton(
                        onPressed: () => showSourcePicker(
                          context: context,
                          section: Section.video,
                          sources: sources,
                          currentId: 'one',
                          manager: FakeSourceManager(sources: sources),
                        ),
                        child: const Text('选择站点'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('选择站点'));
          await tester.pumpAndSettle();
          expect(find.byType(SourcePickerSheet), findsOneWidget);
          final unselected = tester.widget<Material>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('picker-source-two')),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            unselected.color,
            brightness == Brightness.dark
                ? LumeTheme.surfaceAlt
                : const Color(0xFFF7F8FA),
          );
          expect(unselected.elevation, greaterThan(0));
          expect(tester.takeException(), isNull);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('contrast-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('.cache').create(recursive: true);
            await File(
              '.cache/ui-contrast-source-${brightness.name}-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          await tester.binding.setSurfaceSize(null);
          ReadingLibrary.disposeAll();
          ReadingStore.disposeAll();
          await tester.runAsync(() => SectionScope.closeAll());
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          root.deleteSync(recursive: true);
        }
      });
    }
  }
}
