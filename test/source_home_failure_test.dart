import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/source_home_view.dart';
import 'package:lume_box/features/shell/section_preloader.dart';
import 'package:lume_box/shared/widgets/state_view.dart';

void main() {
  setUp(() => SectionPreloader.discard(Section.video));
  tearDown(() => SectionPreloader.discard(Section.video));
  final cases = <(String, String, bool)>[
    ('首页没有解析到板块（站点改版了？）', '页面内容未能识别', false),
    ('Failed host lookup: example.test', '站点地址无法解析', true),
    ('NEED_WEBVIEW_VERIFY：站点返回验证页', '站点需要网页验证', true),
    ('请求失败 HTTP 403', '网络异常', true),
    ('执行超时：home', '请求超时', true),
    ('TypeError: parse is not a function', '首页加载失败', false),
  ];
  for (final (message, title, webView) in cases) {
    testWidgets('首页诊断 $title 保留原始原因及重试', (tester) async {
      final source = _FailOnceSource(message);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceHomeView(
              source: source,
              pipeline: null,
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.textContaining(message), findsOneWidget);
      expect(find.text('网页视图'), webView ? findsOneWidget : findsNothing);
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('重试后的测试条目'), findsOneWidget);
      expect(source.calls, 2);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('短屏长错误可滚动到重试，按钮不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceHomeView(
            source: _FailOnceSource('首页没有解析到板块\n${'原始错误详情\n' * 40}'),
            pipeline: null,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的测试条目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('公共状态卡为解析失败提供说明并保留原始错误', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SourceStateView(
            state: SourceStateKind.pageUnrecognized,
            detail: '未解析到正文',
          ),
        ),
      ),
    );
    expect(find.text('页面内容未能识别'), findsOneWidget);
    expect(find.textContaining('可能是页面结构变化'), findsOneWidget);
    expect(find.textContaining('未解析到正文'), findsOneWidget);
  });
}

class _FailOnceSource extends MockDataSource implements HomeCapable {
  _FailOnceSource(this.message) : super(section: Section.video);
  final String message;
  int calls = 0;
  @override
  Future<bool> supportsHome() async => true;
  @override
  Future<SourceHome> home() async {
    if (calls++ == 0) {
      throw SourceException(SourceErrorKind.callFailed, message);
    }
    return const SourceHome(
      items: [SourceItem(id: 'test', title: '重试后的测试条目')],
    );
  }
}
