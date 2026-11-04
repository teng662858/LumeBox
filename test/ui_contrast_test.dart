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
    'custom accent preserves exact fill while text and controls stay legible',
    () {
      const chosen = Color(0xFFFF2D55);
      for (final brightness in Brightness.values) {
        final theme = LumeTheme.build(
          brightness: brightness,
          customAccent: chosen,
        );
        final colors = theme.extension<LumeAccentColors>()!;
        expect(colors.fill, chosen);
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          chosen,
        );
        expect(
          theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
          colors.onFill,
        );
        expect(
          theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
          chosen,
        );
        expect(
          theme.switchTheme.thumbColor!.resolve({WidgetState.selected}),
          Colors.white,
        );
        expect(theme.sliderTheme.activeTrackColor, chosen);
        expect(theme.chipTheme.selectedColor, chosen);
        expect(
          LumeTheme.contrast(colors.onFill, chosen),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LumeTheme.contrast(theme.colorScheme.primary, LumeTheme.surfaceAlt),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          AppearanceSettings(
            useCustomAccent: true,
            customAccentArgb: 0xFFFF2D55,
          ).accentColorFor(brightness),
          chosen,
        );
      }
      LumeTheme.build();
    },
  );
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
    test('$brightness: typography defines readable sizes and weights', () {
      final updated = LumeTheme.readableTextTheme(brightness);
      for (final style in [
        updated.bodyLarge,
        updated.bodyMedium,
        updated.bodySmall,
        updated.titleLarge,
        updated.titleMedium,
        updated.titleSmall,
        updated.labelLarge,
        updated.labelMedium,
        updated.labelSmall,
      ]) {
        expect(style, isNotNull);
        expect(style!.fontSize, isNotNull);
        expect(style.fontSize!, inInclusiveRange(11, 32));
        expect(style.fontWeight, isNotNull);
      }
      // 正文 / 小标题 / 说明文字的关键字号（与 LumeTypography 同一套口径）。
      expect(updated.bodyMedium!.fontSize, 14);
      expect(updated.titleSmall!.fontSize, 16);
      expect(updated.labelSmall!.fontSize, 12);
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
          final card = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('picker-card-two')),
          );
          final decoration = card.decoration as BoxDecoration;
          expect(
            decoration.color,
            brightness == Brightness.dark
                ? LumeTheme.surfaceAlt
                : LumeTheme.surface,
          );
          expect(decoration.boxShadow, isNotEmpty);
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
