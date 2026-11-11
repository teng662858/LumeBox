import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/source/source_editor_page.dart';
import 'package:lume_box/features/settings/ai_assistant_page.dart';

void main() {
  testWidgets('PY 编辑保留原文，提供 AI 和导出入口，退出不关闭借用管理器', (tester) async {
    const script = '# LumeRuntime: python\nclass Spider:\n    pass';
    final manager = _Manager();
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: SourceEditorPage(
          section: Section.video,
          manager: manager,
          initialScript: script,
        ),
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      script,
    );
    await tester.tap(find.byTooltip('源工具'));
    await tester.pumpAndSettle();
    expect(find.text('导出源文件'), findsOneWidget);
    await tester.tap(find.text('AI 修复源'));
    await tester.pumpAndSettle();
    final page = tester.widget<AiAssistantPage>(find.byType(AiAssistantPage));
    expect(page.input, script);
    expect(page.applyScript, true);
    expect(find.text('发送并分析'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(manager.closed, false);
  });
}

class _Manager implements SourceManager {
  bool closed = false;
  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
