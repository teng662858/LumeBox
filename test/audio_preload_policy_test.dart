import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_background/just_audio_background.dart';
import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/session/section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tracks = [
    for (var i = 0; i < 3; i++)
      AudioBookTrack(
        id: 'e$i',
        album: '测试书',
        episode: ResourceEpisode(
          id: 'e$i',
          title: '第$i集',
          url: Uri.parse('https://fixture.invalid/$i.mp3'),
        ),
      ),
  ];
  late _NativeAudio native;
  late JustAudioBookPlayer player;
  late Future<void> Function() configureSession;
  setUp(() {
    native = _NativeAudio();
    configureSession = () async {};
    player = JustAudioBookPlayer(player: native, configureSession: () => configureSession());
  });
  tearDown(() async {
    await player.release();
    await player.disposeNative();
    await native.states.close();
    await native.indices.close();
    await native.errors.close();
    MediaPreload.instance.update(audio: true);
  });

  for (final preload in [true, false]) {
    test('释放时仍在配置音频会话，晚到的装载不能重建队列（预载 $preload）', () async {
      MediaPreload.instance.update(audio: preload);
      final gate = Completer<void>();
      configureSession = () => gate.future;
      final loading = player.load(tracks, index: 1);
      await player.release();
      gate.complete();
      await loading;
      expect(native.singles, isEmpty);
      expect(native.batches, isEmpty);
      await MediaPreload.instance.clear();
      expect(native.singles, isEmpty, reason: '已释放的装载不能重新注册缓存清理回调');
    });

    test('较早的会话配置晚完成时不能替换新书队列（预载 $preload）', () async {
      MediaPreload.instance.update(audio: preload);
      final gate = Completer<void>();
      configureSession = () => gate.future;
      final old = player.load(tracks, index: 1);
      configureSession = () async {};
      await player.load([tracks.last]);
      gate.complete();
      await old;
      final sources = preload ? native.batches.single : native.singles;
      expect(sources, hasLength(1));
      final source = sources.single as ja.UriAudioSource;
      final tag = source.tag as MediaItem;
      expect(tag.id, tracks.last.id);
      expect(player.playhead.index, 0);
    });
  }

  test('音频关闭预载后只提交当前集，手动和自动切集保持全局集数', () async {
    MediaPreload.instance.update(audio: false);
    final observed = <int?>[];
    final subscription = player.index.listen(observed.add);
    await player.load(tracks, index: 1);
    await Future<void>.delayed(Duration.zero);
    expect(native.batches, isEmpty);
    expect(native.singles.length, 1);
    expect(observed.last, 1);
    await player.play();
    native.completeChapter();
    await Future<void>.delayed(Duration.zero);
    expect(native.singles.length, 2);
    expect(observed.last, 2);
    await player.previous();
    await Future<void>.delayed(Duration.zero);
    expect(observed.last, 1);
    await subscription.cancel();
  });

  test('暂停在章节末尾时不自动切章或恢复播放', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    native.completeChapter();
    await Future<void>.delayed(Duration.zero);
    expect(native.singles, hasLength(1));
    expect(native.playing, isFalse);
  });

  for (final preload in [true, false]) {
    test('最后一章播完显示暂停，点击播放从该章开头重播（预载 $preload）', () async {
      MediaPreload.instance.update(audio: preload);
      await player.load(tracks, index: 2);
      await player.play();
      native.completeChapter();
      await Future<void>.delayed(Duration.zero);
      expect(native.playing, isFalse);
      expect(native.position, const Duration(minutes: 10));
      await player.play();
      expect(native.playing, isTrue);
      expect(native.position, Duration.zero);
      expect(player.playhead.index, 2);
    });
  }

  test('重播定位尚未完成时暂停，不会在定位完成后重新出声', () async {
    await player.load(tracks, index: 2);
    native.processingState = ja.ProcessingState.completed;
    final gate = native.seekGate = Completer<void>();
    final replay = player.play();
    await player.pause();
    gate.complete();
    await replay;
    expect(native.seekCalls, 1);
    expect(native.playing, isFalse);
  });

  test('单集模式下原生索引持续为零也能通知后台自动切章', () async {
    MediaPreload.instance.update(audio: false);
    final observed = <int?>[];
    final subscription = player.index.listen(observed.add);
    addTearDown(subscription.cancel);
    await player.load(tracks);
    await player.play();
    native.completeChapter();
    await Future<void>.delayed(Duration.zero);
    expect(native.singles, hasLength(2));
    expect(observed.last, 1);
    expect(player.playhead.index, 1);
  });

  test('自动切章失败后显示原因，重新加载从失败章节开头播放', () async {
    MediaPreload.instance.update(audio: false);
    final settings = _MemorySettings();
    final session = AudioBookSession(
      factory: () => player,
      settings: settings,
      initialize: () async {},
    );
    addTearDown(() async {
      await session.shutdown();
      session.dispose();
    });
    final book = MediaResource(
      id: 'book', title: '测试书', kind: ResourceKind.audioBook,
      destination: Section.video, episodes: tracks.map((t) => t.episode).toList(),
    );
    await session.open(book, tracks);
    final gate = native.pendingLoad = Completer<Duration?>();
    native.completeChapter();
    await Future<void>.delayed(Duration.zero);
    expect(native.singles, hasLength(2));
    native.pendingLoad = null;
    gate.completeError(StateError('load failed'));
    await Future<void>.delayed(Duration.zero);
    expect(session.error, contains('第1集'));
    expect(native.playing, isFalse);
    expect(session.current, 1);
    expect(settings.positions['book']?['position'], 0);
    await session.retry();
    expect(session.error, isNull);
    expect(player.playhead.index, 1);
    expect(native.position, Duration.zero);
    expect(native.playing, isTrue);
  });

  test('自动切章缓冲时手动选集，旧章节失败不会打断新选择', () async {
    MediaPreload.instance.update(audio: false);
    final errors = <AudioBookFailure>[];
    final subscription = player.errors.listen(errors.add);
    addTearDown(subscription.cancel);
    await player.load(tracks);
    await player.play();
    final gate = native.pendingLoad = Completer<Duration?>();
    native.completeChapter();
    await Future<void>.delayed(Duration.zero);
    final selected = player.seek(const Duration(seconds: 23), index: 2);
    native.errors.add(ja.PlayerException(1, 'old chapter unavailable', 0));
    native.pendingLoad = null;
    gate.completeError(StateError('old load failed'));
    await selected;
    expect(errors, isEmpty);
    expect(player.playhead.index, 2);
    expect(native.position, const Duration(seconds: 23));
    expect(native.playing, isTrue);
  });

  test('切章缓冲期间的暂停优先于此前的续播请求', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    await player.play();
    native.pendingLoad = Completer<Duration?>();
    final change = player.next();
    expect(player.playhead.index, isNull);
    await player.pause();
    native.pendingLoad!.complete(const Duration(minutes: 10));
    await change;
    expect(player.playhead.index, 1);
    expect(native.playing, isFalse);
  });

  test('单集模式缓冲期间再选一章，最终使用后选的章节与时间', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    final gate = native.pendingLoad = Completer<Duration?>();
    final first = player.seek(Duration.zero, index: 1);
    final second = player.seek(const Duration(seconds: 37), index: 2);
    gate.complete(const Duration(minutes: 10));
    await Future.wait([first, second]);
    expect(native.singles, hasLength(3));
    expect(native.position, const Duration(seconds: 37));
  });

  test('释放已开始时，等待中的选集不能再把章节装回引擎', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    final gate = native.pendingLoad = Completer<Duration?>();
    final first = player.seek(Duration.zero, index: 1);
    final second = player.seek(Duration.zero, index: 2);
    final release = player.release();
    gate.complete(const Duration(minutes: 10));
    await Future.wait([first, second, release]);
    expect(native.singles, hasLength(2));
  });

  test('先选的章节加载失败后，只执行等待中的最后一次选择', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    final gate = native.pendingLoad = Completer<Duration?>();
    final first = expectLater(player.next(), throwsStateError);
    final skipped = player.seek(Duration.zero, index: 0);
    final latest = player.seek(const Duration(seconds: 27), index: 2);
    native.pendingLoad = null;
    gate.completeError(StateError('失效章节'));
    await Future.wait([first, skipped, latest]);
    expect(native.singles, hasLength(3));
    expect(native.position, const Duration(seconds: 27));
  });

  test('五千章目录只提交当前集，切集保持目录索引与恢复位置', () async {
    MediaPreload.instance.update(audio: true);
    final catalog = [
      for (var i = 0; i < 5329; i++)
        AudioBookTrack(
          id: 'long-$i',
          album: '长篇听书',
          episode: ResourceEpisode(
            id: '$i',
            title: '$i',
            url: Uri.parse('https://fixture.invalid/$i.mp3'),
          ),
        ),
    ];
    final observed = <int?>[];
    final subscription = player.index.listen(observed.add);
    await player.load(
      catalog,
      index: 3100,
      position: const Duration(seconds: 42),
    );
    await Future<void>.delayed(Duration.zero);
    expect(native.batches, isEmpty);
    expect(native.singles, hasLength(1));
    expect(observed.last, 3100);
    expect(native.position, const Duration(seconds: 42));
    await player.next();
    await Future<void>.delayed(Duration.zero);
    expect(observed.last, 3101);
    await player.previous();
    await Future<void>.delayed(Duration.zero);
    expect(observed.last, 3100);
    await subscription.cancel();
  });

  test('开启预载提交完整惰性队列；清理后仅保留当前集和播放位置', () async {
    MediaPreload.instance.update(audio: true);
    await player.load(tracks, index: 1, position: const Duration(seconds: 19));
    await player.play();
    expect(native.batches.single.length, 3);
    await MediaPreload.instance.clear();
    expect(native.singles.length, 1);
    expect(native.position, const Duration(seconds: 19));
    expect(native.playing, true);
    final observed = <int?>[];
    final subscription = player.index.listen(observed.add);
    await player.next();
    await Future<void>.delayed(Duration.zero);
    expect(observed.last, 2);
    await subscription.cancel();
  });
}

class _MemorySettings extends AudioBookSettings {
  @override
  Future<void> load() async {}
  @override
  Future<void> save() async {}
}

/// Implements the native engine boundary, so the real playlist/policy/proxy
/// wiring is exercised without pretending to decode audio on Windows.
class _NativeAudio implements ja.AudioPlayer {
  Completer<Duration?>? pendingLoad;
  final states = StreamController<ja.PlayerState>.broadcast();
  final indices = StreamController<int?>.broadcast();
  final errors = StreamController<ja.PlayerException>.broadcast(sync: true);
  final singles = <ja.AudioSource>[];
  final batches = <List<ja.AudioSource>>[];
  @override
  int? currentIndex = 0;
  @override
  Duration position = Duration.zero;
  @override
  ja.ProcessingState processingState = ja.ProcessingState.ready;
  Completer<void>? seekGate;
  int seekCalls = 0;
  void completeChapter() {
    position = const Duration(minutes: 10);
    processingState = ja.ProcessingState.completed;
    states.add(ja.PlayerState(playing, processingState));
  }

  @override
  Future<void> seek(Duration? time, {int? index}) async {
    seekCalls++;
    await seekGate?.future;
    position = time ?? Duration.zero;
    processingState = ja.ProcessingState.ready;
  }
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  ja.PlaybackEvent get playbackEvent => ja.PlaybackEvent(
    processingState: processingState,
    currentIndex: currentIndex,
    updatePosition: position,
    duration: const Duration(minutes: 10),
  );
  @override
  bool playing = false;
  @override
  Stream<ja.PlayerState> get playerStateStream => states.stream;
  @override
  Stream<bool> get playingStream => states.stream.map((state) => state.playing);
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ja.PlayerException> get errorStream => errors.stream;
  @override
  Stream<int?> get currentIndexStream => indices.stream.distinct();
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #setAudioSource ||
        call.memberName == #setAudioSources) {
      if (call.memberName == #setAudioSource) {
        singles.add(call.positionalArguments.single as ja.AudioSource);
      } else {
        batches.add(
          List<ja.AudioSource>.from(call.positionalArguments.single as List),
        );
      }
      currentIndex = call.namedArguments[#initialIndex] as int? ?? 0;
      processingState = ja.ProcessingState.ready;
      position =
          call.namedArguments[#initialPosition] as Duration? ?? Duration.zero;
      indices.add(currentIndex);
      return pendingLoad?.future ??
          Future<Duration?>.value(const Duration(minutes: 10));
    }
    if (call.memberName == #play) {
      playing = true;
      return Future<void>.value();
    }
    if ([#stop, #pause].contains(call.memberName)) {
      playing = false;
      return Future<void>.value();
    }
    if ([#clearAudioSources, #dispose].contains(call.memberName)) {
      return Future<void>.value();
    }
    return super.noSuchMethod(call);
  }
}
