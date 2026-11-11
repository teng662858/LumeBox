import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'buffering.dart';
import 'highest_hls.dart';
import 'player_capabilities.dart';
import 'player_settings.dart';
import 'player_stats.dart';

/// Apple-native display surface: HDR pixels never pass through a Flutter texture.
class AetherPlayer extends AbstractPlayer implements PresentationEngine {
  static const channel = MethodChannel('lumebox/aether');
  final _snapshot = ValueNotifier(const PlayerSnapshot());
  final _stats = ValueNotifier(const PlayerStats(engineLabel: 'AetherEngine'));
  final _presentation = ValueNotifier<List<String>>(const ['正在读取播放信息']);
  final _hls = HighestHls();
  PlayerSettings _settings = const PlayerSettings(kernel: PlayerKernel.aether);
  BufferingConfig _buffering = BufferingConfig.defaults;
  late final Future<int> _created = _create();
  int? _id;
  int? get nativePlayerId => _id;
  bool _disposed = false, _polling = false;
  int _generation = 0;
  Timer? _timer;
  Timer? _bufferingTimer;
  Completer<void>? _bufferingPending;
  StreamSubscription<Object?>? _events;
  Future<void> _pending = Future<void>.value();

  Future<int> _create() async {
    await LumeLog.playbackCheckpoint('[aether] 开始创建原生播放器');
    final id = await channel.invokeMethod<int>('create');
    if (id == null) throw StateError('AetherEngine 初始化失败');
    _id = id;
    if (!_disposed) {
      _events = EventChannel('lumebox/aether/$id/events')
          .receiveBroadcastStream()
          .listen(
            (event) {
              if (_disposed || event is! Map) return;
              final data = Map<Object?, Object?>.from(event);
              if (data['generation'] is num &&
                  data['generation'] != _generation) {
                return;
              }
              _timer?.cancel();
              _applySnapshot(data);
            },
            onError: (Object _) {
              /* Older native builds retain polling fallback. */
            },
          );
    }
    if (!_disposed) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        unawaited(_refresh());
      });
    }
    return id;
  }

  @override
  Future<void> initialize() async {
    await _created;
  }

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;
  @override
  ValueListenable<PlayerStats> get stats => _stats;
  @override
  ValueListenable<List<String>> get presentationStatus => _presentation;
  @override
  PlayerCapabilities get capabilities =>
      PlayerCapabilities.of(PlayerKernel.aether);

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) return null;
    final id = await _created;
    if (_disposed) return null;
    return channel.invokeMethod<T>(method, {'id': id, ...args});
  }

  // Preserve transport/settings order while polling remains independent of a slow load.
  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _pending.then((_) async {
      if (!_disposed) await operation();
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Map<String, Object?> get _options => {
    ..._settings.presentation.toJson(),
    'wantsHdr': _settings.presentation.wantsHdr,
    'hardwareDecoding': _settings.hardwareDecoding,
    'speed': _settings.speed,
    'subtitleFontSize': 24 * _settings.subtitleSize.scale,
    'subtitleArgb': _settings.subtitleColor.argb,
    'subtitleOutlineWidth': _settings.subtitleOutline.width,
    'subtitleBackground': _settings.subtitleBackground,
    'subtitleFont': _settings.subtitleFont,
    'subtitleShadow': _settings.subtitleShadow,
    'subtitleOffsetY': _settings.subtitleOffsetY,
    'subtitleDelaySeconds': _settings.subtitleDelay.inMilliseconds / 1000,
    'audioDelaySeconds': _settings.audioDelay.inMilliseconds / 1000,
    'subtitlesEnabled': _settings.subtitlesEnabled,
    'forwardBufferSeconds': _buffering.readAhead.inMilliseconds / 1000,
    'maxBufferBytes': _buffering.maxBufferBytes,
  };

  @override
  Future<void> load(PlayerMedia media) => _enqueue(() async {
    final generation = ++_generation;
    _snapshot.value = const PlayerSnapshot(buffering: true);
    try {
      final uri = await _hls.resolve(
        media.uri,
        media.headers,
        presentation: _settings.presentation,
      );
      if (_disposed || generation != _generation) {
        await _hls.close();
        return;
      }
      await LumeLog.playbackCheckpoint(
        '[aether] 原生装载开始 · ${uri.path.endsWith('.m3u8') ? 'HLS' : '媒体文件'}',
      );
      await _invoke<Object?>('load', {
        'generation': generation,
        'url': uri.toString(),
        'headers': media.headers ?? const <String, String>{},
        'options': _options,
      });
      await LumeLog.playbackCheckpoint('[aether] 原生装载返回');
      await _refresh();
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _snapshot.value = PlayerSnapshot(error: '$error');
      }
      rethrow;
    }
  });

  @override
  Future<void> play() => _enqueue(() async {
    await _invoke<Object?>('play');
  });
  @override
  Future<void> pause() => _enqueue(() async {
    await _invoke<Object?>('pause');
  });
  @override
  Future<void> seek(Duration position) => _enqueue(() async {
    await _invoke<Object?>('seek', {'seconds': position.inMilliseconds / 1000});
    await _refresh();
  });
  @override
  Future<void> stop() => _enqueue(() async {
    await _invoke<Object?>('stop');
  });
  @override
  Future<void> setVolume(double volume) => _enqueue(() async {
    await _invoke<Object?>('volume', {'value': volume.clamp(0.0, 1.0)});
  });
  @override
  Future<void> setBuffering(BufferingConfig config) {
    _buffering = config;
    if (_generation == 0) {
      return _enqueue(() async {
        await _invoke<Object?>('settings', {'options': _options});
      });
    }
    _bufferingTimer?.cancel();
    final pending = _bufferingPending ??= Completer<void>();
    _bufferingTimer = Timer(const Duration(milliseconds: 300), () {
      _bufferingPending = null;
      _enqueue(() async {
        await _invoke<Object?>('settings', {'options': _options});
      }).then(
        (_) {
          if (!pending.isCompleted) pending.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!pending.isCompleted) pending.completeError(error, stack);
        },
      );
    });
    return pending.future;
  }

  @override
  Future<void> setAudioDelay(Duration delay) =>
      applySettings(_settings.copyWith(audioDelay: delay));

  @override
  Future<void> applySettings(PlayerSettings settings) => _enqueue(() async {
    _settings = settings;
    await _invoke<Object?>('settings', {'options': _options});
    await _refresh();
  });
  @override
  Future<void> applyPresentation(PlaybackPresentation settings) =>
      applySettings(_settings.copyWith(presentation: settings));

  Future<List<PlayerTrack>> _tracks(String method) async {
    final values = await _invoke<List<Object?>>(method);
    return [
      for (final value in values ?? const [])
        if (value is Map)
          PlayerTrack(
            id: '${value['id']}',
            label: '${value['label']}',
            language: value['language'] as String?,
            selected: value['selected'] == true,
          ),
    ];
  }

  @override
  Future<List<PlayerTrack>> audioTracks() => _tracks('audioTracks');
  @override
  Future<List<PlayerTrack>> subtitleTracks() => _tracks('subtitleTracks');
  @override
  Future<void> selectAudioTrack(String id) => _enqueue(() async {
    await _invoke<Object?>('selectAudio', {'track': int.parse(id)});
  });
  @override
  Future<void> selectSubtitleTrack(String? id) => _enqueue(() async {
    await _invoke<Object?>('selectSubtitle', {
      'track': id == null ? null : int.parse(id),
    });
  });
  @override
  Future<bool> loadSubtitleFile(String path) async =>
      await _invoke<bool>('externalSubtitle', {'path': path}) ?? false;

  Future<void> _refresh() async {
    if (_disposed || _polling) return;
    _polling = true;
    final generation = _generation;
    try {
      final data = await _invoke<Map<Object?, Object?>>('snapshot');
      if (_disposed || data == null || generation != _generation) return;
      _applySnapshot(data);
    } catch (error) {
      if (!_disposed) _snapshot.value = PlayerSnapshot(error: '$error');
    } finally {
      _polling = false;
    }
  }

  void _applySnapshot(Map<Object?, Object?> data) {
    Duration time(String key) {
      final value = data[key];
      final seconds = value is num ? value.toDouble() : 0.0;
      return Duration(
        milliseconds: seconds.isFinite ? (seconds * 1000).round() : 0,
      );
    }

    _snapshot.value = PlayerSnapshot(
      position: time('position'),
      duration: time('duration'),
      playing: data['playing'] == true,
      buffering: data['buffering'] == true,
      error: data['error'] as String?,
    );
    _stats.value = PlayerStats(
      engineLabel: 'AetherEngine',
      width: (data['width'] as num?)?.toInt(),
      height: (data['height'] as num?)?.toInt(),
      videoCodec: data['videoCodec'] as String?,
      audioCodec: data['audioCodec'] as String?,
      fps: (data['fps'] as num?)?.toDouble(),
      videoBitrateKbps: (data['bitrate'] as num?)?.toDouble(),
      buffering: data['buffering'] == true,
      firstFrameReady: data['firstFrameReady'] as bool?,
      buffered: time('bufferedSeconds'),
    );
    _presentation.value =
        (data['presentation'] as List?)?.cast<String>() ?? const [];
  }

  @override
  Widget buildView() => FutureBuilder<int>(
    future: _created,
    builder: (context, state) => state.hasData && !_disposed
        ? UiKitView(
            key: ValueKey(state.data),
            viewType: 'lumebox/aether_view',
            creationParams: {'id': state.data},
            creationParamsCodec: const StandardMessageCodec(),
          )
        : const SizedBox.shrink(),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _bufferingTimer?.cancel();
    _bufferingPending?.complete();
    _bufferingPending = null;
    await _events?.cancel();
    try {
      final id = _id;
      if (id != null) {
        // Bypass the transport queue: native stop must cancel an in-flight load.
        await channel.invokeMethod<void>('dispose', {'id': id});
      } else {
        // A timed-out native creation must not hold the fallback hostage. Dispose
        // its eventual result as soon as it arrives, even after this Dart object exits.
        unawaited(
          _created
              .then((id) async {
                await channel.invokeMethod<void>('dispose', {'id': id});
              })
              .catchError((Object _) {}),
        );
      }
    } finally {
      await _hls.close();
      _snapshot.dispose();
      _stats.dispose();
      _presentation.dispose();
    }
  }
}
