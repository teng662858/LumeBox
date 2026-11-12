import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/native_video_bridge.dart';
import 'package:lume_box/core/player/playback_diagnostics.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/session/section_module_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_runtime_pins.dart';
import 'package:lume_box/features/video/native_video_source_session.dart';
import 'package:lume_box/features/video/video_play_target.dart';
import 'package:lume_box/features/video/video_player_settings.dart';
import 'package:lume_box/features/video/source_playback_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lumebox/native_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late ReadingLibrary library;
  late NativeVideoBridge bridge;
  late _Source source;
  late Map<String, Object?> opened;
  late NativeVideoSourceSession session;
  final calls = <MethodCall>[];

  Future<Object?> native(String method, Map<String, Object?> arguments) async {
    final result = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (ByteData? bytes) {
        if (bytes == null) {
          result.complete(null);
          return;
        }
        try {
          result.complete(const StandardMethodCodec().decodeEnvelope(bytes));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future;
  }

  Future<Map<String, Object?>> request(
    String action, [
    Map<String, Object?> args = const {},
  ]) async => Map<String, Object?>.from(
    await native('request', {
      'session': opened['session'],
      'action': action,
      'arguments': args,
    }) as Map,
  );
  Future<void> progress(
    double at, {
    String? identity,
    String type = 'progress',
    String? error,
  }) async {
    await native('event', {
      'session': opened['session'],
      'identity': identity ?? (opened['media'] as Map)['identity'],
      'type': type,
      'position': at,
      'duration': 100.0,
      'playing': true,
      'error': ?error,
    });
  }

  Future<void> start({
    VideoPlayTarget? target,
    List<VideoQuality> qualities = const [],
    Future<PlayerMedia> Function(PlayerMedia, bool)? prepare,
  }) async {
    session = NativeVideoSourceSession(
      media: PlayerMedia(
        uri: Uri.parse('https://cdn.example/A1.m3u8'),
        headers: const {'Referer': 'https://example/', 'Cookie': 'session=a,b'},
      ),
      library: library,
      source: source,
      bridge: bridge,
      qualities: qualities,
      target:
          target ??
          const VideoPlayTarget(
            sourceId: 'fixture',
            itemId: 'show',
            title: '测试作品',
            chapterIndex: 0,
            chapterId: 'A1',
            chapterTitle: '第1集',
          ),
      prepareMedia: prepare ?? (media, _) async => media,
    );
    addTearDown(session.close);
    await session.open();
  }

  setUp(() async {
    calls.clear();
    opened = {};
    directory = await Directory.systemTemp.createTemp('native-video-test-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'open') {
        opened = Map<String, Object?>.from(call.arguments as Map);
      }
      return null;
    });
    await SectionScope.open(Section.video);
    library = await ReadingLibrary.open(Section.video);
    bridge = NativeVideoBridge();
    source = _Source();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });

  test('native handoff preserves signed URLs and exact headers without creating Dart engines', () async {
    await start();
    final media = opened['media'] as Map;
    expect(media['url'], 'https://cdn.example/A1.m3u8');
    expect(media['headers'], {
      'Referer': 'https://example/',
      'Cookie': 'session=a,b',
    });
    expect((opened['options'] as Map)['kernel'], 'avplayer');
    expect(calls.map((c) => c.method), ['open']);
    expect(SourceRuntimePins.contains(Section.video, 'fixture'), isTrue);
    await session.close();
    expect(SourceRuntimePins.contains(Section.video, 'fixture'), isFalse);
  });
  test(
    'each native load reports its own clock across kernel and hardware changes',
    () async {
      await start();
      for (final kernel in ['avplayer', 'mpv', 'mpv', 'avplayer']) {
        for (final type in ['load-start', 'ready', 'firstFrame']) {
          await native('event', {
            'session': opened['session'],
            'type': type,
            'kernel': kernel,
            'generation': 2,
            'elapsedMs': type == 'load-start' ? 0 : 123,
          });
        }
        final events = PlaybackDiagnostics.snapshot;
        expect(events[events.length - 3]['stage'], 'native-open');
        expect(events[events.length - 3]['elapsedMs'], 0);
        expect(events.last['kernel'], kernel);
        expect(events.last['elapsedMs'], 123);
      }
      await session.close();
    },
  );
  test('an inspected unsupported Apple container retries with MPV before presentation', () async {
    final modes = <bool>[];
    await start(
      prepare: (media, apple) async {
        modes.add(apple);
        if (apple) throw UnsupportedError('inspected MKV');
        return media;
      },
    );
    expect(modes, [true, false]);
    expect((opened['options'] as Map)['kernel'], 'mpv');
    expect(calls.where((call) => call.method == 'open'), hasLength(1));
  });
  test('source profile defaults and native changes stay isolated from global preferences', () async {
    SourcePlaybackProfiles(library).save(
      'fixture',
      const PlayerSettings(kernel: PlayerKernel.mpv, hardwareDecoding: false),
      600,
    );
    await start();
    final options = opened['options'] as Map;
    expect(options['kernel'], 'mpv');
    expect(options['hardwareDecoding'], false);
    expect(options['forwardBufferSeconds'], 600);
    await native('event', {
      'session': opened['session'],
      'type': 'settings',
      'kernel': 'mpv',
      'speed': 1.5,
    });
    expect(
      VideoPlayerSettingsStore(library).load().kernel,
      PlayerKernel.avplayer,
    );
    expect(
      SourcePlaybackProfiles(library)
          .load('fixture', const PlayerSettings())
          .speed,
      1.5,
    );
  });
  test(
    'native options preserve module buffer limits without waiting to fill them',
    () async {
      const SectionModuleSettings(
        bufferSeconds: 420,
        bufferMiB: 96,
      ).save(library);
      await start();
      final options = opened['options'] as Map;
      expect(options['forwardBufferSeconds'], 420);
      expect(options['maxBufferBytes'], 96 * 1024 * 1024);
    },
  );
  test(
    'kernel switch prepares the original media for the destination engine',
    () async {
      final appleModes = <bool>[];
      await start(
        prepare: (media, apple) async {
          appleModes.add(apple);
          return PlayerMedia(
            uri: Uri.parse('http://127.0.0.1/${apple ? 'apple' : 'mpv'}.m3u8'),
          );
        },
      );
      await progress(19);
      final result = (await request('kernel', {'id': 'mpv'}))['media'] as Map;
      expect(appleModes, [true, false]);
      expect(result['position'], 19);
      expect(result['url'], 'http://127.0.0.1/mpv.m3u8');
      expect(result['sourceUrl'], 'https://cdn.example/A1.m3u8');
      expect(source.resolved, isEmpty);
    },
  );
  test(
    'progress belongs to the reported episode and never adds a favorite',
    () async {
      await start();
      final identity = (opened['media'] as Map)['identity'] as String;
      await progress(12.5);
      final saved = library.videoEpisodeProgress(
        'show',
        'A1',
        sourceId: 'fixture',
      );
      expect(saved?.position, const Duration(milliseconds: 12500));
      expect(library.onShelf('show', sourceId: 'fixture'), isFalse);
      expect(library.continueWatching().single.itemId, 'show');
      await request('next');
      await progress(14, identity: identity);
      expect(
        library.videoEpisodeProgress('show', 'A2', sourceId: 'fixture'),
        isNull,
      );
    },
  );
  test('incognito and error events do not overwrite saved history', () async {
    await start();
    await progress(10);
    library.setSetting('history.incognito', 'true');
    await progress(30);
    library.setSetting('history.incognito', 'false');
    await progress(40, error: 'HTTP 403');
    expect(
      library.videoEpisodeProgress('show', 'A1', sourceId: 'fixture')?.position,
      const Duration(seconds: 10),
    );
  });
  test(
    'unknown identity, non-finite and negative timing never writes progress',
    () async {
      await start();
      await progress(12, identity: 'unknown');
      await progress(double.nan);
      await progress(-1);
      expect(library.videoProgress('show', sourceId: 'fixture'), isNull);
    },
  );
  test(
    'episode and line lists keep original source IDs and selected line',
    () async {
      await start();
      expect(
        ((await request('episodes'))['items'] as List).map(
          (e) => (e as Map)['id'],
        ),
        ['A1', 'A2'],
      );
      expect(
        ((await request('lines'))['items'] as List).map(
          (e) => (e as Map)['id'],
        ),
        ['A', 'B'],
      );
    },
  );
  test(
    'next episode resets progress and forwards fresh content headers',
    () async {
      await start();
      await progress(27);
      final reply = (await request('next'))['media'] as Map;
      expect(reply['url'], 'https://cdn.example/A2.m3u8?token=fresh');
      expect(reply['position'], 0);
      expect((reply['headers'] as Map)['Referer'], 'https://example/');
      expect(session.target?.chapterId, 'A2');
      expect((await request('next'))['media'], isNull);
    },
  );
  test(
    'retry re-resolves the source and preserves the current playhead',
    () async {
      await start();
      await progress(23);
      final reply = (await request('retry'))['media'] as Map;
      expect(source.resolved, ['A1']);
      expect(reply['position'], 23);
      expect(reply['url'], contains('token=fresh'));
    },
  );
  test('line changes match the same episode and keep its position', () async {
    await start();
    await progress(18);
    final reply = (await request('line', {'id': 'B'}))['media'] as Map;
    expect(source.resolved, ['B1']);
    expect(reply['position'], 18);
    expect(session.target?.chapterId, 'B1');
  });
  test('stale source completions cannot replace a newer episode', () async {
    await start();
    final delayed = source.blocked['A2'] = Completer<ChapterContent>();
    final old = request('episode', {'id': 'A2'});
    while (!source.resolved.contains('A2')) {
      await Future<void>.delayed(Duration.zero);
    }
    await request('episode', {'id': 'B1'});
    delayed.complete(
      VideoContent(url: Uri.parse('https://cdn.example/stale.mp4')),
    );
    expect((await old)['error'], contains('取消'));
    expect(session.target?.chapterId, 'B1');
  });
  test(
    'closing cancels a source completion and releases its runtime pin',
    () async {
      await start();
      final delayed = source.blocked['A2'] = Completer<ChapterContent>();
      final old = request('next');
      while (source.resolved.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await session.close();
      delayed.complete(
        VideoContent(url: Uri.parse('https://cdn.example/stale.mp4')),
      );
      expect((await old)['error'], contains('取消'));
      expect(SourceRuntimePins.contains(Section.video, 'fixture'), isFalse);
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    },
  );
  test(
    'late native events after disposal cannot write to the library',
    () async {
      await start();
      await session.close();
      await progress(50);
      expect(library.videoProgress('show', sourceId: 'fixture'), isNull);
    },
  );
  test(
    'native settings persist only supported engines and bounded speed',
    () async {
      await start();
      await native('event', {
        'session': opened['session'],
        'type': 'settings',
        'kernel': 'mpv',
        'speed': 99.0,
        'autoNext': false,
        'hardwareDecoding': false,
      });
      final saved = VideoPlayerSettingsStore(library).load();
      expect(saved.kernel.id, 'mpv');
      expect(saved.speed, 4);
      expect(saved.autoNext, isFalse);
      expect(saved.hardwareDecoding, isFalse);
    },
  );
  test(
    'source danmaku is parsed without participating in media startup',
    () async {
      await start();
      expect((await request('danmaku'))['items'], [
        {'time': 1.0, 'text': '测试弹幕'},
      ]);
    },
  );
}

class _Source extends MockDataSource implements DanmakuCapable {
  _Source() : super(section: Section.video);
  final blocked = <String, Completer<ChapterContent>>{};
  final resolved = <String>[];
  @override
  String get id => 'fixture';
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => const [
    SourceChapter(id: 'A1', title: '第1集', line: 'A'),
    SourceChapter(id: 'A2', title: '第2集', line: 'A'),
    SourceChapter(id: 'B1', title: '第1集', line: 'B'),
  ];
  @override
  Future<ChapterContent> content({
    required String itemId,
    required String chapterId,
  }) async {
    resolved.add(chapterId);
    if (blocked[chapterId] case final pending?) return pending.future;
    return VideoContent(
      url: Uri.parse('https://cdn.example/$chapterId.m3u8?token=fresh'),
      headers: const {'Referer': 'https://example/'},
    );
  }

  @override
  Future<Object?> danmaku({
    required String itemId,
    required String chapterId,
  }) async => [
    {'time': 1000, 'text': '测试弹幕'},
  ];
}
