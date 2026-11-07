import 'package:flutter/material.dart';

import '../../core/session/app_preferences.dart';
import '../../core/player/player_stats.dart';

class MediaBadgeSettings extends ChangeNotifier {
  static final instance = MediaBadgeSettings();
  bool enabled(String key) => AppPreferences.instance.mediaBadges[key] != false;
  bool get graphic => AppPreferences.instance.mediaBadges['graphic'] == true;
  void set(String key, bool value) {
    AppPreferences.instance.mediaBadges[key] = value;
    AppPreferences.instance.save();
    notifyListeners();
  }
}

/// Explicit media metadata only; titles are never scanned for specifications.
class MediaBadgeData {
  static List<String> fromMap(Map<String, dynamic> data) {
    final out = <String>[];
    for (final key in [
      'resolution',
      'dynamicRange',
      'videoCodec',
      'bitDepth',
      'audioCodec',
      'channels',
      'fps',
      'language',
    ]) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) out.add(value.trim());
      if (value is num && value > 0) {
        out.add(
          key == 'bitDepth'
              ? '${value}bit'
              : key == 'fps'
              ? '${value}FPS'
              : '$value',
        );
      }
    }
    return out.take(8).toList();
  }

  static List<String> fromStats(PlayerStats stats) => [
    if (stats.resolutionText != null)
      stats.height == 2160 ? '4K' : '${stats.height}P',
    if (stats.codecText != null) stats.codecText!,
    if (stats.audioCodec?.trim().isNotEmpty == true &&
        stats.videoCodec?.trim().isNotEmpty == true)
      stats.audioCodec!.toUpperCase(),
    if (stats.fpsText != null) stats.fpsText!,
  ];
}

class MediaBadges extends StatelessWidget {
  const MediaBadges({
    super.key,
    required this.values,
    this.location = 'detail',
    this.overlay = false,
    this.limit = 8,
    this.preview = false,
  });
  final List<String> values;
  final String location;
  final bool overlay, preview;
  final int limit;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MediaBadgeSettings.instance,
    builder: (context, _) {
      final settings = MediaBadgeSettings.instance;
      if ((!preview &&
              (!settings.enabled('enabled') || !settings.enabled(location))) ||
          values.isEmpty) {
        return const SizedBox.shrink();
      }
      final colors = Theme.of(context).colorScheme;
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final value in values.take(limit))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: overlay
                    ? Colors.black.withValues(alpha: .58)
                    : colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (settings.graphic) ...[
                    Icon(
                      Icons.movie_outlined,
                      size: 12,
                      color: overlay ? Colors.white : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: overlay ? Colors.white : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
