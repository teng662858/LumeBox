import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/features/video/player_playback_info.dart';
import 'package:lume_box/features/video/player_hud.dart';
import 'package:lume_box/features/settings/ai_assistant_page.dart';

void main() {
  testWidgets('播放诊断实时更新缓冲，复制时不包含签名地址', (tester) async {
    final stats = ValueNotifier(
      const PlayerStats(buffered: Duration(seconds: 3)),
    );
    final snapshot = ValueNotifier(const PlayerSnapshot(buffering: true));
    addTearDown(stats.dispose);
    addTearDown(snapshot.dispose);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PlayerPlaybackInfo(
                  address: Uri.parse(
                    'https://media.example/test.m3u8?auth_key=private',
                  ),
                  source: '测试源',
                  quality: '1080P',
                  kernel: 'AVPlayer',
                  line: Future.value('线路一'),
                  stats: stats,
                  snapshot: snapshot,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('线路：线路一'), findsOneWidget);
    expect(find.text('已缓冲：3.0 秒'), findsOneWidget);
    stats.value = const PlayerStats(
      buffered: Duration(seconds: 12),
      downloadBytesPerSecond: 1000000,
    );
    await tester.pump();
    expect(find.text('已缓冲：12.0 秒'), findsOneWidget);
    await tester.tap(find.text('AI 诊断'));
    await tester.pumpAndSettle();
    final input = tester
        .widget<AiAssistantPage>(find.byType(AiAssistantPage))
        .input;
    expect(input, contains('已缓冲：12.0 秒'));
    expect(input, isNot(contains('test.m3u8')));
    expect(input, isNot(contains('private')));
    expect(input, isNot(contains('auth_key')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制诊断信息'));
    await tester.pumpAndSettle();
    expect(copied, contains('实际内核：AVPlayer'));
    expect(copied, contains('实时下载：1.0MB/s'));
    expect(copied, isNot(contains('auth_key')));
    expect(copied, isNot(contains('private')));
  });

  testWidgets('实时下载与线路测速区分，缓冲时显示秒数', (tester) async {
    final stats = ValueNotifier(
      const PlayerStats(
        buffering: true,
        buffered: Duration(seconds: 5),
        downloadBytesPerSecond: 1000000,
      ),
    );
    final probe = ValueNotifier<int?>(8000);
    addTearDown(stats.dispose);
    addTearDown(probe.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerStatsInline(
            stats: stats,
            networkKbps: probe,
            showBuffer: true,
          ),
        ),
      ),
    );
    expect(find.text('下载 1.0MB/s'), findsOneWidget);
    expect(find.text('已缓冲 5 秒'), findsOneWidget);
    stats.value = const PlayerStats();
    await tester.pump();
    expect(find.text('线路测速 1.0MB/s'), findsOneWidget);
    expect(find.text('下载 1.0MB/s'), findsNothing);
  });
}
