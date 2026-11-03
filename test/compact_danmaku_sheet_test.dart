import 'package:lume_box/features/video/danmaku/danmaku_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings_sheet.dart';

void main() {
  testWidgets('来源页提供本集弹幕预览和空结果说明', (tester) async {
    Future<void> show(List<DanmakuItem> preview) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DanmakuSettingsSheet(
            settings: const DanmakuSettings(),
            onChanged: (_) {},
            preview: preview,
          ),
        ),
      ),
    );
    await show(const []);
    await tester.pumpAndSettle();
    expect(find.text('本集弹幕预览'), findsOneWidget);
    expect(find.textContaining('本集暂无可预览的弹幕'), findsOneWidget);
    await show(const [DanmakuItem(time: Duration(seconds: 65), text: '测试弹幕')]);
    await tester.pumpAndSettle();
    expect(find.text('01:05  测试弹幕'), findsOneWidget);
    expect(find.textContaining('本集暂无可预览的弹幕'), findsNothing);
  });

  testWidgets(
    'landscape source controls fit in one page and remain actionable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(344, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var matched = 0, reloads = 0, services = 0, clears = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuSettingsSheet(
              settings: const DanmakuSettings(),
              onChanged: (_) {},
              videoTitle: '燃烧吧！爸爸',
              episodeTitle: '蓝光',
              danmakuCount: 128,
              sourceCount: 28,
              publicCount: 100,
              matchLabel: '测试作品第 1 集',
              status: '已加载本集弹幕',
              onMatch: () => matched++,
              onReload: () => reloads++,
              onConfigureService: () => services++,
              onClearMatch: () => clears++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['匹配公共弹幕', '重新加载本集', '弹幕服务', '清除本集关联，重新匹配']) {
        expect(tester.getRect(find.text(label)).bottom, lessThanOrEqualTo(390));
        await tester.tap(find.text(label));
      }
      expect([matched, reloads, services, clears], [1, 1, 1, 1]);
      expect(tester.takeException(), isNull);
    },
  );
}
