import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_web_parse.dart';
import 'package:lume_box/core/media/playback_focus.dart';
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
import 'package:lume_box/features/video/video_download_center.dart';
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
  late VideoDownloadCenter downloads;
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
    bool playing = true,
    double duration = 100,
  }) async {
    await native('event', {
      'session': opened['session'],
      'identity': identity ?? (opened['media'] as Map)['identity'],
      'type': type,
      'position': at,
      'duration': duration,
      'playing': playing,
      'error': ?error,
    });
  }

  Future<void> start({
    VideoPlayTarget? target,
    PlayerMedia? initialMedia,
    Duration? initialPosition,
    List<VideoQuality> qualities = const [],
    Future<PlayerMedia> Function(PlayerMedia, bool)? prepare,
  }) async {
    session = NativeVideoSourceSession(
      initialPosition: initialPosition,
      media:
          initialMedia ??
          PlayerMedia(
            uri: Uri.parse('https://cdn.example/A1.m3u8'),
            headers: const {
              'Referer': 'https://example/',
              'Cookie': 'session=a,b',
            },
          ),
      library: library,
      downloads: downloads,
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
    downloads = VideoDownloadCenter(directory: () async => directory);
    await downloads.boot();
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

  test('a new video waits for the previous native screen to close', () async {
    await start();
    final first = session;
    final closing = Completer<void>();
    final dismissed = Completer<void>();
    addTearDown(() { if (!dismissed.isCompleted) dismissed.complete(); });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'close' && call.arguments['session'] == first.connectionId) {
        closing.complete();
        await dismissed.future;
      }
      if (call.method == 'open') {
        if (!dismissed.isCompleted) throw PlatformException(code: 'busy');
        opened = Map<String, Object?>.from(call.arguments as Map);
      }
      return null;
    });
    final second = start();
    await Future<void>.delayed(Duration.zero);
    try {
      expect(closing.isCompleted, isTrue);
      expect(calls.map((c) => c.method), ['open', 'close']);
    } finally {
      dismissed.complete();
      await second;
    }
    await progress(7);
    await first.close();
    expect(PlaybackFocus.isPlaying, isTrue);
  });

  test('a replaced video still preparing its URL cannot present afterwards', () async {
    final preparing = Completer<void>();
    final delayed = Completer<PlayerMedia>();
    final first = start(prepare: (media, _) {
      preparing.complete();
      return delayed.future;
    });
    await preparing.future;
    await start();
    await progress(7);
    delayed.complete(PlayerMedia(uri: Uri.parse('https://cdn.example/old.mp4')));
    await first;
    expect(calls.where((c) => c.method == 'open'), hasLength(1));
    expect(PlaybackFocus.isPlaying, isTrue);
  });

  test('cancelling a queued route leaves the current video playing', () async {
    await start();
    await progress(7);
    final first = session;
    final second = start();
    await session.close();
    await second;
    expect(calls.map((c) => c.method), ['open']);
    expect(PlaybackFocus.isPlaying, isTrue);
    await PlaybackFocus.acquire('audioBook');
    expect(calls.last.arguments['session'], first.connectionId);
    expect(calls.last.method, 'close');
  });

  test('focus handoff saves the native playhead reported during dismissal', () async {
    await start();
    await progress(10);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'close') {
        await progress(14);
        await native('event', {'session': opened['session'], 'type': 'closed'});
      }
      return null;
    });
    await PlaybackFocus.acquire('audioBook');
    expect(library.videoProgress('show', sourceId: 'fixture')?.position,
        const Duration(seconds: 14));
    await progress(60);
    expect(library.videoProgress('show', sourceId: 'fixture')?.position,
        const Duration(seconds: 14));
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
  test('legacy Matroska saved as media.mp4 opens with MPV offline', () async {
    final old = File('${directory.path}/media.mp4');
    await old.writeAsBytes([0x1a, 0x45, 0xdf, 0xa3]);
    await start(initialMedia: DownloadedVideoPlayback(old.uri).media('下载'));
    expect((opened['options'] as Map)['kernel'], 'mpv');
    expect((opened['media'] as Map)['url'], old.uri.toString());
  });

  for (final profiled in [false, true]) {
    test('automatic MPV fallback keeps the default kernel on next open (profile: $profiled)', () async {
      final store = VideoPlayerSettingsStore(library);
      final profiles = SourcePlaybackProfiles(library);
      final defaults = const PlayerSettings()
          .copyWith(kernel: PlayerKernel.mpv, speed: 1.75)
          .copyWith(kernel: PlayerKernel.avplayer, speed: 1.25);
      if (profiled) {
        profiles.save('fixture', defaults, 30);
      } else {
        store.save(defaults);
      }
      await start(initialMedia: PlayerMedia(uri: Uri.parse('file:///movie.mkv')));
      expect((opened['options'] as Map)['kernel'], 'mpv');
      expect((opened['options'] as Map)['speed'], 1.75);
      await native('event', {
        'session': opened['session'], 'type': 'settings', 'kernel': 'mpv',
        'speed': 1.75, 'hardwareDecoding': true, 'autoNext': true,
      });
      await native('event', {
        'session': opened['session'], 'type': 'settings', 'kernel': 'mpv', 'speed': 2.25,
      });
      final saved = profiles.load('fixture', store.load());
      expect(saved.kernel, PlayerKernel.avplayer);
      expect(saved.copyWith(kernel: PlayerKernel.mpv).speed, 2.25);
      await session.close();
      await start();
      expect((opened['options'] as Map)['kernel'], 'avplayer');
      expect((opened['options'] as Map)['speed'], 1.25);
    });
  }

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
    await native('event', {
      'session': opened['session'], 'type': 'settings', 'kernel': 'mpv',
      'speed': 1.0, 'hardwareDecoding': true, 'autoNext': true,
    });
    expect(VideoPlayerSettingsStore(library).load().kernel, PlayerKernel.avplayer);
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
  test('auto-next changed on a profiled source survives reopening the player', () async {
    SourcePlaybackProfiles(library).save('fixture', const PlayerSettings(kernel: PlayerKernel.mpv), 60);
    await start();
    expect((opened['options'] as Map)['autoNext'], true);
    await native('event', {
      'session': opened['session'], 'type': 'settings', 'kernel': 'mpv', 'autoNext': false,
    });
    await session.close();
    await start();
    expect((opened['options'] as Map)['autoNext'], false);
    expect(VideoPlayerSettingsStore(library).load().kernel, PlayerKernel.avplayer);
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
  for (final sourceOverride in [false, true]) {
    test('kernel changes restore independent speeds (source override: $sourceOverride)', () async {
      final store = VideoPlayerSettingsStore(library);
      final profiles = SourcePlaybackProfiles(library);
      final settings = const PlayerSettings()
          .copyWith(kernel: PlayerKernel.mpv, speed: 2.5)
          .copyWith(kernel: PlayerKernel.avplayer, speed: 1.75);
      if (sourceOverride) {
        profiles.save('fixture', settings, 30);
      } else {
        store.save(settings);
      }
      await start();
      expect((opened['options'] as Map)['speed'], 1.75);
      expect((await request('kernel', {'id': 'mpv'}))['speed'], 2.5);
      await native('event', {
        'session': opened['session'], 'type': 'settings', 'kernel': 'mpv',
        'speed': 1.75, 'hardwareDecoding': true, 'autoNext': true,
      });
      Future<void> settingsEvent(String kernel, [double? speed]) async {
        await native('event', {
          'session': opened['session'], 'type': 'settings', 'kernel': kernel,
          'speed': ?speed,
        });
      }
      await settingsEvent('mpv');
      PlayerSettings saved() => profiles.load('fixture', store.load());
      expect(saved().speed, 2.5);
      await settingsEvent('mpv', 2.75);
      expect((await request('kernel', {'id': 'avplayer'}))['speed'], 1.75);
      await settingsEvent('avplayer', 1.75);
      expect(saved().copyWith(kernel: PlayerKernel.mpv).speed, 2.75);
      if (sourceOverride) expect(store.load().speed, PlayerSettings.defaultSpeed);
    });
  }

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
  test('late progress updates only the previous episode after a switch', () async {
    await start();
    final first = (opened['media'] as Map)['identity'] as String;
    await progress(12);
    final next = (await request('next'))['media'] as Map;
    await progress(22, identity: next['identity'] as String);
    await progress(14, identity: first, playing: false);
    final latest = library.videoProgress('show', sourceId: 'fixture');
    expect(latest?.chapterId, 'A2');
    expect(latest?.position, const Duration(seconds: 22));
    expect(library.videoEpisodeProgress('show', 'A1', sourceId: 'fixture')?.position,
        const Duration(seconds: 14));
    expect(PlaybackFocus.isPlaying, isTrue);
  });

  test('a final update with unknown duration keeps the known duration of that episode', () async {
    await start();
    await progress(96);
    await progress(97, duration: 0, playing: false);
    final saved = library.videoProgress('show', sourceId: 'fixture');
    expect(saved?.position.inSeconds, 97);
    expect(saved?.duration.inSeconds, 100);
    expect(saved?.isFinished, isTrue);
    final next = (await request('next'))['media'] as Map;
    await progress(8, duration: 0, identity: next['identity'] as String);
    expect(library.videoProgress('show', sourceId: 'fixture')?.duration, Duration.zero);
    await progress(9, duration: 45, identity: next['identity'] as String);
    expect(library.videoProgress('show', sourceId: 'fixture')?.duration.inSeconds, 45);
  });
  for (final incognito in [false, true]) {
    test('a bookmark near the end opens at its timestamp without rewriting history (incognito=$incognito)', () async {
      await start();
      await progress(35);
      await session.close();
      library.setSetting('history.incognito', '$incognito');
      await start(initialPosition: const Duration(seconds: 98));
      expect((opened['media'] as Map)['position'], 98);
      expect(library.videoEpisodeProgress('show', 'A1', sourceId: 'fixture')?.position,
          const Duration(seconds: 35));
    });
  }

  test('an explicit seek to zero updates retry and history, while startup zero preserves them', () async {
    await start();
    await progress(35);
    await progress(0, type: 'ready');
    expect(((await request('retry'))['media'] as Map)['position'], 35);
    await progress(0, type: 'seek');
    expect(((await request('retry'))['media'] as Map)['position'], 0);
    expect(
      library.videoEpisodeProgress('show', 'A1', sourceId: 'fixture')?.position,
      Duration.zero,
    );
  });
  test('private playback opens at the position carried by a matching line', () async {
    library.setSetting('history.incognito', 'true');
    await start(target: const VideoPlayTarget(
      sourceId: 'fixture', itemId: 'show', title: '测试作品', chapterIndex: 0,
      chapterId: 'B1', chapterTitle: '第1集', resumePosition: Duration(seconds: 75),
    ));
    expect((opened['media'] as Map)['position'], 75);
    await progress(81);
    expect(library.videoProgress('show', sourceId: 'fixture'), isNull);
  });
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
  test('retry works even when the episode catalog is offline', () async {
    await start();
    source.catalogOffline = true;
    await progress(17);
    final media = (await request('retry'))['media'] as Map?;
    expect(media?['position'], 17);
    expect(media?['url'], contains('/A1.'));
    expect(session.target?.chapterIndex, 0);
  });
  test('a direct catalog item can retry its original URL while its resolver is unavailable', () async {
    const url = 'https://cdn.example/direct.mp4?ticket=first';
    const headers = {'Authorization': 'Bearer fixture'};
    await start(
      target: const VideoPlayTarget(sourceId: 'fixture', itemId: url,
        title: '电影', chapterIndex: 0, chapterId: url, chapterTitle: '正片'),
      initialMedia: PlayerMedia(uri: Uri.parse(url), headers: headers),
    );
    await progress(19);
    final first = source.blocked[url] = Completer<ChapterContent>();
    final retry = request('retry');
    while (!source.resolved.contains(url)) {
      await Future<void>.delayed(Duration.zero);
    }
    first.completeError(const SourceException(SourceErrorKind.callFailed, '无解析接口'));
    final original = (await retry)['media'] as Map?;
    expect(original?['url'], url);
    expect(original?['headers'], headers);
    expect(original?['position'], 19);
    final web = source.blocked[url] = Completer<ChapterContent>();
    final needsWeb = request('retry');
    while (source.resolved.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    web.completeError(CatWebParseRequired(Uri.parse('https://example.test/watch'), {}));
    expect((await needsWeb)['media'], isNull);
    source.blocked.remove(url);
    final fresh = (await request('retry'))['media'] as Map;
    expect(fresh['url'], endsWith('token=fresh'));
    expect(fresh['headers'], {'Referer': 'https://example/'});
    expect(fresh['position'], 19);
  });
  Future<File> stored(
    String id,
    int index,
    String line,
    String filename,
  ) async {
    final task = VideoDownloadTask(
      id: VideoDownloadCenter.identity('fixture', 'show', id),
      sourceId: 'fixture',
      itemId: 'show',
      chapterId: id,
      title: '测试作品',
      chapterTitle: '第${index + 1}集',
      chapterIndex: index,
      line: line,
      state: 'done',
      fileName: filename,
    );
    downloads.tasks.add(task);
    await Directory(downloads.folder(task)).create(recursive: true);
    final file = downloads.localFile(task);
    if (filename.endsWith('.m3u8')) {
      await file.writeAsString(
        '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
      );
      await File.fromUri(file.uri.resolve('part.ts')).writeAsBytes([1, 2, 3]);
    } else {
      await file.writeAsBytes([4, 5, 6]);
    }
    return file;
  }

  test('offline catalog switches downloaded episodes with original positions and releases HLS', () async {
    HttpOverrides.global = null;
    await stored('A4', 3, 'A', 'index.m3u8');
    final third = await stored('A3', 2, 'A', 'merged.mp4');
    await stored('B1', 0, 'B', 'merged.mp4');
    final first = await stored('A1', 0, 'A', 'merged.mp4');
    source.catalogOffline = true;
    await start(initialMedia: DownloadedVideoPlayback(first.uri).media('下载'));
    final list = await request('episodes');
    expect((list['items'] as List?)?.map((e) => e['id']), ['A1', 'A3', 'A4']);
    expect((await request('next'))['media'], isNull);
    expect(
      ((await request('episode', {'id': 'A3'}))['media'] as Map)['url'],
      third.uri.toString(),
    );
    final next = (await request('next'))['media'] as Map;
    expect(session.target?.chapterId, 'A4');
    expect(session.target?.chapterIndex, 3);
    final uri = Uri.parse(next['url'] as String);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final bytes = await (await client.getUrl(uri.resolve('part.ts'))).close();
    expect(await bytes.expand((b) => b).toList(), [1, 2, 3]);
    await progress(22, identity: next['identity'] as String);
    final saved = library.videoProgress('show', sourceId: 'fixture');
    expect(saved?.chapterIndex, 3);
    expect(saved?.position.inSeconds, 22);
    final retried = (await request('retry'))['media'] as Map;
    expect(retried['url'], next['url']);
    expect(retried['position'], 22);
    expect(
      ((await request('previous'))['media'] as Map)['url'],
      third.uri.toString(),
    );
    expect(source.resolved, isEmpty);
    await expectLater(
      client.getUrl(uri).then((r) => r.close()),
      throwsA(isA<IOException>()),
    );
  });
  test('downloaded episodes switch immediately while the source catalog is stalled', () async {
    final first = await stored('A1', 0, 'A', 'media.mp4');
    final second = await stored('A2', 1, 'A', 'media.mp4');
    final backup = await stored('B2', 1, 'B', 'media.mp4');
    source.pendingCatalog = Completer<List<SourceChapter>>();
    try {
      await start(initialMedia: DownloadedVideoPlayback(first.uri).media('下载'));
      final next = await request('next').timeout(const Duration(seconds: 2));
      expect((next['media'] as Map)['url'], second.uri.toString());
      final lines = await request('lines').timeout(const Duration(seconds: 2));
      expect((lines['items'] as List).map((e) => e['id']), ['A', 'B']);
      final switched = await request('line', {'id': 'B'}).timeout(const Duration(seconds: 2));
      expect((switched['media'] as Map)['url'], backup.uri.toString());
      expect(source.resolved, isEmpty);
    } finally {
      source.pendingCatalog!.complete(source.episodes);
    }
  });
  test('the first menu in downloaded playback includes promptly available online episodes', () async {
    final first = await stored('A1', 0, 'A', 'media.mp4');
    await start(initialMedia: DownloadedVideoPlayback(first.uri).media('下载'));
    final list = await request('episodes');
    expect((list['items'] as List).map((e) => e['id']), ['A1', 'A2']);
  });
  test('a removed episode stays selectable from its local copy beside online episodes', () async {
    final third = await stored('A3', 2, 'A', 'media.mp4');
    await start();
    final list = await request('episodes');
    expect((list['items'] as List).map((e) => e['id']), ['A1', 'A2', 'A3']);
    expect(((await request('next'))['media'] as Map)['url'], contains('/A2.'));
    expect(((await request('next'))['media'] as Map)['url'], third.uri.toString());
    expect(session.target?.chapterIndex, 2);
    expect(source.resolved, ['A2']);
  });
  test('next follows the online catalog when an older download shares its index', () async {
    final old = await stored('oldA2', 1, 'A', 'media.mp4');
    await start();
    final list = await request('episodes');
    expect((list['items'] as List).map((e) => e['id']), ['A1', 'A2', 'oldA2']);
    expect(((await request('next'))['media'] as Map)['url'], contains('/A2.'));
    expect(((await request('episode', {'id': 'oldA2'}))['media'] as Map)['url'], old.uri.toString());
    expect(source.resolved, ['A2']);
  });
  for (final uri in [
    Uri.parse('file:///downloads/movie.mp4'),
    Uri.parse('http://127.0.0.1:43002/session/index.m3u8'),
  ]) {
    test(
      'retrying a downloaded ${uri.scheme} episode keeps its offline address',
      () async {
        await start(initialMedia: DownloadedVideoPlayback(uri).media('下载'));
        await progress(37);
        final media = (await request('retry'))['media'] as Map;
        expect(media['sourceUrl'], uri.toString());
        expect(media['position'], 37);
        expect(source.resolved, isEmpty);
        await request('next');
        await request('retry');
        expect(source.resolved, ['A2', 'A2']);
      },
    );
  }

  test('switching to a headerless quality does not reuse the previous track credentials', () async {
    await start(
      qualities: [
        VideoQuality(
          label: '1080p',
          url: Uri.parse('https://cdn.example/full.m3u8'),
          headers: const {'Authorization': 'track-specific'},
        ),
        VideoQuality(
          label: '720p',
          url: Uri.parse('https://cdn.example/low.m3u8'),
        ),
      ],
    );
    await request('quality', {'id': 0});
    final media = (await request('quality', {'id': 1}))['media'] as Map;
    expect(media['headers'], isEmpty);
  });

  test(
    'manual quality uses fresh matching URLs and headers on retry and next',
    () async {
      VideoQuality quality(String chapter, int height) => VideoQuality(
        label: '${height}p',
        url: Uri.parse('https://cdn.example/$chapter/$height?fresh'),
        headers: {'Authorization': '$chapter-$height'},
      );
      await start(qualities: [quality('initial', 720)]);
      await request('quality', {'id': 0});
      for (final (action, chapter) in [('retry', 'A1'), ('next', 'A2')]) {
        source.blocked[chapter] = Completer<ChapterContent>()
          ..complete(
            VideoContent(
              url: Uri.parse('https://cdn.example/default'),
              qualities: [quality(chapter, 1080), quality(chapter, 720)],
            ),
          );
        final media = (await request(action))['media'] as Map;
        expect(media['url'], quality(chapter, 720).url.toString());
        expect(media['headers'], quality(chapter, 720).headers);
      }
    },
  );

  test('closing during focus acquisition never retains the source', () async {
    final pending = start();
    await session.close();
    await pending;
    expect(SourceRuntimePins.contains(Section.video, 'fixture'), isFalse);
    expect(calls.where((c) => c.method == 'open'), isEmpty);
  });

  test('next episode honors the preset and a manual choice survives reopening', () async {
    final store = VideoPlayerSettingsStore(library);
    store.save(const PlayerSettings(
      defaultQuality: DefaultQuality.hd,
      rememberManualQuality: true,
    ));
    final options = [
      for (final height in [1080, 720])
        VideoQuality(label: '${height}p', url: Uri.parse('https://cdn.example/$height.mp4')),
    ];
    for (final id in ['A1', 'A2']) {
      source.blocked[id] = Completer<ChapterContent>()
        ..complete(VideoContent(url: Uri.parse('https://cdn.example/base'), qualities: options));
    }
    await start();
    expect(((await request('next'))['media'] as Map)['url'], options.last.url.toString());
    await request('quality', {'id': 0});
    expect(store.load().manualQualityLabel, options.first.label);
    await session.close();
    await start();
    expect(((await request('retry'))['media'] as Map)['url'], options.first.url.toString());
  });

  test(
    'direct video keeps its playhead across quality changes and retry',
    () async {
      final original = Uri.parse('https://example.com/a.mp4');
      final other = Uri.parse('https://example.com/b.mp4');
      session = NativeVideoSourceSession(
        media: PlayerMedia(uri: original),
        library: library,
        qualities: [VideoQuality(label: '720p', url: other)],
        bridge: bridge,
        prepareMedia: (media, _) async => media,
      );
      addTearDown(session.close);
      await session.open();
      await progress(15);
      final changed = (await request('quality', {'id': 0}))['media'] as Map;
      expect(changed['position'], 15);
      await progress(25, identity: changed['identity'] as String);
      final retried = (await request('retry'))['media'] as Map;
      expect(retried['position'], 25);
      expect(changed['identity'], (opened['media'] as Map)['identity']);
      expect(retried['url'], other.toString());
      expect(source.resolved, isEmpty);
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
  test('switching lines from a fractional episode transfers progress only to the same episode', () async {
    source.episodes = const [
      SourceChapter(id: 'A1', title: 'S01E03.5', line: 'A'),
      SourceChapter(id: 'B3', title: '第3集', line: 'B'),
      SourceChapter(id: 'C3', title: '第03.5集', line: 'C'),
    ];
    await start();
    await progress(18);
    expect((await request('line', {'id': 'B'}))['media'], isNull);
    expect(session.target?.chapterId, 'A1');
    expect(source.resolved, isEmpty);
    final switched = (await request('line', {'id': 'C'}))['media'] as Map;
    expect(switched['position'], 18);
    expect(session.target?.chapterId, 'C3');
  });
  test('switching lines cannot carry the playhead from part one to part two', () async {
    source.episodes = const [
      SourceChapter(id: 'A1', title: '第3集（上）', line: 'A'),
      SourceChapter(id: 'B1', title: '第3集（下）', line: 'B'),
      SourceChapter(id: 'C1', title: '第03集 上', line: 'C'),
    ];
    await start();
    await progress(18);
    expect((await request('line', {'id': 'B'}))['media'], isNull);
    expect(session.target?.chapterId, 'A1');
    expect(source.resolved, isEmpty);
    expect(((await request('line', {'id': 'C'}))['media'] as Map)['position'], 18);
    expect(source.resolved, ['C1']);
  });
  for (final (action, arguments) in [
    ('quality', <String, Object?>{'id': 0}),
    ('line', <String, Object?>{'id': 'B'}),
    ('retry', <String, Object?>{}),
    ('kernel', <String, Object?>{'id': 'mpv'}),
  ]) {
    test('$action uses the most recent playhead when media preparation finishes', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var switching = false;
      await start(
        qualities: [VideoQuality(label: '720p', url: Uri.parse('https://example.test/720.m3u8'))],
        prepare: (media, _) async {
          if (switching) {
            entered.complete();
            await release.future;
          }
          return media;
        },
      );
      await progress(12);
      switching = true;
      final result = request(action, arguments);
      await entered.future;
      await progress(24, type: 'seek');
      release.complete();
      final media = (await result)['media'] as Map;
      expect(media['position'], 24);
      if (action == 'line') {
        switching = false;
        final retry = (await request('retry'))['media'] as Map;
        expect(retry['position'], 24);
      }
    });
  }
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
  testWidgets(
    'a media preparation that finishes after the request timeout cannot change the episode',
    (tester) async {
      downloads = _EmptyDownloads();
      final preparing = Completer<PlayerMedia>();
      await tester.runAsync(
        () => start(
          prepare: (media, _) async =>
              media.uri.path.contains('A2') ? preparing.future : media,
        ),
      );
      final pending = request('next');
      await tester.pump();
      expect(source.resolved, contains('A2'));
      await tester.pump(const Duration(seconds: 21));
      expect((await pending)['error'], isNotNull);
      preparing.complete(
        PlayerMedia(uri: Uri.parse('https://example/late.mp4')),
      );
      await tester.pump();
      expect(session.target?.chapterId, 'A1');
    },
  );

  test(
    'returning to an episode resets the position used by immediate retry',
    () async {
      await start();
      await progress(41);
      await request('next');
      expect(((await request('previous'))['media'] as Map)['position'], 0);
      expect(((await request('retry'))['media'] as Map)['position'], 0);
    },
  );
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
        'autoNext': false,
        'hardwareDecoding': false,
      });
      await native('event', {
        'session': opened['session'],
        'type': 'settings',
        'kernel': 'mpv',
        'speed': 99.0,
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

class _EmptyDownloads extends VideoDownloadCenter {
  @override
  Future<void> boot() async {}
  @override
  Future<DownloadedVideoPlayback?> completedPlayback(String sourceId, String itemId, String chapterId) async => null;
}

class _Source extends MockDataSource implements DanmakuCapable {
  _Source() : super(section: Section.video);
  final blocked = <String, Completer<ChapterContent>>{};
  final resolved = <String>[];
  bool catalogOffline = false;
  Completer<List<SourceChapter>>? pendingCatalog;
  @override
  String get id => 'fixture';
  List<SourceChapter> episodes = const [
      SourceChapter(id: 'A1', title: '第1集', line: 'A'),
      SourceChapter(id: 'A2', title: '第2集', line: 'A'),
      SourceChapter(id: 'B1', title: '第1集', line: 'B'),
  ];
  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    if (catalogOffline) throw StateError('catalog offline');
    return pendingCatalog?.future ?? Future.value(episodes);
  }

  @override
  Future<SourceDetail?> detail(String itemId) async => catalogOffline
      ? throw StateError('catalog offline')
      : super.detail(itemId);
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
