import '../source/source_runtime_pins.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

import '../media/media_library.dart';
import '../media/playback_focus.dart';
import '../util/lume_log.dart';
import '../cache/media_preload.dart';
import 'audio_book_track.dart';
import 'audio_book_proxy.dart';

enum AudioBookEngine { justAudio, audioPlayers }

class AudioBookSettings extends ChangeNotifier {
  static final instance = AudioBookSettings();
  AudioBookEngine engine = AudioBookEngine.justAudio;
  double speed = 1;
  int sleepMinutes = 0;
  final Map<String, Map<String, int>> positions = {};
  final Map<String, String> chapterIds = {};
  int indexFor(MediaResource entry) {
    final chapter = chapterIds[entry.id];
    if (chapter != null) {
      final index = entry.episodes.indexWhere(
        (episode) => episode.id == chapter,
      );
      return index < 0 ? 0 : index;
    }
    return (positions[entry.id]?['index'] ?? 0).clamp(
      0,
      entry.episodes.isEmpty ? 0 : entry.episodes.length - 1,
    );
  }

  Future<void> _saving = Future.value();
  Future<void>? _loading;
  Future<File> get _file async => File(
    '${(await getApplicationSupportDirectory()).path}/audio_book_settings.json',
  );
  Future<void> load() => _loading ??= _load().onError((Object error, StackTrace stack) {
    _loading = null;
    Error.throwWithStackTrace(error, stack);
  });
  Future<void> _load() async {
    final file = await _file;
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        if (data['chapterIds'] is Map) {
          for (final entry in (data['chapterIds'] as Map).entries) {
            if (entry.key is String && entry.value is String) {
              chapterIds[entry.key as String] = entry.value as String;
            }
          }
        }
        final raw = data['speed'];
        if (raw is num && raw.isFinite) speed = raw.toDouble().clamp(.5, 3);
        if (data['sleepMinutes'] is int) {
          sleepMinutes = (data['sleepMinutes'] as int).clamp(0, 240);
        }
        if (data['positions'] is Map) {
          for (final entry in (data['positions'] as Map).entries) {
            if (entry.key is String && entry.value is Map) {
              final row = entry.value as Map;
              positions[entry.key as String] = {
                if (row['updatedAt'] is int)
                  'updatedAt': row['updatedAt'] as int,
                'index': row['index'] is int
                    ? (row['index'] as int).clamp(0, 1000000)
                    : 0,
                'position': row['position'] is int
                    ? (row['position'] as int).clamp(0, 2147483647)
                    : 0,
              };
            }
          }
        }
      }
    } on FormatException {
      /* Presets survive old or corrupt configuration. */
    }
    // The placeholder is never made active, including after malformed restores.
    engine = AudioBookEngine.justAudio;
  }

  Future<void> save() {
    final encoded = jsonEncode({
      'engine': engine.name,
      'speed': speed,
      'sleepMinutes': sleepMinutes,
      'positions': positions,
      'chapterIds': chapterIds,
    });
    final next = _saving.then((_) async {
      final file = await _file;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
    });
    _saving = next.catchError((_) {});
    notifyListeners();
    return next;
  }
}

typedef AudioBookPlayhead = ({int? index, Duration position, Duration? duration});

/// Every future implementation must satisfy this audio-only contract.
abstract interface class AudioBookPlayer {
  AudioBookPlayhead get playhead;
  Stream<Duration> get position;
  Stream<Duration?> get duration;
  Stream<bool> get playing;
  Stream<int?> get index;
  Stream<AudioBookFailure> get errors;
  Future<void> load(
    List<AudioBookTrack> sources, {
    int index = 0,
    Duration position = Duration.zero,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position, {int? index});
  Future<void> next();
  Future<void> previous();
  Future<void> speed(double speed);
  Future<void> release();
}

class JustAudioBookPlayer implements AudioBookPlayer {
  JustAudioBookPlayer({
    ja.AudioPlayer? player,
    Future<void> Function()? configureSession,
  }) : _configureSession = configureSession ?? _configureAudioSession,
       _player =
           player ??
           ja.AudioPlayer(
             audioLoadConfiguration: ja.AudioLoadConfiguration(
               darwinLoadControl: ja.DarwinLoadControl(
                 automaticallyWaitsToMinimizeStalling: false,
                 preferredForwardBufferDuration: Duration(
                   seconds: MediaPreload.instance.bufferSeconds,
                 ),
               ),
               androidLoadControl: ja.AndroidLoadControl(
                 minBufferDuration: const Duration(seconds: 3),
                 maxBufferDuration: Duration(
                   seconds: MediaPreload.instance.bufferSeconds,
                 ),
                 bufferForPlaybackDuration: const Duration(milliseconds: 500),
                 bufferForPlaybackAfterRebufferDuration: const Duration(
                   seconds: 1,
                 ),
                 targetBufferBytes: MediaPreload.instance.mediaBudgetBytes,
               ),
             ),
           );
  final ja.AudioPlayer _player;
  final Future<void> Function() _configureSession;
  static Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
  }

  final _proxy = AudioBookProxy();
  List<ja.AudioSource> _playlist = [];
  bool _singleMode = false;
  Future<void>? _singleLoad;
  int _chapterRequest = 0;
  int _playRequest = 0;
  int _offset = 0;
  final _singleIndex = StreamController<int>.broadcast();
  final _chapterErrors = StreamController<AudioBookFailure>.broadcast(sync: true);
  StreamSubscription<ja.PlayerState>? _completion;
  VoidCallback? _removePreloadClearer;
  static Future<void>? _background;
  static Future<void> initialize() => _background ??= JustAudioBackground.init(
    androidNotificationChannelId: 'lumebox.audioBooks',
    androidNotificationChannelName: '音频播放',
    androidNotificationOngoing: true,
  );
  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<Duration?> get duration => _player.durationStream;
  @override
  Stream<bool> get playing => _player.playingStream;
  @override
  AudioBookPlayhead get playhead {
    final event = _player.playbackEvent;
    return (
      index: _singleMode
          ? (_singleLoad == null && event.currentIndex != null ? _offset : null)
          : event.currentIndex,
      position: _player.position,
      duration: event.duration,
    );
  }

  @override
  Stream<int?> get index => Stream<int?>.multi((events) {
    final native = _player.currentIndexStream.listen((value) {
      if (!_singleMode) events.addSync(value);
    });
    final single = _singleIndex.stream.listen(events.addSync);
    if (_singleMode && _singleLoad == null && _playlist.isNotEmpty) {
      events.add(_offset);
    }
    events.onCancel = () async {
      await native.cancel();
      await single.cancel();
    };
  }).distinct();
  @override
  Stream<AudioBookFailure> get errors => Stream<AudioBookFailure>.multi((events) {
    final native = _player.errorStream.listen((error) {
      LumeLog.warn('[audioBook] 播放器错误: $error');
      // setAudioSource reports load failures to the operation that selected
      // the chapter. It knows whether that selection is still current.
      if (_singleLoad != null) return;
      events.addSync(AudioBookFailure(_proxy.lastError ?? '音频播放失败，请检查源和网络'));
    });
    final chapters = _chapterErrors.stream.listen(events.addSync);
    events.onCancel = () async {
      await native.cancel();
      await chapters.cancel();
    };
  });
  @override
  Future<void> load(
    List<AudioBookTrack> sources, {
    int index = 0,
    Duration position = Duration.zero,
  }) async {
    _playRequest++;
    _chapterRequest++;
    await _configureSession();
    final urls = await _proxy.prepare(sources);
    // Huge native queues serialize thousands of MediaItems on route entry.
    // Keep the Dart catalog intact and load chapters on demand instead.
    _singleMode = !MediaPreload.instance.audio || sources.length > 200;
    _removePreloadClearer ??= MediaPreload.instance.onClear(() async {
      if (_playlist.isEmpty || _singleLoad != null || _singleMode) return;
      final index = _player.currentIndex ?? 0;
      final position = _player.position;
      _singleMode = true;
      await _loadSingle(index, position: position);
    });
    _completion ??= _player.playerStateStream.listen((state) {
      if (_singleLoad != null ||
          _playlist.isEmpty ||
          !state.playing ||
          !_player.playing ||
          state.processingState != ja.ProcessingState.completed ||
          _player.processingState != ja.ProcessingState.completed) {
        return;
      }
      if (_singleMode && _offset + 1 < _playlist.length) {
        unawaited(_loadSingle(_offset + 1, automatic: true));
      } else {
        unawaited(pause().catchError((Object error) {
          LumeLog.warn('[audioBook] 播放结束后暂停失败：$error');
        }));
      }
    });
    try {
      _playlist = [
        for (var i = 0; i < sources.length; i++)
          ja.AudioSource.uri(
            urls[i],
            tag: MediaItem(
              id: sources[i].id,
              title: sources[i].episode.title,
              album: sources[i].album,
              artUri: sources[i].cover == null
                  ? null
                  : Uri.tryParse(sources[i].cover!),
            ),
          ),
      ];
      if (_singleMode) {
        await _loadSingle(index, position: position);
      } else {
        _offset = 0;
        await _player.setAudioSources(
          _playlist,
          initialIndex: index,
          initialPosition: position,
        );
      }
    } catch (_) {
      final message = _proxy.lastError;
      if (message != null) throw AudioBookFailure(message);
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    final request = ++_playRequest;
    if (_player.processingState == ja.ProcessingState.completed) {
      await _player.seek(Duration.zero);
      if (request != _playRequest) return;
    }
    await _player.play();
  }
  @override
  Future<void> pause() {
    _playRequest++;
    return _player.pause();
  }
  Future<void> _loadSingle(
    int index, {
    Duration position = Duration.zero,
    bool automatic = false,
  }) async {
    if (index < 0 || index >= _playlist.length) return;
    final request = ++_chapterRequest;
    final playlist = _playlist;
    final pending = _singleLoad;
    if (pending != null) {
      // A failed chapter must not prevent the next selection from loading.
      await pending.catchError((_) {});
      if (request != _chapterRequest || !identical(playlist, _playlist)) return;
    }
    final load = Future<Duration?>.sync(
      () => _player.setAudioSource(playlist[index], initialPosition: position),
    );
    _singleLoad = load;
    try {
      await load;
      if (identical(playlist, _playlist)) {
        _offset = index;
        _singleIndex.add(index);
      }
    } catch (error) {
      if (!automatic) rethrow;
      if (request != _chapterRequest || !identical(playlist, _playlist)) return;
      LumeLog.warn('[audioBook] 自动切集失败：$error');
      _chapterErrors.add(AudioBookFailure(
        _proxy.lastError ?? '加载失败，请检查源和网络',
        retryChapter: index,
      ));
      try {
        await pause();
      } catch (error) {
        LumeLog.warn('[audioBook] 自动切集失败后暂停失败：$error');
      }
    } finally {
      if (identical(_singleLoad, load)) _singleLoad = null;
    }
  }

  @override
  Future<void> stop() {
    _playRequest++;
    _chapterRequest++;
    return _player.stop();
  }
  @override
  Future<void> seek(Duration value, {int? index}) =>
      _singleMode && index != null
      ? _loadSingle(index, position: value)
      : _player.seek(value, index: index);
  @override
  Future<void> next() =>
      _singleMode ? _loadSingle(_offset + 1) : _player.seekToNext();
  @override
  Future<void> previous() =>
      _singleMode ? _loadSingle(_offset - 1) : _player.seekToPrevious();
  @override
  Future<void> speed(double value) => _player.setSpeed(value);
  @override
  Future<void> release() async {
    _playRequest++;
    _chapterRequest++;
    _playlist = [];
    _removePreloadClearer?.call();
    _removePreloadClearer = null;
    await _completion?.cancel();
    _completion = null;
    await _player.stop();
    await _player.clearAudioSources();
    _proxy.reset();
  }

  Future<void> disposeNative() async {
    await _chapterErrors.close();
    await _singleIndex.close();
    await _proxy.close();
    await _player.dispose();
  }
}

class AudioBookSession extends ChangeNotifier {
  AudioBookSession({
    AudioBookPlayer Function()? factory,
    Future<void> Function()? initialize,
    AudioBookSettings? settings,
    Timer Function(Duration, void Function())? schedule,
  }) : _factory = factory ?? JustAudioBookPlayer.new,
       _initialize = initialize ?? JustAudioBookPlayer.initialize,
       _schedule = schedule ?? Timer.new,
       settings = settings ?? AudioBookSettings.instance {
    PlaybackFocus.register('audioBook', release);
  }
  static final instance = AudioBookSession();
  final AudioBookPlayer Function() _factory;
  final Future<void> Function() _initialize;
  final AudioBookSettings settings;
  final Timer Function(Duration, void Function()) _schedule;
  VoidCallback? _releaseRuntime;
  AudioBookPlayer? _player;
  String? _preloadConfiguration;
  MediaResource? resource;
  Duration position = Duration.zero, duration = Duration.zero;
  int current = 0;
  bool playing = false, loading = false, seeking = false;
  String? error;
  String loadingMessage = '正在加载音频…';
  DateTime? sleepAt;
  Timer? _sleep;
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _generation = 0;
  int _seekRevision = 0;
  static const _seekError = '跳转失败，请重试';
  bool _seekFailed = false;
  Future<void>? _pendingSeek;
  Duration _confirmedSeekPosition = Duration.zero;
  int _pauseRevision = 0;
  Future<void> _loads = Future.value();
  List<AudioBookTrack> _tracks = [];
  // Until settings load, the visible index and time are only placeholders.
  ({int? index, Duration? position, bool resume})? _pendingStart;
  bool _ready = false;
  bool _acceptEvents = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final progress = ValueNotifier<(Duration, Duration)>((
    Duration.zero,
    Duration.zero,
  ));
  void _notifyProgress() => progress.value = (position, duration);
  @override
  void notifyListeners() {
    PlaybackFocus.setPlaying('audioBook', playing);
    _notifyProgress();
    super.notifyListeners();
  }

  @override
  void dispose() {
    PlaybackFocus.unregister('audioBook', release);
    _generation++;
    _acceptEvents = false;
    PlaybackFocus.setPlaying('audioBook', false);
    _releaseRuntime?.call();
    progress.dispose();
    super.dispose();
  }

  AudioBookPlayer? get player => _player;
  Future<void> open(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
    Duration? initialPosition,
    bool restart = false,
  }) async {
    if (!restart &&
        resource?.id == entry.id &&
        _ready &&
        error == null &&
        (index == null || index == current) &&
        sources.length == _tracks.length &&
        List.generate(
          sources.length,
          (i) => i,
        ).every((i) => sources[i].id == _tracks[i].id)) {
      if (initialPosition != null) await seek(initialPosition);
      return;
    }
    final task = load(
      entry,
      sources,
      index: index,
      resume: !restart,
      initialPosition: initialPosition,
    );
    final generation = _generation;
    final pauseRevision = _pauseRevision;
    await task;
    if (generation == _generation &&
        pauseRevision == _pauseRevision &&
        resource?.id == entry.id &&
        error == null) {
      unawaited(play());
    }
  }

  Future<void> retry() async {
    final entry = resource;
    if (entry == null || loading) return;
    final start = _pendingStart;
    final task = load(
      entry,
      _tracks,
      index: start == null ? current : start.index,
      initialPosition: start == null ? position : start.position,
      resume: start?.resume ?? false,
    );
    final generation = _generation;
    final pauseRevision = _pauseRevision;
    await task;
    if (generation == _generation &&
        pauseRevision == _pauseRevision &&
        error == null) {
      unawaited(play());
    }
  }

  Future<void> load(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
    bool resume = false,
    Duration? initialPosition,
  }) {
    final generation = ++_generation;
    final task = _loads.then(
      (_) => _load(entry, sources, index, generation, resume, initialPosition),
    );
    _loads = task.catchError((_) {});
    return task;
  }

  Future<void> _load(
    MediaResource entry,
    List<AudioBookTrack> sources,
    int? requested,
    int generation,
    bool restore,
    Duration? initialPosition,
  ) async {
    if (generation != _generation) return;
    _remember();
    final previousId = resource?.id;
    final previousIndex = current;
    final previousPosition = position;
    final previousChapter =
        current >= 0 && current < (resource?.episodes.length ?? 0)
        ? resource!.episodes[current].id
        : null;
    final wasReady = _ready;
    _pendingStart = (index: requested, position: initialPosition, resume: restore);
    _ready = false;
    seeking = false;
    _seekFailed = false;
    _pendingSeek = null;
    _acceptEvents = false;
    _sleep?.cancel();
    sleepAt = null;
    loading = true;
    loadingMessage = '正在准备播放器…';
    _releaseRuntime?.call();
    _releaseRuntime = entry.originSection != null && entry.sourceId != null
        ? SourceRuntimePins.retain(entry.originSection!, entry.sourceId!)
        : null;
    resource = entry;
    current = requested ?? 0;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    error = null;
    notifyListeners();
    _tracks = sources;
    try {
      await _player?.stop();
      if (generation != _generation) return;
      if (sources.isEmpty) throw const AudioBookFailure('资源没有可播放的章节');
      await PlaybackFocus.acquire(
        'audioBook',
        stillWanted: () => generation == _generation,
      );
      if (generation != _generation) return;
      await settings.load();
      if (generation != _generation) return;
      final saved = settings.positions[entry.id];
      final index = (requested ?? settings.indexFor(entry)).clamp(
        0,
        sources.length - 1,
      );
      final savedChapter = settings.chapterIds[entry.id];
      final savedMatches = savedChapter == null
          ? (saved?['index'] == index)
          : savedChapter == sources[index].episode.id;
      final resume =
          initialPosition ??
          (restore &&
                  wasReady &&
                  previousId == entry.id &&
                  (previousChapter == sources[index].episode.id ||
                      previousChapter == null && previousIndex == index)
              ? previousPosition
              : ((requested == null || restore) && savedMatches)
              ? Duration(milliseconds: saved?['position'] ?? 0)
              : Duration.zero);
      resource = entry;
      position = resume;
      duration = Duration.zero;
      current = index;
      _pendingStart = null;
      final policy = MediaPreload.instance;
      final configuration = '${policy.bufferSeconds}|${policy.capacityMb}';
      if (_player != null && _preloadConfiguration != configuration) {
        for (final subscription in _subscriptions) {
          await subscription.cancel();
        }
        _subscriptions.clear();
        await _player!.release();
        final previous = _player;
        if (previous is JustAudioBookPlayer) await previous.disposeNative();
        _player = null;
      }
      if (_player == null) {
        await _initialize();
        if (generation != _generation) return;
        _player = _factory();
        _preloadConfiguration = configuration;
        _subscriptions.addAll([
          _player!.position.listen((_) => _syncPlayhead()),
          _player!.duration.listen((_) => _syncPlayhead()),
          _player!.index.listen((_) => _syncPlayhead()),
          _player!.playing.listen((value) {
            if (!_acceptEvents) return;
            if (playing == value) return;
            playing = value;
            notifyListeners();
            if (!loading && !value) _remember();
          }),
          _player!.errors.listen((failure) {
            if (!_acceptEvents) return;
            final chapter = failure.retryChapter;
            error = failure.message;
            if (chapter != null && chapter >= 0 && chapter < _tracks.length) {
              error = '${_tracks[chapter].episode.title}：${failure.message}';
              _acceptEvents = false;
              playing = false;
              current = chapter;
              position = duration = Duration.zero;
              _remember();
              _ready = false;
            }
            notifyListeners();
          }),
        ]);
      }
      if (generation != _generation) return;
      _acceptEvents = true;
      loadingMessage = '正在加载音频…';
      notifyListeners();
      await _player!.load(
        [
          for (final track in sources)
            if (track.resolve == null)
              track
            else
              AudioBookTrack(
                id: track.id,
                episode: track.episode,
                album: track.album,
                cover: track.cover,
                resolve: () async {
                  if (generation == _generation && loading) {
                    loadingMessage = '正在解析音频地址…';
                    notifyListeners();
                  }
                  final audio = await track.resolve!();
                  if (generation == _generation && loading) {
                    loadingMessage = '正在缓冲音频…';
                    notifyListeners();
                  }
                  return audio;
                },
              ),
        ],
        index: index,
        position: resume,
      );
      if (generation != _generation) {
        // A focus change may release the queue while the native load is still
        // pending. Its late completion must not reinstall the old media.
        await _player?.release();
        return;
      }
      _syncPlayhead();
      await _player!.speed(settings.speed);
      if (generation != _generation) return;
      _ready = true;
      setSleep(settings.sleepMinutes);
    } catch (failure, stack) {
      LumeLog.error('[audioBook] 加载失败: $failure', stack);
      if (generation == _generation) {
        _acceptEvents = false;
        error = failure is AudioBookFailure
            ? failure.message
            : '音频加载失败，请检查地址、权限和网络';
      }
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void _syncPlayhead() {
    if (!_acceptEvents || seeking || _seekFailed) return;
    // Index, duration and timer ticks arrive independently. Read all three
    // from the current playback event even when an older tick arrives late.
    final head = _player!.playhead;
    final index = head.index;
    if (index == null || index < 0 || index >= _tracks.length) return;
    final changedChapter = current != index;
    if (changedChapter && loading) return;
    current = index;
    position = head.position;
    duration = head.duration ?? Duration.zero;
    if (changedChapter) {
      notifyListeners();
    } else {
      _notifyProgress();
    }
    if (changedChapter || DateTime.now().difference(_savedAt).inSeconds >= 5) {
      _remember();
    }
  }

  void _remember() {
    final id = resource?.id;
    if (id == null || loading || seeking || !_ready) return;
    if (current >= 0 && current < (resource?.episodes.length ?? 0)) {
      settings.chapterIds[id] = resource!.episodes[current].id;
    }
    settings.positions[id] = {
      'index': current,
      'position': position.inMilliseconds,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _savedAt = DateTime.now();
    unawaited(settings.save().catchError((_) {}));
  }

  Future<void> play() async {
    if (loading) return;
    if (error != null || !_ready && resource != null) {
      await retry();
      return;
    }
    if (_player == null || loading || error != null) return;
    final generation = _generation;
    try {
      await _player!.play();
    } catch (_) {
      if (generation != _generation) return;
      error = '音频播放失败';
      notifyListeners();
    }
  }

  Future<void> pause() async {
    _pauseRevision++;
    await _player?.pause();
    _remember();
  }

  Future<void> stop() async {
    _pauseRevision++;
    _remember();
    _sleep?.cancel();
    sleepAt = null;
    await _player?.stop();
    notifyListeners();
  }

  Future<void> seek(Duration value, {int? index}) async {
    final entry = resource;
    if (entry == null || loading) return;
    if (index != null && (index < 0 || index >= _tracks.length)) return;
    if (!_ready) {
      // A bookmark seek on a released session can load directly at the
      // requested time, without briefly selecting a different chapter.
      await load(
        entry,
        _tracks,
        index: index ?? current,
        initialPosition: value,
      );
      return;
    }
    final generation = _generation;
    final revision = ++_seekRevision;
    if (!seeking) _confirmedSeekPosition = position;
    seeking = true;
    position = value;
    final previous = _pendingSeek;
    Future<void> apply() async {
      if (previous != null) await previous;
      if (generation != _generation || revision != _seekRevision) return;
      try {
        // A failed native load may already have switched its internal index.
        // Re-anchor a time-only retry to the chapter the listener actually heard.
        final target = index ?? (_seekFailed ? current : null);
        await _player!.seek(value, index: target);
        if (generation == _generation) {
          if (index != null) current = index;
          _confirmedSeekPosition = value;
          _seekFailed = false;
          if (error == _seekError) error = null;
        }
      } catch (_) {
        if (generation == _generation) {
          _seekFailed = true;
          if (revision == _seekRevision) error = _seekError;
        }
      }
    }

    final pending = _pendingSeek = apply();
    notifyListeners();
    await pending;
    if (generation == _generation && revision == _seekRevision) {
      _pendingSeek = null;
      position = _confirmedSeekPosition;
      seeking = false;
      final head = _player!.playhead;
      if (!_seekFailed && head.index == current) {
        duration = head.duration ?? Duration.zero;
      }
      _remember();
      notifyListeners();
    }
  }

  Future<void> playChapter(int index) async {
    final entry = resource;
    if (entry == null || loading || index < 0 || index >= _tracks.length) {
      return;
    }
    if (!_ready || error != null) {
      await open(entry, _tracks, index: index, restart: true);
      return;
    }
    final generation = _generation;
    final pauseRevision = _pauseRevision;
    final seekRevision = _seekRevision + 1;
    await seek(Duration.zero, index: index);
    if (generation == _generation &&
        pauseRevision == _pauseRevision &&
        seekRevision == _seekRevision &&
        error == null) {
      unawaited(play());
    }
  }

  Future<void> next() => seek(Duration.zero, index: current + 1);

  Future<void> previous() => seek(Duration.zero, index: current - 1);

  Future<void> setSpeed(double speed) async {
    settings.speed = speed.clamp(.5, 3);
    await _player?.speed(settings.speed);
    await settings.save();
    notifyListeners();
  }

  void setSleep(int minutes) {
    _sleep?.cancel();
    sleepAt = minutes > 0
        ? DateTime.now().add(Duration(minutes: minutes))
        : null;
    if (minutes > 0) {
      _sleep = _schedule(Duration(minutes: minutes), () {
        unawaited(stop());
      });
    }
    notifyListeners();
  }

  Future<void> release() async {
    _remember();
    final generation = ++_generation;
    loading = false;
    seeking = false;
    _sleep?.cancel();
    sleepAt = null;
    _ready = false;
    _acceptEvents = false;
    final releaseRuntime = _releaseRuntime;
    _releaseRuntime = null;
    try {
      await _player?.release();
    } finally {
      releaseRuntime?.call();
      if (generation == _generation) {
        playing = false;
        notifyListeners();
      }
    }
  }

  Future<void> shutdown() async {
    _remember();
    _generation++;
    _ready = false;
    _acceptEvents = false;
    loading = false;
    _sleep?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player?.release();
    _releaseRuntime?.call();
    _releaseRuntime = null;
    await settings.save();
  }
}
