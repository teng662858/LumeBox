import 'package:lume_box/core/session/section_scope.dart';

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/player/playback_health.dart';
import 'package:lume_box/core/intro/intro_models.dart';
import 'package:lume_box/core/intro/repeated_segments.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/experience/tracking_resume.dart';
import 'package:lume_box/features/video/line_performance.dart';
import 'package:lume_box/features/video/player_source_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('诊断区分吞吐不足、已有缓存和内核未提供数据', () {
    const waiting = PlayerSnapshot(playing: true, buffering: true);
    expect(
      PlaybackHealth.describe(waiting, const PlayerStats()),
      contains('足够信息'),
    );
    expect(
      PlaybackHealth.describe(
        waiting,
        const PlayerStats(buffered: Duration(seconds: 8)),
      ),
      contains('解码'),
    );
    expect(
      PlaybackHealth.describe(
        waiting,
        const PlayerStats(
          buffered: Duration(seconds: 1),
          downloadBytesPerSecond: 100000,
          videoBitrateKbps: 3000,
        ),
      ),
      contains('低于媒体码率'),
    );
    expect(
      PlaybackHealth.describe(
        waiting,
        const PlayerStats(),
        operation: '正在解析地址',
      ),
      '正在解析地址',
    );
  });
  test('停滞计时不跨暂停、跳转或换集，并以实际进度为准', () {
    final guard = PlaybackStallGuard();
    final now = DateTime(2026);
    const state = PlayerSnapshot(
      playing: true,
      position: Duration(seconds: 10),
    );
    expect(guard.observe('a', state, now, eligible: true), false);
    expect(
      guard.observe(
        'a',
        state,
        now.add(const Duration(seconds: 14)),
        eligible: true,
      ),
      false,
    );
    expect(
      guard.observe(
        'a',
        state,
        now.add(const Duration(seconds: 15)),
        eligible: true,
      ),
      true,
    );
    guard.observe(
      'a',
      state,
      now.add(const Duration(seconds: 16)),
      eligible: false,
    );
    expect(
      guard.observe(
        'a',
        state,
        now.add(const Duration(seconds: 40)),
        eligible: true,
      ),
      false,
    );
    expect(
      guard.observe(
        'b',
        state,
        now.add(const Duration(seconds: 60)),
        eligible: true,
      ),
      false,
    );
    expect(
      guard.observe(
        'b',
        const PlayerSnapshot(position: Duration(seconds: 11)),
        now.add(const Duration(seconds: 80)),
        eligible: true,
      ),
      false,
    );
  });
  test('同季未打点的连续重复片段可发现，静止台标和短片不判片头', () {
    final random = Random(42);
    String hash() => List.generate(
      2,
      (_) => random.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'),
    ).join();
    final old = [
      for (var i = 0; i < 10; i++)
        <String, Object?>{'at': 30000 + i * 3000, 'p': hash(), 'd': hash()},
    ];
    final frames = [
      for (final f in old)
        <String, Object?>{...f, 'at': (f['at'] as int) + 6000},
    ];
    final histories = <Map<String, Object?>>[
      {'durationMs': 1200000, 'frames': old, 'segments': []},
    ];
    final found = RepeatedSegments.discover(
      frames,
      histories,
      1200000,
      IntroOptions(),
    );
    expect(found, hasLength(1));
    expect(found.single.startMs, 36000);
    expect(found.single.source, 'fingerprint.repeat');
    expect(
      RepeatedSegments.discover(frames, histories, 60000, IntroOptions()),
      isEmpty,
    );
    final still = [
      for (final f in old)
        <String, Object?>{
          ...f,
          'p': 'abababababababab',
          'd': 'abababababababab',
        },
    ];
    expect(
      RepeatedSegments.discover(
        still,
        [
          {'durationMs': 1200000, 'frames': still},
        ],
        1200000,
        IntroOptions(),
      ),
      isEmpty,
    );
    expect(
      RepeatedSegments.discover(
        frames,
        [
          {'frames': old},
        ],
        1200000,
        IntroOptions(),
      ),
      isEmpty,
    );
  });
  test('追更续看只在同线路匹配，上集看完才进入下一集，末集和移除集不乱跳', () {
    const chapters = [
      SourceChapter(id: 'a1', title: '第01集', line: 'A'),
      SourceChapter(id: 'a2', title: '第02集', line: 'A'),
      SourceChapter(id: 'b1', title: '第01集', line: 'B'),
      SourceChapter(id: 'b2', title: '第02集', line: 'B'),
    ];
    VideoProgress progress(String id, int seconds) => VideoProgress(
      section: Section.video,
      itemId: 'work',
      chapterIndex: 0,
      chapterId: id,
      chapterTitle: id,
      updatedAt: DateTime(2026),
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 100),
    );
    final p = progress('b1', 96);
    final episodes = TrackingResume.episodes(chapters, p);
    expect(episodes.map((c) => c.id), ['b1', 'b2']);
    expect(TrackingResume.index(episodes, p), 1);
    expect(TrackingResume.index(episodes, progress('b1', 30)), 0);
    expect(TrackingResume.index(episodes, progress('b2', 99)), -1);
    expect(TrackingResume.index(episodes, progress('removed', 99)), -1);
    expect(TrackingResume.index(episodes, null), 0);
  });
  testWidgets('线路测速可刷新顺序，显示实测信息并保留线路选择回调', (tester) async {
    var measured = false;
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerSourceSheet(
            address: 'https://example.test/video.mp4',
            initialTab: PlayerSourceTab.lines,
            loadLines: () async => measured
                ? [
                    const PlayerSourceLine('B', detail: '探测 2.0MB/s'),
                    const PlayerSourceLine('A', current: true),
                  ]
                : [
                    const PlayerSourceLine('A', current: true),
                    const PlayerSourceLine('B'),
                  ],
            onBenchmarkLines: () async => measured = true,
            onSelectLine: (name) async {
              chosen = name;
              return false;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('测速并排序'));
    await tester.pumpAndSettle();
    expect(find.text('探测 2.0MB/s'), findsOneWidget);
    expect(find.text('测速未完成，请重试'), findsNothing);
    expect(
      tester.getTopLeft(find.text('B')).dy,
      lessThan(tester.getTopLeft(find.text('A')).dy),
    );
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(chosen, 'B');
  });
  group('线路实测记录', () {
    late Directory root;
    late ReadingLibrary library;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('lume-line-performance');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      await SectionScope.open(Section.video);
      library = await ReadingLibrary.open(Section.video);
    });
    tearDown(() async {
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      root.deleteSync(recursive: true);
    });
    test('失败优先降级，同作品按实测排序，其他作品不串记录', () {
      final store = LinePerformance(library, 'source:work');
      store.record('A', kbps: 4000, startupMs: 2000);
      store.record('B', kbps: 12000, startupMs: 1000);
      expect(['A', 'B']..sort(store.compare), ['B', 'A']);
      store.record('B', failed: true);
      expect(['A', 'B']..sort(store.compare), ['A', 'B']);
      expect(LinePerformance(library, 'another:work').result('A'), isEmpty);
      expect(
        LinePerformance(library, 'source:work').describe('A'),
        contains('2.0 秒'),
      );
      expect(store.result('A').keys, isNot(contains('url')));
    });
  });
}
