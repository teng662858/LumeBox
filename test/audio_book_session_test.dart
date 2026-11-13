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

  Future<void> openBookmark() => session.open(
    resource,
    tracks,
    index: 1,
    initialPosition: const Duration(seconds: 63),
  );

  test('bookmark starts at its saved time before the first play command', () async {
    Duration? firstAudiblePosition;
    player.beforePlay = () async => firstAudiblePosition ??= session.position;
    await openBookmark();
    expect(firstAudiblePosition, const Duration(seconds: 63));
  });

  test('a bookmark interrupted by video focus cannot reclaim playback', () async {
    final entered = Completer<void>(), resume = Completer<void>();
    player.beforeLoad = () {
      if (!entered.isCompleted) entered.complete();
      return resume.future;
    };
    final opening = openBookmark();
    await entered.future;
    await PlaybackFocus.acquire('video');
    resume.complete();
    await opening;
    expect(PlaybackFocus.owner, 'video');
    expect(player.loads, 1);
  });

  test('opening a bookmark in the active chapter keeps a paused player paused', () async {
    await session.open(resource, tracks, index: 1);
    await session.pause();
    await openBookmark();
    expect(session.position, const Duration(seconds: 63));
    expect(session.playing, isFalse);
    expect(player.loads, 1);
  });

  test('audio settings can retry a temporary storage failure and recover bookmarks', () async {
    await session.load(resource, tracks, index: 1);
    await session.seek(const Duration(seconds: 39));
    await settings.save();
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async {
            if (++reads == 1) throw PlatformException(code: 'unavailable');
            return root.path;
          },
        );
    final reopened = AudioBookSettings();
    await expectLater(reopened.load(), throwsA(isA<PlatformException>()));
    await reopened.load();
    expect(reopened.positions[resource.id]?['position'], 39000);
  });

  for (final (String label, int? index, Duration? at, bool restart, int expectedIndex, int seconds) in [
    ('自动续听', null, null, false, 2, 73),
    ('指定章节续听', 2, null, false, 2, 73),
    ('从头播放', 2, null, true, 2, 0),
    ('书签', 1, const Duration(seconds: 19), false, 1, 19),
  ]) {
    test('读取进度暂时失败后重试会保留$label的位置', () async {
      final fresh = AudioBookSettings();
      final other = AudioBookSession(
        factory: () => player, settings: fresh, initialize: () async {},
      );
      addTearDown(() async {
        await other.shutdown();
        other.dispose();
      });
      settings.chapterIds[resource.id] = 'c2';
      settings.positions[resource.id] = {'index': 2, 'position': 73000};
      await settings.save();
      var available = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async {
          if (!available) throw PlatformException(code: 'unavailable');
          return root.path;
        },
      );
      await other.open(resource, tracks, index: index, initialPosition: at, restart: restart);
      expect(other.error, isNotNull);
      expect(player.loads, 0);
      available = true;
      await other.retry();
      expect(other.error, isNull);
      expect(other.current, expectedIndex);
      expect(other.position, Duration(seconds: seconds));
      expect(other.playing, true);
    });
  }

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
      player.emitPosition(Duration(milliseconds: n * 100));
    }
    expect(progressUpdates, 9);
    expect(pageUpdates, 0);
  });

  for (final positionFirst in [false, true]) {
    test('自动切章后立即退出会保存新章的时间（先收到${positionFirst ? '进度' : '章节'}）', () async {
      await session.open(resource, tracks);
      await session.seek(const Duration(minutes: 4, seconds: 59));
      player.current = 1;
      player.nativePosition = const Duration(seconds: 2);
      player.nativeDuration = const Duration(minutes: 3);
      if (positionFirst) {
        player.p.add(player.nativePosition);
      } else {
        player.i.add(1);
      }
      // The previous chapter's last notification is delivered late.
      player.p.add(const Duration(minutes: 4, seconds: 59));
      expect(session.progress.value, (player.nativePosition, player.nativeDuration));
      await session.release();
      await settings.save();
      final reopened = AudioBookSettings();
      await reopened.load();
      expect(reopened.chapterIds[resource.id], 'c1');
      expect(reopened.positions[resource.id]?['position'], 2000);
    });
  }

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

  test('opening an empty book stops the audible previous book and keeps its bookmark', () async {
    var audible = false;
    final output = player.playing.listen((value) => audible = value);
    addTearDown(output.cancel);
    await session.open(resource, tracks, index: 1);
    await session.seek(const Duration(seconds: 37));
    expect(audible, isTrue);
    await session.open(resource, [], restart: true);
    expect(session.error, '资源没有可播放的章节');
    expect(audible, isFalse);
    expect(settings.positions[resource.id]?['position'], 37000);
  });

  for (final retry in [false, true]) {
    test(
      'pause during pending ${retry ? "retry" : "open"} cancels autoplay',
      () async {
        if (retry) {
          player.failLoads = 1;
          await session.open(resource, tracks);
        }
        final entered = Completer<void>(), release = Completer<void>();
        player.beforeLoad = () async {
          entered.complete();
          await release.future;
        };
        final loading = retry
            ? session.retry()
            : session.open(resource, tracks);
        await entered.future;
        await session.pause();
        release.complete();
        await loading;
        expect(session.loading, isFalse);
        expect(session.error, isNull);
        expect(session.playing, isFalse);
        await session.play();
        expect(session.playing, isTrue);
      },
    );
  }

  test('a failed seek keeps the last playable resume position', () async {
    await session.open(resource, tracks, index: 1);
    await session.seek(const Duration(seconds: 25));
    player.beforeSeek = () async => throw StateError('seek failed');
    await session.seek(const Duration(seconds: 80));
    expect(session.position.inSeconds, 25);
    expect(settings.positions[resource.id]?['position'], 25000);
    expect(session.error, isNotNull);
  });

  for (final lastFails in [false, true]) {
    test('overlapping audiobook seeks keep the last confirmed position (failure=$lastFails)', () async {
      await session.open(resource, tracks);
      await session.seek(const Duration(seconds: 5));
      final entered = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      player.beforeSeek = () async {
        if (++requests == 1) {
          entered.complete();
          await release.future;
        } else if (lastFails) {
          throw StateError('unavailable');
        }
      };
      final first = session.seek(const Duration(seconds: 15));
      await entered.future;
      final last = session.seek(const Duration(seconds: 90));
      final requested = session.position;
      release.complete();
      await Future.wait([first, last]);
      expect(requested.inSeconds, 90);
      expect(session.position.inSeconds, lastFails ? 15 : 90);
      expect(settings.positions[resource.id]?['position'], lastFails ? 15000 : 90000);
      expect(session.error != null, lastFails);
    });
  }

  test('a pending chapter selection respects a later pause', () async {
    await session.open(resource, tracks);
    final gate = Completer<void>();
    player.beforeSeek = () => gate.future;
    final selecting = session.playChapter(1);
    await session.pause();
    gate.complete();
    await selecting;
    expect(session.playing, isFalse);
  });

  test('failed and superseded seeks never become the audiobook resume point', () async {
    await session.open(resource, tracks);
    await session.seek(const Duration(seconds: 5));
    final gate = Completer<void>();
    var requests = 0;
    player.beforeSeek = () async {
      requests++;
      await gate.future;
      throw StateError('unavailable');
    };
    final first = session.seek(const Duration(seconds: 20));
    final superseded = session.seek(const Duration(seconds: 40));
    final last = session.seek(const Duration(seconds: 60));
    gate.complete();
    await Future.wait([first, superseded, last]);
    expect(requests, 2);
    expect(session.position.inSeconds, 5);
    expect(settings.positions[resource.id]?['position'], 5000);
  });

  test('a failed chapter selection keeps the error without replaying the old chapter', () async {
    await session.load(resource, tracks);
    player.beforeSeek = () async => throw StateError('chapter unavailable');
    await session.playChapter(1);
    await Future<void>.delayed(Duration.zero);
    expect(session.error, '跳转失败，请重试');
    expect(player.loads, 1);
    expect(session.playing, isFalse);
  });

  test('a failed native chapter change preserves the last confirmed chapter and time', () async {
    await session.open(resource, tracks, index: 1);
    await session.seek(const Duration(seconds: 31));
    player.beforeSeek = () async {
      player.current = 2;
      player.i.add(2);
      player.p.add(Duration.zero);
      throw StateError('new chapter unavailable');
    };
    await session.seek(Duration.zero, index: 2);
    player.i.add(2);
    player.p.add(Duration.zero);
    expect(session.current, 1);
    expect(session.position.inSeconds, 31);
    expect(settings.chapterIds[resource.id], 'c1');
    expect(settings.positions[resource.id]?['position'], 31000);
    expect(session.error, isNotNull);
    player.beforeSeek = null;
    await session.seek(const Duration(seconds: 11));
    expect(player.current, 1);
    expect(session.error, isNull);
    await session.seek(const Duration(seconds: 12), index: 2);
    expect(session.current, 2);
    expect(session.error, isNull);
    expect(settings.chapterIds[resource.id], 'c2');
  });

  test('overlapping chapter changes persist the successful chapter when the latest fails', () async {
    await session.open(resource, tracks);
    final entered = Completer<void>(), release = Completer<void>();
    var requests = 0;
    player.beforeSeek = () async {
      if (++requests == 1) {
        entered.complete();
        await release.future;
      } else {
        player.i.add(2);
        throw StateError('unavailable');
      }
    };
    final first = session.seek(const Duration(seconds: 21), index: 1);
    await entered.future;
    final last = session.seek(const Duration(seconds: 80), index: 2);
    release.complete();
    await Future.wait([first, last]);
    expect(session.current, 1);
    expect(session.position.inSeconds, 21);
    expect(settings.chapterIds[resource.id], 'c1');
  });

  test('a queued time seek reselects the playable chapter after a failed switch', () async {
    await session.open(resource, tracks, index: 1);
    final entered = Completer<void>(), release = Completer<void>();
    player.beforeSeek = () async {
      player.beforeSeek = null;
      player.current = 2;
      player.i.add(2);
      entered.complete();
      await release.future;
      throw StateError('unavailable');
    };
    final failed = session.seek(Duration.zero, index: 2);
    await entered.future;
    final retry = session.seek(const Duration(seconds: 17));
    release.complete();
    await Future.wait([failed, retry]);
    expect(player.current, 1);
    expect(session.current, 1);
    expect(session.position.inSeconds, 17);
    expect(session.error, isNull);
  });

  test('a released session selects and plays the requested chapter', () async {
    await session.open(resource, tracks);
    await session.release();
    await session.playChapter(2);
    expect(session.playing, isTrue);
    expect(session.current, 2);
  });

  for (final forward in [true, false]) {
    test('released session can skip ${forward ? "forward" : "back"} while remaining paused', () async {
      await session.open(resource, tracks, index: 1);
      await session.release();
      await (forward ? session.next() : session.previous());
      expect(session.current, forward ? 2 : 0);
      expect(player.lastTracks, hasLength(3));
      expect(session.position, Duration.zero);
      expect(session.playing, isFalse);
    });
  }

  test('a late seek failure belongs only to the previous chapter', () async {
    await session.open(resource, tracks, index: 0);
    final gate = Completer<void>();
    player.beforeSeek = () => gate.future;
    final seeking = session.seek(const Duration(seconds: 30));
    await session.open(resource, tracks, index: 1);
    gate.completeError(StateError('old seek interrupted'));
    await seeking;
    expect(session.current, 1);
    expect(session.seeking, isFalse);
    expect(session.error, isNull);
    expect(session.position, Duration.zero);
  });

  test('an interrupted play cannot report an error on the next book', () async {
    await session.load(resource, tracks);
    final gate = Completer<void>();
    player.beforePlay = () => gate.future;
    final playing = session.play();
    await session.load(resource, tracks, index: 1);
    gate.completeError(StateError('old playback interrupted'));
    await playing;
    expect(session.current, 1);
    expect(session.error, isNull);
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
  Future<void> Function()? beforeSeek, beforePlay;
  bool resolveTracks = false;
  double rate = 1;
  Duration nativePosition = Duration.zero;
  Duration nativeDuration = const Duration(minutes: 5);
  @override
  AudioBookPlayhead get playhead =>
      (index: current, position: nativePosition, duration: nativeDuration);
  void emitPosition(Duration value) {
    nativePosition = value;
    p.add(value);
  }
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
    emitPosition(position);
    d.add(nativeDuration);
  }

  @override
  Future<void> play() async {
    b.add(true);
    if (beforePlay != null) await beforePlay!();
  }

  @override
  Future<void> pause() async => b.add(false);
  @override
  Future<void> stop() async => b.add(false);
  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (beforeSeek != null) await beforeSeek!();
    if (index != null) {
      current = index;
      i.add(index);
    }
    emitPosition(position);
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
