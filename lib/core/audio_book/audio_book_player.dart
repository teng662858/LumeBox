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
  Future<void> _saving = Future.value();
  Future<void>? _loading;
  Future<File> get _file async => File(
    '${(await getApplicationSupportDirectory()).path}/audio_book_settings.json',
  );
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final file = await _file;
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
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

/// Every future implementation must satisfy this audio-only contract.
abstract interface class AudioBookPlayer {
  Stream<Duration> get position;
  Stream<Duration?> get duration;
  Stream<bool> get playing;
  Stream<int?> get index;
  Stream<String> get errors;
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
  bool _singleMode = false, _changing = false;
  int _offset = 0;
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
  Stream<int?> get index => _player.currentIndexStream.map(
    (index) => index == null ? null : index + (_singleMode ? _offset : 0),
  );
  @override
  Stream<String> get errors => _player.errorStream.map((error) {
    LumeLog.warn('[audioBook] 播放器错误: $error');
    return _proxy.lastError ?? '音频播放失败，请检查源和网络';
  });
  @override
  Future<void> load(
    List<AudioBookTrack> sources, {
    int index = 0,
    Duration position = Duration.zero,
  }) async {
    await _configureSession();
    final urls = await _proxy.prepare(sources);
    _singleMode = !MediaPreload.instance.audio;
    _removePreloadClearer ??= MediaPreload.instance.onClear(() async {
      if (_playlist.isEmpty || _changing || _singleMode) return;
      final index = (_player.currentIndex ?? 0) + (_singleMode ? _offset : 0);
      final wasPlaying = _player.playing;
      final position = _player.position;
      _singleMode = true;
      await _loadSingle(index, position: position, play: wasPlaying);
    });
    _completion ??= _player.playerStateStream.listen((state) {
      if (_singleMode &&
          !_changing &&
          state.processingState == ja.ProcessingState.completed &&
          _offset + 1 < _playlist.length) {
        unawaited(
          _loadSingle(_offset + 1, play: true).catchError((Object error) {
            LumeLog.warn('[audioBook] 自动切集失败：$error');
          }),
        );
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
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  Future<void> _loadSingle(
    int index, {
    Duration position = Duration.zero,
    bool play = false,
  }) async {
    if (index < 0 || index >= _playlist.length || _changing) return;
    _changing = true;
    try {
      _offset = index;
      await _player.setAudioSource(_playlist[index], initialPosition: position);
      if (play) unawaited(_player.play());
    } finally {
      _changing = false;
    }
  }

  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration value, {int? index}) =>
      _singleMode && index != null
      ? _loadSingle(index, position: value, play: _player.playing)
      : _player.seek(value, index: index);
  @override
  Future<void> next() => _singleMode
      ? _loadSingle(_offset + 1, play: _player.playing)
      : _player.seekToNext();
  @override
  Future<void> previous() => _singleMode
      ? _loadSingle(_offset - 1, play: _player.playing)
      : _player.seekToPrevious();
  @override
  Future<void> speed(double value) => _player.setSpeed(value);
  @override
  Future<void> release() async {
    _removePreloadClearer?.call();
    _removePreloadClearer = null;
    await _completion?.cancel();
    _completion = null;
    _playlist = [];
    await _player.stop();
    await _player.clearAudioSources();
    _proxy.reset();
  }

  Future<void> disposeNative() async {
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
  AudioBookPlayer? _player;
  String? _preloadConfiguration;
  MediaResource? resource;
  Duration position = Duration.zero, duration = Duration.zero;
  int current = 0;
  bool playing = false, loading = false, seeking = false;
  String? error;
  DateTime? sleepAt;
  Timer? _sleep;
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _generation = 0;
  Future<void> _loads = Future.value();
  List<AudioBookTrack> _tracks = [];
  bool _ready = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  AudioBookPlayer? get player => _player;
  Future<void> load(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
  }) {
    final generation = ++_generation;
    final task = _loads.then((_) => _load(entry, sources, index, generation));
    _loads = task.catchError((_) {});
    return task;
  }

  Future<void> _load(
    MediaResource entry,
    List<AudioBookTrack> sources,
    int? requested,
    int generation,
  ) async {
    if (generation != _generation) return;
    _remember();
    loading = true;
    error = null;
    notifyListeners();
    _tracks = sources;
    try {
      await PlaybackFocus.acquire('audioBook');
      await settings.load();
      if (generation != _generation) return;
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
        _player = _factory();
        _preloadConfiguration = configuration;
        _subscriptions.addAll([
          _player!.position.listen((value) {
            if (!_ready && !loading) return;
            if (!seeking) {
              position = value;
              notifyListeners();
            }
            if (!loading &&
                DateTime.now().difference(_savedAt).inSeconds >= 5) {
              _remember();
            }
          }),
          _player!.duration.listen((value) {
            if (!_ready && !loading) return;
            duration = value ?? Duration.zero;
            notifyListeners();
          }),
          _player!.playing.listen((value) {
            playing = value;
            notifyListeners();
            if (!loading && !value) _remember();
          }),
          _player!.index.listen((value) {
            if (!_ready && !loading) return;
            current = value ?? 0;
            notifyListeners();
          }),
          _player!.errors.listen((message) {
            error = message;
            notifyListeners();
          }),
        ]);
      }
      _remember();
      await _player!.stop();
      if (generation != _generation) return;
      final saved = settings.positions[entry.id];
      final index = (requested ?? saved?['index'] ?? 0).clamp(
        0,
        sources.length - 1,
      );
      final resume = requested == null
          ? Duration(milliseconds: saved?['position'] ?? 0)
          : Duration.zero;
      resource = entry;
      position = resume;
      duration = Duration.zero;
      current = index;
      await _player!.load(sources, index: index, position: resume);
      if (generation != _generation) return;
      await _player!.speed(settings.speed);
      _ready = true;
      setSleep(settings.sleepMinutes);
    } catch (failure, stack) {
      LumeLog.error('[audioBook] 加载失败: $failure', stack);
      if (generation == _generation) {
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

  void _remember() {
    final id = resource?.id;
    if (id == null || loading || !_ready) return;
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
    if (!_ready && resource != null) await load(resource!, _tracks);
    if (_player == null || loading || error != null) return;
    try {
      await _player!.play();
    } catch (_) {
      error = '音频播放失败';
      notifyListeners();
    }
  }

  Future<void> pause() async {
    await _player?.pause();
    _remember();
  }

  Future<void> stop() async {
    _remember();
    _sleep?.cancel();
    sleepAt = null;
    await _player?.stop();
    notifyListeners();
  }

  Future<void> seek(Duration value, {int? index}) async {
    if (!_ready && resource != null) {
      await load(resource!, _tracks, index: index);
    }
    seeking = true;
    position = value;
    notifyListeners();
    try {
      await _player?.seek(value, index: index);
    } catch (_) {
      error = '跳转失败，请重试';
    } finally {
      seeking = false;
      _remember();
      notifyListeners();
    }
  }

  Future<void> next() async {
    if (current + 1 < (resource?.episodes.length ?? 0)) await _player?.next();
  }

  Future<void> previous() async {
    if (current > 0) await _player?.previous();
  }

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
    _sleep?.cancel();
    sleepAt = null;
    _ready = false;
    await _player?.release();
    playing = false;
    notifyListeners();
  }

  Future<void> shutdown() async {
    _remember();
    _generation++;
    _sleep?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player?.release();
    await settings.save();
  }
}
