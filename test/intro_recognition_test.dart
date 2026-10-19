import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:lume_box/core/intro/community_sources.dart';
import 'package:lume_box/core/intro/intro_backend.dart';
import 'package:lume_box/core/intro/intro_controller.dart';
import 'package:lume_box/core/intro/intro_detectors.dart';
import 'package:lume_box/core/intro/intro_models.dart';
import 'package:lume_box/core/intro/intro_service.dart';
import 'package:lume_box/core/intro/intro_signals.dart';
import 'package:lume_box/core/intro/intro_store.dart';
import 'package:lume_box/core/intro/mkv_metadata.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/features/video/intro_episode_sheet.dart';

const episode = EpisodeIdentity(
  series: 'test-series',
  season: 1,
  episode: 1,
  tmdb: 1396,
  imdb: 'tt0903747',
);
const opening = SkipSegment(
  kind: SegmentKind.opening,
  startMs: 5000,
  endMs: 65000,
  confidence: 1,
  source: 'manual',
);
const duration = 1200000;
Map<String, Object?> disabled() => {
  for (final key in IntroOptions.switches.keys) key: false,
};
IntroRequest request({
  EpisodeIdentity identity = episode,
  Map<String, Object?> metadata = const {},
}) => IntroRequest(
  episode: identity,
  uri: Uri.parse('file:///sample.mp4'),
  durationMs: duration,
  metadata: metadata,
);

class FakeBackend implements IntroScanBackend {
  int metadataCalls = 0, sampleCalls = 0, inferenceCalls = 0, cancelCalls = 0;
  Map<String, Object?> tags = {};
  Map<String, Object?> gate = {'allowed': true, 'wifi': true, 'charging': true};
  Completer<IntroSample?>? blocked;
  @override
  Future<Map<String, Object?>> resources() async => gate;
  @override
  Future<Map<String, Object?>> metadata(
    Uri uri,
    Map<String, String> headers,
  ) async {
    metadataCalls++;
    return tags;
  }

  @override
  Future<IntroSample?> sample(
    Uri uri,
    Map<String, String> headers,
    int atMs,
    IntroOptions options,
    IntroCancellation token,
  ) async {
    sampleCalls++;
    if (blocked != null) return blocked!.future;
    return IntroSample(
      atMs: atMs,
      gray: Uint8List.fromList(
        List.generate(1024, (i) => (i * 37 + atMs ~/ 1000) % 256),
      ),
      pcm: List.generate(400, (i) => math.sin(i / 10) * .1),
    );
  }

  @override
  Future<IntroSample> infer(IntroSample sample, IntroOptions options) async {
    inferenceCalls++;
    return sample;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late IntroStore store;
  setUp(() => store = IntroStore(sqlite3.openInMemory()));
  tearDown(() {
    store.dispose();
    store.db.close();
  });

  testWidgets(
    'unsupported native scanner allocates no session or cleanup timers',
    (tester) async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeIntroBackend.channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeIntroBackend.channel,
          null,
        ),
      );
      final backend = NativeIntroBackend(platformSupported: false);
      expect((await backend.resources())['allowed'], isFalse);
      await expectLater(
        backend.metadata(Uri.parse('file:///sample.mp4'), {}),
        throwsA(isA<MissingPluginException>()),
      );
      await backend.close();
      await tester.pump();
      expect(calls, isEmpty);
    },
  );

  testWidgets(
    'closing a pending native session cancels its request and releases exactly once',
    (tester) async {
      final calls = <String>[];
      final metadata = Completer<Map<String, Object?>>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeIntroBackend.channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'metadata' ? metadata.future : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeIntroBackend.channel,
          null,
        ),
      );
      final backend = NativeIntroBackend(platformSupported: true);
      final pending = expectLater(
        backend.metadata(Uri.parse('file:///sample.mp4'), {}),
        throwsA(isA<IntroCancelled>()),
      );
      await tester.pump();
      await backend.close();
      await pending;
      await backend.close();
      metadata.complete({});
      await tester.pump();
      expect(calls, ['metadata', 'cancel', 'release']);
    },
  );

  test('manual four points, generated results and seasons have distinct persistence', () {
    store.saveSegments(episode, duration, [opening], manual: true);
    store.saveSegments(episode, duration, [
      const SkipSegment(
        kind: SegmentKind.ending,
        startMs: 1100000,
        endMs: duration,
        confidence: .97,
        source: 'chapters',
      ),
    ]);
    expect(store.manual(episode, duration).single.kind, SegmentKind.opening);
    expect(
      store.readSegments(episode, duration).single.kind,
      SegmentKind.ending,
    );
    expect(
      store
          .manual(
            const EpisodeIdentity(series: 'test-series', season: 1, episode: 2),
            duration,
            reuseSeason: true,
          )
          .single
          .endMs,
      65000,
    );
    expect(
      store.manual(
        const EpisodeIdentity(series: 'test-series', season: 2, episode: 1),
        duration,
        reuseSeason: true,
      ),
      isEmpty,
    );
    expect(
      store.manual(episode, duration + 3000),
      isEmpty,
      reason: 'Different edits are rejected',
    );
    store.update({'chapters': false});
    expect(
      store.readSegments(episode, duration),
      isEmpty,
      reason: 'Disabling a method invalidates its cached result',
    );
    expect(store.manual(episode, duration), hasLength(1));
  });
  test('same-series memory reuses OP and relative ED across unequal episodes without IDs', () {
    const first = EpisodeIdentity(series: 'source:work', episode: 1);
    const second = EpisodeIdentity(series: 'source:work', episode: 2);
    const tail = SkipSegment(
      kind: SegmentKind.ending,
      startMs: duration - 90000,
      endMs: duration,
      confidence: 1,
      source: 'manual',
    );
    store.rememberSeries(first, duration, [opening, tail]);
    final memory = store.seriesMemory(second, duration + 20000);
    expect(memory.map((s) => s.kind), [
      SegmentKind.opening,
      SegmentKind.ending,
    ]);
    expect(memory.first.endMs, 65000);
    expect(memory.last.startMs, duration + 20000 - 90000);
    expect(memory.last.endMs, duration + 20000);
    expect(
      store.seriesMemory(
        const EpisodeIdentity(series: 'another', episode: 2),
        duration,
      ),
      isEmpty,
    );
    expect(
      store.seriesMemory(
        const EpisodeIdentity(series: 'source:work', season: 2, episode: 2),
        duration,
      ),
      isEmpty,
    );
    expect(store.seriesMemory(first, duration + 20000), isEmpty);
    store.update({'reuseManualSeason': false});
    expect(store.seriesMemory(second, duration), isEmpty);
    store.update({'reuseManualSeason': true, 'manual': false});
    expect(store.seriesMemory(second, duration), isEmpty);
    store.update({'manual': true});
    final reopened = IntroStore(store.db);
    expect(reopened.seriesMemory(second, duration), hasLength(2));
    reopened.dispose();
    store.clearSeriesMemory(second);
    expect(
      store.hasSeriesMemory(first),
      isTrue,
      reason: 'Do not import cleared legacy marks again',
    );
    expect(store.seriesMemory(first, duration), isEmpty);
    expect(store.manual(first, duration, reuseSeason: true), isEmpty);
  });

  test('replacing precise marks removes a deleted opening from later episode memory', () {
    const tail = SkipSegment(
      kind: SegmentKind.ending,
      startMs: duration - 90000,
      endMs: duration,
      confidence: 1,
      source: 'manual',
    );
    store.saveSegments(episode, duration, [opening, tail], manual: true);
    store.saveSegments(episode, duration, [tail], manual: true);
    final later = store.seriesMemory(
      const EpisodeIdentity(series: 'test-series', episode: 2),
      duration + 20000,
    );
    expect(later.single.kind, SegmentKind.ending);
  });

  test('priority reorder deduplicates and retains every scheme', () {
    final options = IntroOptions({
      'order': ['ai', 'manual', 'ai', 'unknown'],
    });
    expect(options.order.take(2), [
      RecognitionStage.ai,
      RecognitionStage.manual,
    ]);
    expect(options.order.toSet(), RecognitionStage.values.toSet());
    expect(IntroOptions.switches.length, 17);
  });
  test('community identity changes invalidate machine results and preserve manual marks', () {
    store.saveSegments(episode, duration, [opening]);
    store.saveSegments(episode, duration, [opening], manual: true);
    expect(store.readSegments(episode, duration), hasLength(1));
    const corrected = EpisodeIdentity(
      series: 'test-series',
      season: 1,
      episode: 1,
      tmdb: 999,
      imdb: 'tt1234567',
    );
    expect(store.readSegments(corrected, duration), isEmpty);
    expect(store.manual(corrected, duration), hasLength(1));
  });
  test(
    'empty and incompatible manual marks do not hide a usable season reference',
    () {
      store.saveSegments(episode, duration, [opening], manual: true);
      const second = EpisodeIdentity(
        series: 'test-series',
        season: 1,
        episode: 2,
      );
      const third = EpisodeIdentity(
        series: 'test-series',
        season: 1,
        episode: 3,
      );
      const fourth = EpisodeIdentity(
        series: 'test-series',
        season: 1,
        episode: 4,
      );
      store.saveSegments(second, duration, [], manual: true);
      store.saveSegments(third, duration + 10000, [opening], manual: true);
      expect(store.manual(second, duration, reuseSeason: true), isEmpty);
      expect(
        store.manual(fourth, duration, reuseSeason: true).single.endMs,
        opening.endMs,
      );
    },
  );
  testWidgets(
    'four-point editor reads live position and rejects invalid repeated clock components',
    (tester) async {
      final controller = IntroController(store, backend: FakeBackend.new)
        ..request = request();
      var position = const Duration(seconds: 7);
      await tester.pumpWidget(
        MaterialApp(
          home: IntroEpisodeSheet(
            controller: controller,
            position: () => position,
          ),
        ),
      );
      await tester.tap(find.text('高级：精确调整起止时间'));
      await tester.pumpAndSettle();
      position = const Duration(seconds: 42);
      final current = find.widgetWithText(TextButton, '当前位置').first;
      await tester.ensureVisible(current);
      await tester.tap(current);
      await tester.pump();
      expect(find.text('0:42.000'), findsOneWidget);
      final start = find.widgetWithText(TextField, 'OP 起点');
      final end = find.widgetWithText(TextField, 'OP 终点');
      await tester.enterText(start, '90:90');
      await tester.enterText(end, '92:00');
      final save = find.widgetWithText(FilledButton, '保存四点标记');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      expect(store.manual(episode, duration), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  test(
    'malformed preferences cannot crash settings or schedule unbounded work',
    () {
      final options = IntroOptions({
        'active': 'bad',
        'order': 'bad',
        'scanSeconds': double.nan,
        'maxSamples': 90000,
        'threshold': 'bad',
      });
      expect(options.active, isTrue);
      expect(options.order, RecognitionStage.values);
      expect(options.scanSeconds, 45);
      expect(options.maxSamples, 240);
      expect(options.threshold, .85);
    },
  );
  test(
    'method-channel PCM may be unaligned and contains no nonfinite samples',
    () {
      final buffer = Uint8List(14);
      final bytes = ByteData.sublistView(buffer);
      bytes.setFloat32(1, .25, Endian.little);
      bytes.setFloat32(5, -.5, Endian.little);
      bytes.setFloat32(9, double.nan, Endian.little);
      expect(
        NativeIntroBackend.decodePcm(Uint8List.sublistView(buffer, 1, 13)),
        [.25, -.5, 0],
      );
    },
  );
  test(
    'AI needs a consecutive video run and honors the independent audio gate',
    () {
      final frames = List.generate(
        5,
        (i) => IntroSample(
          atMs: i * 3000,
          gray: Uint8List(1024),
          ai: const {'opening': .95, 'speech': .9, 'music': .1},
        ),
      );
      expect(
        AiSegments.classify(frames, duration, IntroOptions()),
        isEmpty,
        reason: 'Dialogue vetoes music-only OP evidence',
      );
      expect(
        AiSegments.classify(
          frames,
          duration,
          IntroOptions({'audioAI': false}),
        ).single.source,
        'ai.mobileclip',
      );
      expect(
        AiSegments.classify(frames, duration, IntroOptions({'videoAI': false})),
        isEmpty,
      );
      expect(
        AiSegments.classify(
          frames.take(3).toList(),
          duration,
          IntroOptions({'audioAI': false}),
        ),
        isEmpty,
      );
    },
  );
  test(
    'OCR tracks a moving credit line even when the top heading is stationary',
    () {
      final frames = List.generate(
        2,
        (i) => IntroSample(
          atMs: 1000000 + i * 3000,
          gray: Uint8List(1024),
          text: 'Director Cast',
          textY: .1,
          lines: [
            {'text': 'Stationary heading', 'y': .1},
            {'text': 'Director Name', 'y': .8 - i * .2},
          ],
        ),
      );
      final options = IntroOptions({...disabled(), 'ocr': true});
      expect(
        HeuristicSegments.detect(frames, duration, options).single.source,
        'heuristic.ocr',
      );
      expect(
        HeuristicSegments.detect(
          frames,
          duration,
          IntroOptions({...disabled()}),
        ),
        isEmpty,
      );
    },
  );
  test('TheIntroDB uses current v4 millisecond API and rejects a mismatched release', () async {
    final client = CommunitySegments(
      client: MockClient((req) async {
        expect(req.url.path, '/v4/media');
        expect(req.url.queryParameters['tmdb_id'], '1396');
        expect(req.url.queryParameters['details'], 'true');
        return http.Response(
          jsonEncode({
            'group_duration_ms': duration + 10000,
            'intro': [
              {'start_ms': 5000, 'end_ms': 65000, 'confidence': .98},
            ],
          }),
          200,
        );
      }),
    );
    await expectLater(
      client.lookup('theIntroDB', episode, duration, IntroCancellation()),
      throwsStateError,
    );
    client.close();
  });
  test('IntroDB preserves OP start, ED end and confidence without confusing seconds', () async {
    final client = CommunitySegments(
      client: MockClient((req) async {
        expect(req.url.host, 'api.introdb.app');
        expect(req.url.path, '/segments');
        expect(req.url.queryParameters['imdb_id'], episode.imdb);
        return http.Response(
          jsonEncode({
            'intro': {'start_ms': 5000, 'end_ms': 65000, 'confidence': .94},
            'outro': {
              'start_ms': 1100000,
              'end_ms': 1180000,
              'confidence': .91,
            },
          }),
          200,
        );
      }),
    );
    final result = await client.lookup(
      'introDB',
      episode,
      duration,
      IntroCancellation(),
    );
    expect(result.map((s) => s.startMs), [5000, 1100000]);
    expect(result.last.endMs, 1180000);
    expect(result.first.confidence, .94);
    client.close();
  });
  test('one disabled online provider is never requested; success stops all lower layers', () async {
    store.update({...disabled(), 'introDB': true});
    final backend = FakeBackend();
    var calls = 0;
    final community = CommunitySegments(
      client: MockClient((req) async {
        calls++;
        expect(req.url.host, 'api.introdb.app');
        return http.Response(
          '{"intro":{"start_ms":5000,"end_ms":65000,"confidence":0.95}}',
          200,
        );
      }),
    );
    final service = IntroRecognitionService(
      store: store,
      backend: backend,
      community: community,
    );
    final result = await service.recognize(
      request(),
      IntroCancellation(),
      allowHeavy: true,
    );
    expect(calls, 1);
    expect(result.single.source, 'introDB');
    expect(backend.metadataCalls, 0);
    expect(backend.sampleCalls, 0);
    expect(backend.inferenceCalls, 0);
    await service.close();
  });
  test(
    'community error falls back to manual, and manual-first avoids the network',
    () async {
      store.update({...disabled(), 'manual': true, 'introDB': true});
      store.saveSegments(episode, duration, [opening], manual: true);
      var calls = 0;
      final service = IntroRecognitionService(
        store: store,
        backend: FakeBackend(),
        community: CommunitySegments(
          client: MockClient((_) async {
            calls++;
            return http.Response('unavailable', 503);
          }),
        ),
      );
      expect(
        (await service.recognize(
          request(),
          IntroCancellation(),
          allowHeavy: false,
        )).single.source,
        'manual',
      );
      expect(calls, 1);
      store.update({
        'order': ['manual', 'community'],
      });
      await service.recognize(
        request(),
        IntroCancellation(),
        allowHeavy: false,
      );
      expect(calls, 1);
      expect(
        store.recentLogs().any((r) => r['status'] == 'provider-error'),
        isTrue,
      );
      await service.close();
    },
  );
  test(
    'network rate limiting backs off instead of retrying every snapshot',
    () async {
      var calls = 0;
      final client = CommunitySegments(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 429, headers: {'retry-after': '60'});
        }),
      );
      await expectLater(
        client.lookup('introDB', episode, duration, IntroCancellation()),
        throwsStateError,
      );
      expect(
        await client.lookup('introDB', episode, duration, IntroCancellation()),
        isEmpty,
      );
      expect(calls, 1);
      client.close();
    },
  );
  test('chapter OP ranges stop at the following chapter; untimed filenames cannot invent bounds', () {
    final options = IntroOptions();
    final result = MetadataSegments.detect(
      {
        'chapters': [
          {'title': 'OP', 'startMs': 5000},
          {'title': 'Main story', 'startMs': 65000},
          {'title': 'ED', 'startMs': 1100000},
        ],
      },
      duration,
      options,
    );
    expect(result.first.endMs, 65000);
    expect(result.last.kind, SegmentKind.ending);
    expect(MetadataSegments.timedFilename('S01E01.Opening.mkv'), isEmpty);
    expect(
      MetadataSegments.timedFilename('Episode.OP[00:05-01:05].mkv')
          .single['endMs'],
      65000,
    );
    expect(
      MetadataSegments.detect(
        {
          'chapters': [
            {'title': 'OP', 'startMs': 0},
          ],
        },
        duration,
        options,
      ),
      isEmpty,
      reason: 'A single OP marker must not skip the whole movie',
    );
  });
  test('disabled metadata avoids both the native reader and lazy MPV property probe', () async {
    store.update(disabled());
    final backend = FakeBackend();
    var calls = 0;
    final service = IntroRecognitionService(store: store, backend: backend);
    await service.recognize(
      IntroRequest(
        episode: episode,
        uri: Uri.parse('file:///x.mp4'),
        durationMs: duration,
        playbackMetadata: () async {
          calls++;
          return {};
        },
      ),
      IntroCancellation(),
      allowHeavy: false,
    );
    expect(backend.metadataCalls, 0);
    expect(calls, 0);
    expect(backend.sampleCalls, 0);
    await service.close();
  });
  test('EBML chapter UID tags and Chinese names are decoded', () {
    Uint8List element(List<int> id, List<int> body) {
      expect(body.length, lessThan(127));
      return Uint8List.fromList([...id, 0x80 | body.length, ...body]);
    }

    final atom = element(
      [0xb6],
      [
        ...element([0x73, 0xc4], [1]),
        ...element([0x91], [0]),
        ...element([0x92], [0x0e, 0xe6, 0xb2, 0x80, 0x00]),
        ...element([0x80], element([0x85], utf8.encode('片头'))),
      ],
    );
    final block = element([
      0x10,
      0x43,
      0xa7,
      0x70,
    ], element([0x45, 0xb9], atom));
    final result = MkvMetadataProbe.parseBlocks([block]);
    final chapter = (result['chapters'] as List).single as Map;
    expect(chapter['title'], '片头');
    expect(chapter['startMs'], 0);
    expect(chapter['endMs'], greaterThan(0));
    final nested = element([
      0x10,
      0x43,
      0xa7,
      0x70,
    ], element([0x45, 0xb9], element([0xb6], atom)));
    expect(
      (MkvMetadataProbe.parseBlocks([nested])['chapters'] as List).where(
        (value) => (value as Map)['title'] == '片头',
      ),
      hasLength(1),
    );
    Uint8List tag(String name, String value) => element(
      [0x67, 0xc8],
      [
        ...element([0x45, 0xa3], utf8.encode(name)),
        ...element([0x44, 0x87], utf8.encode(value)),
      ],
    );
    final timedTags = element(
      [0x12, 0x54, 0xc3, 0x67],
      element(
        [0x73, 0x73],
        [...tag('OP_START', '0:05.000'), ...tag('OP_END', '1:05.000')],
      ),
    );
    final ranges = MkvMetadataProbe.parseBlocks([timedTags])['mkvTags'] as List;
    expect((ranges.single as Map)['startMs'], 5000);
    expect((ranges.single as Map)['endMs'], 65000);
    expect(
      MkvMetadataProbe.parseBlocks([
        Uint8List.sublistView(timedTags, 0, timedTags.length - 3),
      ])['mkvTags'],
      isEmpty,
    );
  });
  test('pHash, dHash and MFCC are deterministic; silent or flat frames cannot become fingerprint anchors', () {
    final image = Uint8List.fromList(
      List.generate(1024, (i) => (i * 37 + i ~/ 32 * 13) % 256),
    );
    expect(
      IntroSignals.hamming(
        IntroSignals.pHash(image),
        IntroSignals.pHash(image),
      ),
      0,
    );
    expect(
      IntroSignals.hamming(
        IntroSignals.dHash(image),
        IntroSignals.dHash(image),
      ),
      0,
    );
    final pcm = List.generate(
      1600,
      (i) => math.sin(i * 2 * math.pi * 440 / 16000) * .2,
    );
    final vector = IntroSignals.mfcc(pcm);
    expect(vector, hasLength(12));
    expect(vector.every((v) => v.isFinite), isTrue);
    expect(
      IntroSignals.cosine(vector, IntroSignals.mfcc(pcm)),
      closeTo(1, 1e-9),
    );
    expect(
      IntroSignals.fingerprint(
        IntroSample(atMs: 0, gray: Uint8List(1024), pcm: List.filled(400, 0)),
        IntroOptions(),
      ).keys,
      ['at'],
    );
  });
  test('a fingerprint match needs a repeated temporal sequence and a consistent offset', () {
    final refs = List.generate(
      7,
      (i) => <String, Object?>{
        'at': 5000 + i * 3000,
        'p': (BigInt.one << (i * 7)).toRadixString(16),
        'm': [i + 1.0, 1.0, .3],
      },
    );
    final candidate = refs
        .map((r) => {...r, 'at': (r['at'] as int) + 9000})
        .toList();
    final options = IntroOptions({...disabled(), 'phash': true});
    final result = FingerprintSegments.match(
      candidate,
      [
        {
          'frames': refs,
          'segments': [
            const SkipSegment(
              kind: SegmentKind.opening,
              startMs: 5000,
              endMs: 26000,
              confidence: 1,
              source: 'manual',
            ).toJson(),
          ],
        },
      ],
      duration,
      options,
    );
    expect(result.single.startMs, 14000);
    expect(result.single.endMs, 35000);
    expect(
      FingerprintSegments.match(
        candidate.take(3).toList(),
        [
          {
            'frames': refs,
            'segments': [opening.toJson()],
          },
        ],
        duration,
        options,
      ),
      isEmpty,
    );
  });
  test('black frames or silence alone never trigger heuristic skipping', () {
    final frames = List.generate(
      8,
      (i) => IntroSample(
        atMs: i * 5000,
        gray: Uint8List(1024),
        pcm: const [0, 0, 0],
      ),
    );
    expect(HeuristicSegments.detect(frames, duration, IntroOptions()), isEmpty);
  });
  test(
    'scan scheduling visits both OP and ED before refining the beginning',
    () {
      final positions = IntroRecognitionService.scanPositions(
        duration,
        IntroOptions({'maxSamples': 10}),
      );
      expect(positions.length, lessThanOrEqualTo(10));
      expect(positions.first, lessThan(240000));
      expect(positions[1], greaterThan(duration - 241000));
    },
  );
  test('playing light path does not decode frames or invoke OCR/AI', () async {
    store.update({
      ...disabled(),
      'black': true,
      'silence': true,
      'videoAI': true,
    });
    final backend = FakeBackend();
    final service = IntroRecognitionService(store: store, backend: backend);
    await service.recognize(request(), IntroCancellation(), allowHeavy: false);
    expect(backend.sampleCalls, 0);
    expect(backend.inferenceCalls, 0);
    expect(
      store.recentLogs().where((r) => r['status'] == 'deferred-idle'),
      isNotEmpty,
    );
    await service.close();
  });
  test('thermal gate defers heavy work without decoding', () async {
    store.update({...disabled(), 'black': true});
    final backend = FakeBackend()
      ..gate = {'allowed': false, 'reason': 'thermal'};
    final service = IntroRecognitionService(store: store, backend: backend);
    await service.recognize(request(), IntroCancellation(), allowHeavy: true);
    expect(service.deferred, isTrue);
    expect(backend.sampleCalls, 0);
    await service.close();
  });
  test('fingerprint teaching runs on an isolate and never invokes lower-priority AI', () async {
    store.update({
      ...disabled(),
      'manual': true,
      'phash': true,
      'maxSamples': 10,
    });
    store.saveSegments(episode, duration, [opening], manual: true);
    final backend = FakeBackend();
    final service = IntroRecognitionService(store: store, backend: backend);
    expect(
      (await service.recognize(
        request(),
        IntroCancellation(),
        allowHeavy: true,
      )).single.source,
      'manual',
    );
    expect(backend.sampleCalls, 10);
    expect(backend.inferenceCalls, 0);
    expect(
      store.fingerprints(
        const EpisodeIdentity(series: 'test-series', episode: 2),
      ),
      hasLength(1),
    );
    await service.close();
  });

  Future<IntroController> ready(
    WidgetTester tester,
    List<Duration> seeks,
  ) async {
    store.update({
      ...disabled(),
      'manual': true,
      'order': ['manual'],
      'countdown': 3,
    });
    store.saveSegments(episode, duration, [opening], manual: true);
    final controller = IntroController(store, backend: FakeBackend.new);
    controller.update(
      const PlayerSnapshot(
        playing: true,
        duration: Duration(milliseconds: duration),
      ),
      foreground: true,
    );
    controller.bind(request(), (position) async => seeks.add(position));
    for (var i = 0; i < 20 && controller.segments.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(controller.segments, hasLength(1));
    return controller;
  }

  const within = PlayerSnapshot(
    playing: true,
    position: Duration(seconds: 10),
    duration: Duration(milliseconds: duration),
  );
  testWidgets(
    'cancelling the prompt prevents the timer and repeated snapshots from skipping',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      controller.update(within, foreground: true);
      expect(controller.prompt, isNotNull);
      controller.dismiss();
      await tester.pump(const Duration(seconds: 5));
      controller.update(within, foreground: true);
      expect(controller.prompt, isNull);
      expect(seeks, isEmpty);
      controller.dispose();
    },
  );
  testWidgets(
    'background PiP keeps automatic skip while heavy scanning stays idle',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      controller.update(within, foreground: false, pictureInPicture: true);
      expect(controller.prompt, isNotNull);
      await tester.pump(const Duration(seconds: 4));
      expect(seeks, [const Duration(milliseconds: 65000)]);
      expect(controller.scanning, isFalse);
      controller.dispose();
    },
  );

  testWidgets(
    'PiP pause and buffering freeze countdown; leaving PiP stops skipping',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      controller.update(within, foreground: false, pictureInPicture: true);
      controller.update(
        const PlayerSnapshot(position: Duration(seconds: 10)),
        foreground: false,
        pictureInPicture: true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(seeks, isEmpty);
      controller.update(
        const PlayerSnapshot(
          playing: true,
          buffering: true,
          position: Duration(seconds: 10),
        ),
        foreground: false,
        pictureInPicture: true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(seeks, isEmpty);
      controller.update(within, foreground: false);
      await tester.pump(const Duration(seconds: 5));
      expect(seeks, isEmpty);
      controller.update(within, foreground: false, pictureInPicture: true);
      await tester.pump(const Duration(seconds: 4));
      expect(seeks, hasLength(1));
      controller.dispose();
    },
  );

  testWidgets(
    'finishing an old seek after changing episode does not learn for the new episode',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      final pending = Completer<void>();
      controller.seek = (_) => pending.future;
      controller.update(within, foreground: true);
      final done = controller.skipNow();
      const other = EpisodeIdentity(series: 'different-work', episode: 1);
      controller.bind(request(identity: other), (_) async {});
      pending.complete();
      await done;
      expect(store.hasSeriesMemory(other), isFalse);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('countdown performs one seek to the exact OP endpoint', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final controller = await ready(tester, seeks);
    controller.update(within, foreground: true);
    await tester.pump(const Duration(seconds: 4));
    controller.update(within, foreground: true);
    await tester.pump(const Duration(seconds: 4));
    expect(seeks, [const Duration(milliseconds: 65000)]);
    controller.dispose();
  });
  testWidgets(
    'background and buffering freeze countdown; seek outside removes prompt',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      controller.update(within, foreground: true);
      controller.update(within, foreground: false);
      await tester.pump(const Duration(seconds: 8));
      expect(seeks, isEmpty);
      controller.update(
        const PlayerSnapshot(
          playing: true,
          buffering: true,
          position: Duration(seconds: 10),
          duration: Duration(milliseconds: duration),
        ),
        foreground: true,
      );
      await tester.pump(const Duration(seconds: 8));
      expect(seeks, isEmpty);
      controller.update(
        const PlayerSnapshot(
          playing: true,
          position: Duration(seconds: 100),
          duration: Duration(milliseconds: duration),
        ),
        foreground: true,
      );
      expect(controller.prompt, isNull);
      controller.dispose();
    },
  );
  testWidgets(
    'master switch cancels an outstanding prompt and clears generated results',
    (tester) async {
      final seeks = <Duration>[];
      final controller = await ready(tester, seeks);
      controller.update(within, foreground: true);
      store.update({'active': false});
      await tester.pump(const Duration(seconds: 8));
      expect(controller.prompt, isNull);
      expect(controller.segments, isEmpty);
      expect(seeks, isEmpty);
      controller.dispose();
    },
  );
}
