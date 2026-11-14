import 'dart:convert';

import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section_module_settings.dart';

/// Optional source overrides. Unrelated controls continue to follow global defaults.
class SourcePlaybackProfiles {
  const SourcePlaybackProfiles(this.library);
  final ReadingLibrary library;
  String _key(String id) => 'video.player.source.${Uri.encodeComponent(id)}';
  Map? _read(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    try {
      final raw = jsonDecode(library.setting(_key(id)) ?? 'null');
      return raw is Map && raw['version'] == 1 ? raw : null;
    } catch (_) {
      return null;
    }
  }

  bool contains(String? id) => _read(id) != null;
  PlayerSettings load(String? id, PlayerSettings defaults) {
    final data = _read(id);
    if (data == null) return defaults;
    final storedKernel =
        PlayerKernel.values.where((k) => k.id == data['kernel']).firstOrNull ??
        defaults.kernel;
    final kernel = storedKernel == PlayerKernel.mdk
        ? PlayerKernel.avplayer
        : storedKernel;
    final prefs = {...defaults.prefs};
    final rawPrefs = data['prefs'];
    if (rawPrefs is Map) {
      for (final key in PlayerKernel.values) {
        if (rawPrefs[key.id] is Map) {
          prefs[key] = KernelPrefs.fromJson(rawPrefs[key.id]);
        }
      }
    }
    if (storedKernel == PlayerKernel.mdk && prefs[PlayerKernel.mdk] != null) {
      prefs[PlayerKernel.avplayer] = prefs[PlayerKernel.mdk]!;
    }
    return defaults.copyWith(
      kernel: kernel,
      prefs: prefs,
      subtitlesEnabled: data['subtitlesEnabled'] is bool
          ? data['subtitlesEnabled'] as bool
          : defaults.subtitlesEnabled,
      hardwareDecoding: data['hardwareDecoding'] is bool
          ? data['hardwareDecoding'] as bool
          : defaults.hardwareDecoding,
      decodingPreset: data['decodingPreset'] is String
          ? DecodingPreset.parse(data['decodingPreset'] as String)
          : data['hardwareDecoding'] == false
          ? DecodingPreset.software
          : defaults.decodingPreset,
      presentation: data['presentation'] is Map
          ? PlaybackPresentation.fromJson(data['presentation'])
          : defaults.presentation,
    );
  }

  int bufferSeconds(String? id, int defaults) {
    return SectionModuleSettings.normalizeBufferSeconds(
      _read(id)?['bufferSeconds'],
      defaults,
    );
  }

  void save(String id, PlayerSettings settings, int bufferSeconds) {
    if (id.trim().isEmpty) return;
    library.setSetting(
      _key(id),
      jsonEncode({
        'version': 1,
        'kernel': settings.kernel.id,
        'prefs': {
          for (final kernel in PlayerKernel.values)
            kernel.id: (settings.prefs[kernel] ?? const KernelPrefs()).toJson(),
        },
        'subtitlesEnabled': settings.subtitlesEnabled,
        'hardwareDecoding': settings.hardwareDecoding,
        'decodingPreset': settings.decodingPreset.name,
        'presentation': settings.presentation.toJson(),
        'bufferSeconds': bufferSeconds.clamp(
          0,
          SectionModuleSettings.maxBufferSeconds,
        ),
      }),
    );
  }

  void clear(String id) => library.setSetting(_key(id), '');
}
