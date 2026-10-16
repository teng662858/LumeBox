import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';

import '../tool/source_management_preview.dart';

Color? labelColor(WidgetTester tester, Finder chip) => tester
    .widget<RichText>(
      find.descendant(of: chip, matching: find.byType(RichText)).first,
    )
    .text
    .style
    ?.color;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness: actual rendered chip colors resolve after style merging',
      (tester) async {
        var selected = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(brightness: brightness),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    ChoiceChip(
                      label: const Text('choice'),
                      selected: selected,
                      onSelected: (value) => setState(() => selected = value),
                    ),
                    FilterChip(
                      label: const Text('filter'),
                      selected: selected,
                      onSelected: (value) => setState(() => selected = value),
                    ),
                    const Chip(label: Text('plain')),
                    ActionChip(label: const Text('action'), onPressed: () {}),
                    InputChip(
                      label: const Text('input'),
                      selected: selected,
                      onSelected: (value) => setState(() => selected = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        for (final type in [
          ChoiceChip,
          FilterChip,
          Chip,
          ActionChip,
          InputChip,
        ]) {
          expect(
            labelColor(tester, find.byType(type)),
            LumeTheme.chipIdleForeground,
          );
        }
        await tester.tap(find.text('choice'));
        await tester.pumpAndSettle();
        for (final type in [ChoiceChip, FilterChip, InputChip]) {
          expect(labelColor(tester, find.byType(type)), Colors.white);
        }
        expect(
          labelColor(tester, find.byType(Chip)),
          LumeTheme.chipIdleForeground,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'comic source management preview filters stay readable when switching',
    (tester) async {
      await tester.pumpWidget(const SourceManagementPreview());
      await tester.pumpAndSettle();
      for (final label in ['全部', '已启用', '异常']) {
        final chip = find.widgetWithText(ChoiceChip, label);
        expect(chip, findsOneWidget);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(labelColor(tester, chip), Colors.white);
        for (final other in [
          '全部',
          '已启用',
          '异常',
        ].where((value) => value != label)) {
          expect(
            labelColor(tester, find.widgetWithText(ChoiceChip, other)),
            LumeTheme.chipIdleForeground,
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
}
