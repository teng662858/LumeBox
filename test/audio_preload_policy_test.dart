import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/media/media_library.dart';

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
  setUp(() {
    native = _NativeAudio();
    player = JustAudioBookPlayer(player: native, configureSession: () async {});
  });
  tearDown(() async {
    await player.release();
    await player.disposeNative();
    await native.states.close();
    await native.indices.close();
    MediaPreload.instance.update(audio: true);
  });

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
    native.states.add(ja.PlayerState(true, ja.ProcessingState.completed));
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
    native.states.add(ja.PlayerState(false, ja.ProcessingState.completed));
    await Future<void>.delayed(Duration.zero);
    expect(native.singles, hasLength(1));
    expect(native.playing, isFalse);
  });

  test('切章缓冲期间的暂停优先于此前的续播请求', () async {
    MediaPreload.instance.update(audio: false);
    await player.load(tracks);
    await player.play();
    native.pendingLoad = Completer<Duration?>();
    final change = player.next();
    await player.pause();
    native.pendingLoad!.complete(const Duration(minutes: 10));
    await change;
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

/// Implements the native engine boundary, so the real playlist/policy/proxy
/// wiring is exercised without pretending to decode audio on Windows.
class _NativeAudio implements ja.AudioPlayer {
  Completer<Duration?>? pendingLoad;
  final states = StreamController<ja.PlayerState>.broadcast();
  final indices = StreamController<int?>.broadcast();
  final singles = <ja.AudioSource>[];
  final batches = <List<ja.AudioSource>>[];
  @override
  int? currentIndex = 0;
  @override
  Duration position = Duration.zero;
  @override
  bool playing = false;
  @override
  Stream<ja.PlayerState> get playerStateStream => states.stream;
  @override
  Stream<int?> get currentIndexStream => indices.stream;
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
