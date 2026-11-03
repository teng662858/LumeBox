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
    settings = AudioBookSettings();
    await settings.load();
    player = _AudioPlayer();
    session = AudioBookSession(
      factory: () => player,
      initialize: () async {},
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
  int current = 0, releases = 0;
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
