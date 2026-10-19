import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/comic/comic_reader_status.dart';
import 'package:lume_box/features/comic/comic_reader_glyphs.dart';

void main() {
  const channel = MethodChannel('lumebox/battery');
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  testWidgets('状态胶囊读取真实电量并按时刷新，后台停止、恢复立即更新', (tester) async {
    var level = 76, reads = 0;
    var now = DateTime(2026, 10, 18, 19, 7);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          reads++;
          return level;
        });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ComicReaderStatus(now: () => now)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('19:07'), findsOneWidget);
    expect(find.text('76%'), findsOneWidget);
    final glyph = find.byKey(const Key('comic.status.batteryGlyph'));
    expect(
      tester.getSize(glyph).width,
      greaterThan(tester.getSize(glyph).height),
    );
    expect(tester.widget<ComicReaderBatteryGlyph>(glyph).level, 76);
    level = 19;
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('19:08'), findsOneWidget);
    expect(find.text('19%'), findsOneWidget);
    final lowBattery = tester.widget<ComicReaderBatteryGlyph>(glyph);
    expect(lowBattery.level, 19);
    expect(lowBattery.color, const Color(0xFFD82D47));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final pausedReads = reads;
    await tester.pump(const Duration(minutes: 2));
    expect(reads, pausedReads);
    now = now.add(const Duration(minutes: 2));
    level = 18;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('19:10'), findsOneWidget);
    expect(find.text('18%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final stoppedReads = reads;
    await tester.pump(const Duration(minutes: 1));
    expect(reads, stoppedReads);
  });

  testWidgets('未知、越界及缺失通道不伪造电量，退出取消在途超时', (tester) async {
    for (final int? value in [null, -1, 101]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => value);
      await tester.pumpWidget(
        MaterialApp(home: ComicReaderStatus(key: ValueKey(value))),
      );
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw MissingPluginException(),
        );
    await tester.pumpWidget(
      const MaterialApp(home: ComicReaderStatus(key: ValueKey('missing'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('—'), findsOneWidget);
    final pending = Completer<int?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    await tester.pumpWidget(
      const MaterialApp(home: ComicReaderStatus(key: ValueKey('pending'))),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(88);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
}
