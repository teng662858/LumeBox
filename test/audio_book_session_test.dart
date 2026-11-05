import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/media/playback_focus.dart';
import 'package:lume_box/core/session/section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AudioBookSettings settings;
  late _AudioPlayer player;
  late AudioBookSession session;
  final tracks = [
    for (var i = 0; i < 3; i++)
      AudioBookTrack(
        id: 'c$i',
        album: '书',
        episode: ResourceEpisode(
          id: 'c$i',
          title: '第$i集',
          url: Uri.parse('https://example.com/$i.mp3'),
        ),
      ),
  ];
  final resource = MediaResource(
    id: 'book',
    title: '书',
    kind: ResourceKind.audioBook,
    destination: Section.video,
    episodes: tracks.map((t) => t.episode).toList(),
  );
  _Timer? scheduled;
  int initializationFailures = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-audio-session-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => null,
        );
    initializationFailures = 0;
    settings = AudioBookSettings();
    await settings.load();
    player = _AudioPlayer();
    session = AudioBookSession(
      factory: () => player,
      initialize: () async {
        if (initializationFailures > 0) {
          initializationFailures--;
          throw const AudioBookFailure('初始化失败');
        }
      },
      settings: settings,
      schedule: (duration, callback) => scheduled = _Timer(duration, callback),
    );
  });
  tearDown(() async {
    await session.shutdown();
    session.dispose();
    await player.close();
    await root.delete(recursive: true);
  });
  test('one facade supports queue, seek, speed, pause/resume and persisted progress', () async {
    await session.load(resource, tracks, index: 1);
    await session.play();
    expect(session.playing, true);
    expect(session.current, 1);
    await session.seek(const Duration(seconds: 47));
    expect(session.position.inSeconds, 47);
    await session.setSpeed(1.5);
    expect(player.rate, 1.5);
    await session.next();
    expect(session.current, 2);
    await session.previous();
    expect(session.current, 1);
    await session.seek(const Duration(seconds: 47));
    await session.pause();
    expect(session.playing, false);
    await session.release();
    expect(settings.positions['book']!['index'], 1);
    expect(settings.positions['book']!['position'], 47000);
    expect(settings.positions['book']!['updatedAt'], greaterThan(0));
    await session.play();
    expect(session.current, 1);
    expect(session.position.inSeconds, 47);
    expect(session.playing, true);
    expect(player.lastTracks, hasLength(3));
    final reopened = AudioBookSettings();
    await settings.save();
    await reopened.load();
    expect(reopened.speed, 1.5);
    expect(reopened.engine, AudioBookEngine.justAudio);
  });
  test(
    'detail reopen preserves the active chapter and paused position',
    () async {
      await session.open(resource, tracks, index: 1);
      await session.seek(const Duration(seconds: 47));
      await session.pause();
      final loads = player.loads;
      await session.open(resource, tracks, index: 1);
      expect(player.loads, loads);
      expect(session.position.inSeconds, 47);
      expect(session.playing, false);
    },
  );

  test(
    'detail resume restores saved time while explicit selection restarts',
    () async {
      settings.positions[resource.id] = {'index': 1, 'position': 47000};
      await session.open(resource, tracks, index: 1);
      expect(session.position.inSeconds, 47);
      await session.open(resource, tracks, index: 1, restart: true);
      expect(session.position, Duration.zero);
      await session.open(resource, tracks, index: 2);
      expect(session.current, 2);
      expect(session.position, Duration.zero);
    },
  );

  test('failed loading can retry the same chapter and resume time', () async {
    settings.positions[resource.id] = {'index': 1, 'position': 47000};
    player.failLoads = 1;
    await session.open(resource, tracks, index: 1);
    expect(session.error, isNotNull);
    expect(session.current, 1);
    expect(session.position.inSeconds, 47);
    await session.retry();
    await Future<void>.delayed(Duration.zero);
    expect(session.error, isNull);
    expect(session.position.inSeconds, 47);
    expect(session.playing, true);
    expect(player.loads, 2);
  });

  test('switching resources isolates old events while preparing', () async {
    await session.open(resource, tracks, index: 1);
    await session.seek(const Duration(seconds: 47));
    final next = MediaResource(
      id: 'next',
      title: '下一本',
      kind: ResourceKind.audioBook,
      destination: Section.video,
      episodes: resource.episodes,
    );
    final gate = Completer<void>();
    player.beforeLoad = () => gate.future;
    final task = session.open(next, tracks, index: 2);
    await Future<void>.delayed(Duration.zero);
    expect(session.resource?.id, 'next');
    expect(session.loading, true);
    expect(session.playing, false);
    expect(session.duration, Duration.zero);
    expect(settings.positions['book']?['position'], 47000);
    gate.complete();
    await task;
    expect(session.current, 2);
    expect(session.position, Duration.zero);
  });

  test(
    'initialization failure retains the requested resume point for retry',
    () async {
      settings.positions[resource.id] = {'index': 2, 'position': 47000};
      initializationFailures = 1;
      await session.open(resource, tracks, index: 2);
      expect(session.error, '初始化失败');
      expect(session.current, 2);
      expect(session.position.inSeconds, 47);
      await session.retry();
      expect(session.error, isNull);
      expect(session.current, 2);
      expect(session.position.inSeconds, 47);
    },
  );

  test(
    'loading reports parsing and buffering stages for the selected audio',
    () async {
      final gate = Completer<ResolvedAudio>();
      player.resolveTracks = true;
      final task = session.open(resource, [
        AudioBookTrack(
          id: 'resolved',
          album: '书',
          episode: tracks.first.episode,
          resolve: () => gate.future,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(session.loadingMessage, '正在解析音频地址…');
      expect(session.loading, true);
      gate.complete(ResolvedAudio(Uri.parse('https://example.com/0.mp3')));
      await task;
      expect(session.loadingMessage, '正在缓冲音频…');
      expect(session.loading, false);
      expect(session.error, isNull);
    },
  );

  test('progress ticks update only progress listeners', () async {
    await session.open(resource, tracks);
    await session.pause();
    var pageUpdates = 0, progressUpdates = 0;
    session.addListener(() => pageUpdates++);
    session.progress.addListener(() => progressUpdates++);
    for (var n = 1; n < 10; n++) {
      player.p.add(Duration(milliseconds: n * 100));
    }
    expect(progressUpdates, 9);
    expect(pageUpdates, 0);
  });

  test(
    'chapter IDs survive reordered catalogs and missing chapters start safely',
    () async {
      await session.open(resource, tracks, index: 1);
      await session.seek(const Duration(seconds: 47));
      await session.pause();
      await session.release();
      final reordered = [tracks[2], tracks[0], tracks[1]];
      final next = MediaResource(
        id: resource.id,
        title: resource.title,
        kind: resource.kind,
        destination: resource.destination,
        episodes: reordered.map((t) => t.episode).toList(),
      );
      await session.open(next, reordered);
      expect(session.current, 2);
      expect(session.position.inSeconds, 47);
      final restored = AudioBookSettings();
      await session.pause();
      await settings.save();
      await restored.load();
      expect(restored.chapterIds[resource.id], 'c1');
      expect(restored.indexFor(next), 2);
      final missing = MediaResource(
        id: resource.id,
        title: resource.title,
        kind: resource.kind,
        destination: resource.destination,
        episodes: [tracks[0].episode],
      );
      await session.release();
      await session.open(missing, [tracks[0]]);
      expect(session.current, 0);
      expect(session.position, Duration.zero);
    },
  );

  test('empty catalogs report a recoverable error', () async {
    await session.open(resource, []);
    expect(session.error, '资源没有可播放的章节');
    expect(session.loading, false);
    expect(player.loads, 0);
  });

  test('sleep timer stops output and can be cancelled without enabling another library', () async {
    await session.load(resource, tracks);
    await session.play();
    session.setSleep(30);
    expect(scheduled!.duration, const Duration(minutes: 30));
    final timer = scheduled!;
    timer.fire();
    await Future<void>.delayed(Duration.zero);
    expect(session.playing, false);
    expect(session.sleepAt, null);
    session.setSleep(15);
    final cancelled = scheduled!;
    session.setSleep(0);
    expect(cancelled.isActive, false);
  });
  test('焦点让出会作废正在加载的音频，晚到结果不能恢复播放', () async {
    final gate = Completer<void>();
    player.beforeLoad = () => gate.future;
    final opening = session.open(resource, tracks);
    while (player.loads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await PlaybackFocus.acquire('video');
    gate.complete();
    await opening;
    expect(session.playing, false);
    expect(session.loading, false);
    expect(player.lastTracks, isEmpty);
    expect(PlaybackFocus.owner, 'video');
  });

  test('释放的会话不再响应后续媒体焦点变化', () async {
    await session.load(resource, tracks);
    await session.shutdown();
    session.dispose();
    await PlaybackFocus.acquire('video');
    // The shared teardown can safely dispose a replacement session.
    session = AudioBookSession(
      factory: () => player,
      initialize: () async {},
      settings: settings,
    );
  });

  test(
    'TTS/video focus releases the audiobook playlist before switching sources',
    () async {
      await session.load(resource, tracks);
      await session.play();
      await PlaybackFocus.acquire('tts');
      expect(player.releases, greaterThan(0));
      expect(session.playing, false);
      expect(player.lastTracks, isEmpty);
    },
  );
}

class _Timer implements Timer {
  _Timer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool active = true;
  void fire() {
    if (active) {
      active = false;
      callback();
    }
  }

  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  @override
  void cancel() => active = false;
}

class _AudioPlayer implements AudioBookPlayer {
  final p = StreamController<Duration>.broadcast(sync: true);
  final d = StreamController<Duration?>.broadcast(sync: true);
  final b = StreamController<bool>.broadcast(sync: true);
  final i = StreamController<int?>.broadcast(sync: true);
  final e = StreamController<String>.broadcast(sync: true);
  List<AudioBookTrack> lastTracks = [];
  int current = 0, releases = 0, loads = 0, failLoads = 0;
  Future<void> Function()? beforeLoad;
  bool resolveTracks = false;
  double rate = 1;
  @override
  Stream<Duration> get position => p.stream;
  @override
  Stream<Duration?> get duration => d.stream;
  @override
  Stream<bool> get playing => b.stream;
  @override
  Stream<int?> get index => i.stream;
  @override
  Stream<String> get errors => e.stream;
  @override
  Future<void> load(
    List<AudioBookTrack> tracks, {
    int index = 0,
    Duration position = Duration.zero,
  }) async {
    loads++;
    await beforeLoad?.call();
    if (failLoads > 0) {
      failLoads--;
      throw const AudioBookFailure('测试加载失败');
    }
    if (resolveTracks) await tracks[index].resolve!();
    lastTracks = tracks;
    current = index;
    i.add(index);
    p.add(position);
    d.add(const Duration(minutes: 5));
  }

  @override
  Future<void> play() async => b.add(true);
  @override
  Future<void> pause() async => b.add(false);
  @override
  Future<void> stop() async => b.add(false);
  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (index != null) {
      current = index;
      i.add(index);
    }
    p.add(position);
  }

  @override
  Future<void> next() async {
    current++;
    i.add(current);
    p.add(Duration.zero);
  }

  @override
  Future<void> previous() async {
    current--;
    i.add(current);
    p.add(Duration.zero);
  }

  @override
  Future<void> speed(double speed) async {
    rate = speed;
  }

  @override
  Future<void> release() async {
    releases++;
    lastTracks = [];
    b.add(false);
    i.add(null);
    p.add(Duration.zero);
  }

  Future<void> close() async {
    await p.close();
    await d.close();
    await b.close();
    await i.close();
    await e.close();
  }
}
