import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/source/source_import_flow.dart';
import 'package:lume_box/features/source/source_import_selection.dart';

void main() {
  testWidgets('导入前默认不选，支持只选一个源以及取消', (tester) async {
    List<SourceImportItem>? result;
    const items = [
      SourceImportItem(script: 'a', label: '甲源'),
      SourceImportItem(script: 'b', label: '乙源'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await chooseSourceImports(context, items);
              },
              child: const Text('添加'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('乙源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 1 个'));
    await tester.pumpAndSettle();
    expect(result!.single.label, '乙源');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
