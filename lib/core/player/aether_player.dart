import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
  bool _disposed = false, _polling = false;
  int _generation = 0;
  Timer? _timer;
  Future<void> _pending = Future<void>.value();

  Future<int> _create() async {
    final id = await channel.invokeMethod<int>('create');
    if (id == null) throw StateError('AetherEngine 初始化失败');
    _id = id;
    if (!_disposed) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        unawaited(_refresh());
      });
    }
    return id;
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
    'speed': _settings.speed,
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
      await _invoke<Object?>('load', {
        'url': uri.toString(),
        'headers': media.headers ?? const <String, String>{},
        'options': _options,
      });
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
  Future<void> setBuffering(BufferingConfig config) async {
    _buffering = config;
  }

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
      );
      _presentation.value =
          (data['presentation'] as List?)?.cast<String>() ?? const [];
    } catch (error) {
      if (!_disposed) _snapshot.value = PlayerSnapshot(error: '$error');
    } finally {
      _polling = false;
    }
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
    try {
      final id = _id ?? await _created;
      // Bypass the transport queue: native stop must cancel an in-flight load.
      await channel.invokeMethod<void>('dispose', {'id': id});
    } finally {
      await _hls.close();
      _snapshot.dispose();
      _stats.dispose();
      _presentation.dispose();
    }
  }
}
