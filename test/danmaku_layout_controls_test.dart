import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/danmaku/danmaku_models.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';
import 'package:lume_box/features/video/danmaku/danmaku_overlay.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings_sheet.dart';

void main() {
  test('行数、半屏、全屏和字幕避让确实限制可用轨道', () {
    const viewport = Size(400, 240);
    for (final rows in [1, 2, 3, 4, 5]) {
      expect(
        DanmakuLayout.laneCount(viewport, DanmakuSettings(rows: rows)),
        rows,
      );
    }
    final half = DanmakuLayout.laneCount(
      viewport,
      const DanmakuSettings(rows: 0, displayArea: .5),
    );
    final full = DanmakuLayout.laneCount(
      viewport,
      const DanmakuSettings(rows: 0, displayArea: 1, avoidSubtitles: false),
    );
    final reserved = DanmakuLayout.laneCount(
      viewport,
      const DanmakuSettings(rows: 0, displayArea: 1),
    );
    expect(full, greaterThan(half));
    expect(reserved, lessThan(full));
  });
  test('新增设置完整往返，屏蔽词与类型过滤按内容生效', () {
    const settings = DanmakuSettings(
      rows: 5,
      lineSpacing: 2,
      bold: false,
      allowColored: false,
      showTop: false,
      showBottom: false,
      maxPerSecond: 2,
      delayMs: -1500,
      mergeDuplicates: false,
      blockedWords: ['剧透'],
      pipEnabled: false,
    );
    final decoded = DanmakuSettings.fromJson(settings.toJson());
    expect(decoded, settings);
    expect(decoded.hashCode, settings.hashCode);
    expect(
      decoded.accepts(const DanmakuItem(time: Duration.zero, text: '剧透结局')),
      false,
    );
    expect(
      decoded.accepts(
        const DanmakuItem(
          time: Duration.zero,
          text: '顶部',
          mode: DanmakuMode.top,
        ),
      ),
      false,
    );
    final style = DanmakuStyle.of(
      const DanmakuItem(time: Duration.zero, text: '白色', color: 0xFF0000),
      decoded,
    );
    expect(style.color.toARGB32() & 0xFFFFFF, 0xFFFFFF);
    expect(style.bold, false);
  });
  final paintFinder = find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_DanmakuPainter',
  );
  Widget view(
    DanmakuSettings settings,
    DanmakuTrack track, {
    Duration position = Duration.zero,
  }) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: 400,
        height: 240,
        child: DanmakuOverlay(
          settings: settings,
          track: track,
          position: position,
          playing: false,
        ),
      ),
    ),
  );
  testWidgets('滚动顶部底部共用轨道，修改排数即时重排', (tester) async {
    final track = DanmakuTrack.parse([
      for (var i = 0; i < 12; i++)
        {
          'time': 0,
          'text': '第$i条',
          'mode': ['scroll', 'top', 'bottom'][i % 3],
        },
    ]);
    await tester.pumpWidget(view(const DanmakuSettings(rows: 3), track));
    dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 3);
    expect(painter.entries.map((dynamic e) => e.lane).toSet().length, 3);
    await tester.pumpWidget(view(const DanmakuSettings(rows: 1), track));
    painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 1);
    expect(painter.entries.first.lane, 0);
  });
  testWidgets('三排紧凑弹幕给末排完整文字和描边留出空间', (tester) async {
    const settings = DanmakuSettings(rows: 3, lineSpacing: 1, strokeWidth: 3);
    final track = DanmakuTrack.parse([
      for (var i = 0; i < 3; i++)
        {'time': 0, 'text': '第$i条🔥', 'mode': 'top', 'fontSize': 2},
    ]);
    await tester.pumpWidget(view(settings, track));
    final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 3);
    final TextPainter text = painter.entries.last.fill;
    expect(
      text.height + settings.strokeWidth,
      lessThanOrEqualTo(DanmakuLayout.rowHeight(settings)),
    );
  });
  testWidgets('每秒限流、重复合并和延迟作用于投放', (tester) async {
    final track = DanmakuTrack.parse([
      for (var i = 0; i < 5; i++) {'time': 0, 'text': '弹幕$i'},
    ]);
    await tester.pumpWidget(
      view(const DanmakuSettings(rows: 5, maxPerSecond: 1), track),
    );
    dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 1);
    await tester.pumpWidget(const SizedBox());
    final duplicates = DanmakuTrack.parse([
      for (var i = 0; i < 5; i++) {'time': 0, 'text': '重复'},
    ]);
    await tester.pumpWidget(view(const DanmakuSettings(rows: 5), duplicates));
    painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view(const DanmakuSettings(delayMs: 1000), track));
    expect(
      (tester.widget<CustomPaint>(paintFinder).painter as dynamic).entries,
      isEmpty,
    );
    await tester.pumpWidget(
      view(
        const DanmakuSettings(delayMs: 1000),
        track,
        position: const Duration(seconds: 1),
      ),
    );
    expect(paintFinder, findsOneWidget);
  });
  testWidgets('三排连续跟随，不必等八秒全部离屏', (tester) async {
    final track = DanmakuTrack.parse([
      for (var i = 0; i < 3; i++) {'time': 0, 'text': '短$i'},
      for (var i = 0; i < 3; i++) {'time': 2000, 'text': '续$i'},
    ]);
    const settings = DanmakuSettings(rows: 3);
    await tester.pumpWidget(view(settings, track));
    await tester.pumpWidget(
      view(settings, track, position: const Duration(seconds: 2)),
    );
    final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(painter.entries.length, 6);
    expect(
      painter.entries.map((dynamic e) => e.lane).toSet().length,
      lessThanOrEqualTo(3),
    );
  });
  testWidgets('同排长弹幕不能追尾短弹幕，固定弹幕仍独占轨道', (tester) async {
    for (final mode in ['scroll', 'top']) {
      final track = DanmakuTrack.parse([
        {'time': 0, 'text': '短', 'mode': mode},
        {'time': 2000, 'text': '很长的后续弹幕不能追上前一条弹幕遮挡文字' * 4},
      ]);
      await tester.pumpWidget(view(const DanmakuSettings(rows: 1), track));
      await tester.pumpWidget(
        view(
          const DanmakuSettings(rows: 1),
          track,
          position: const Duration(seconds: 2),
        ),
      );
      final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter;
      expect(painter.entries.length, 1);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('显示范围选择和高级设置回调包含实际配置', (tester) async {
    DanmakuSettings? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DanmakuSettingsPanel(
              settings: DanmakuSettings.defaults,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('半屏'));
    await tester.tap(find.text('半屏'));
    await tester.pump();
    expect(changed?.rows, 0);
    expect(changed?.displayArea, .5);
    await tester.ensureVisible(find.text('高级设置'));
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('关键词屏蔽'), findsOneWidget);
    expect(find.text('每秒上限'), findsOneWidget);
  });
}
