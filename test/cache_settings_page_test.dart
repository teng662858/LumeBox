import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/cache_settings_page.dart';

/// 设置 →「缓存管理」：按板块展示与清空**内存缓存**。
///
/// 磁盘缓存（统计 / 清理 / 策略）另有一套用例；这里只验证本轮新增的内存部分：
/// 四个板块各一行、占用如实展示、清空按钮只作用本板块、空板块的按钮置灰。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_cache_page');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    SectionMemoryCache.instance.clearAll();
    // 阅读库在真实时钟里先打开：testWidgets 的 fake-async 里等不到真实异步。
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
  });

  tearDown(() async {
    SectionMemoryCache.instance.clearAll();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const CacheSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按板块展示内存缓存占用，清空只作用本板块', (tester) async {
    SectionMemoryCache.instance
        .write(Section.novel, 'demo', 'categories', <String>['abcd']);
    SectionMemoryCache.instance
        .write(Section.comic, 'demo', 'categories', <String>['abcd']);
    await pumpPage(tester);

    // 四个板块各一行：小说 / 漫画有 1 项，视频 / 猫源为空。
    expect(find.text('内存缓存 1 项 · 16 B'), findsNWidgets(2));
    expect(find.text('内存缓存 空'), findsNWidgets(2));

    // 清空按钮按板块排列（Section.values 顺序）：有内容的可用，空板块的置灰。
    final clears = tester
        .widgetList<TextButton>(find.widgetWithText(TextButton, '清空'))
        .toList(growable: false);
    expect(clears, hasLength(Section.values.length));
    expect(clears[0].onPressed, isNotNull, reason: '小说有缓存，可清空');
    expect(clears[1].onPressed, isNotNull, reason: '漫画有缓存，可清空');
    expect(clears[2].onPressed, isNull, reason: '视频是空的');
    expect(clears[3].onPressed, isNull, reason: '猫源是空的');

    await tester.tap(find.widgetWithText(TextButton, '清空').at(0));
    await tester.pumpAndSettle();

    // 只清掉了小说：漫画的条目原样在。
    expect(SectionMemoryCache.instance.usageOf(Section.novel).isEmpty, isTrue);
    expect(SectionMemoryCache.instance.usageOf(Section.comic).entries, 1);
    expect(find.text('内存缓存 空'), findsNWidgets(3));
    expect(find.textContaining('已清空小说内存缓存'), findsOneWidget);
  });

  testWidgets('空板块点「清空」不可用，不会误报清空', (tester) async {
    await pumpPage(tester);

    expect(find.text('内存缓存 空'), findsNWidgets(Section.values.length));
    final clears = tester
        .widgetList<TextButton>(find.widgetWithText(TextButton, '清空'))
        .toList(growable: false);
    for (final button in clears) {
      expect(button.onPressed, isNull);
    }
  });
}
