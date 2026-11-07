import 'package:flutter/material.dart';

import '../../core/session/app_preferences.dart';
import '../../core/player/player_stats.dart';

class MediaBadgeSettings extends ChangeNotifier {
  static final instance = MediaBadgeSettings();
  bool enabled(String key) => AppPreferences.instance.mediaBadges[key] != false;
  String get style =>
      AppPreferences.instance.mediaBadges['style'] as String? ??
      (AppPreferences.instance.mediaBadges['graphic'] == true
          ? 'graphic'
          : 'compact');
  bool get graphic => style == 'graphic';
  void setStyle(String value) {
    AppPreferences.instance.mediaBadges['style'] = value;
    AppPreferences.instance.save();
    notifyListeners();
  }

  void set(String key, bool value) {
    AppPreferences.instance.mediaBadges[key] = value;
    AppPreferences.instance.save();
    notifyListeners();
  }
}

/// Explicit media metadata only; titles are never scanned for specifications.
enum MediaBadgeKind {
  resolution('分辨率', Icons.hd_outlined),
  dynamicRange('HDR / 动态范围', Icons.brightness_6_outlined),
  videoCodec('视频编码', Icons.memory_outlined),
  bitDepth('位深', Icons.gradient),
  audioCodec('音频格式', Icons.graphic_eq),
  channels('声道', Icons.surround_sound_outlined),
  fps('帧率', Icons.speed),
  language('语言', Icons.translate);

  const MediaBadgeKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class MediaBadgeData {
  static MediaBadgeKind kind(String label) {
    final value = label.toUpperCase().replaceAll(' ', '');
    if (RegExp(r'^(\d+[PK]|\d+×\d+|UHD|FHD|HD)$').hasMatch(value)) {
      return MediaBadgeKind.resolution;
    }
    if (value.contains('HDR') ||
        value.contains('VISION') ||
        value == 'HLG' ||
        value == 'SDR') {
      return MediaBadgeKind.dynamicRange;
    }
    if (value.contains('BIT')) return MediaBadgeKind.bitDepth;
    if (value.contains('FPS')) return MediaBadgeKind.fps;
    if (RegExp(r'^\d+\.\d+$').hasMatch(value) ||
        value == 'STEREO' ||
        value == 'MONO') {
      return MediaBadgeKind.channels;
    }
    if (RegExp(r'HEVC|AVC|H\.?26[45]|AV1|VP[89]|MPEG').hasMatch(value)) {
      return MediaBadgeKind.videoCodec;
    }
    if (RegExp(r'ATMOS|TRUEHD|DTS|AAC|AC3|EAC3|FLAC|OPUS|MP3|PCM|DOLBY')
        .hasMatch(value)) {
      return MediaBadgeKind.audioCodec;
    }
    return MediaBadgeKind.language;
  }

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
      final filtered = <String>[];
      final seen = <MediaBadgeKind>{};
      for (final value in values) {
        final category = MediaBadgeData.kind(value);
        if (!settings.enabled('kind.${category.name}') || !seen.add(category)) {
          continue;
        }
        if (location == 'player' &&
            ![
              MediaBadgeKind.resolution,
              MediaBadgeKind.dynamicRange,
              MediaBadgeKind.audioCodec,
            ].contains(category)) {
          continue;
        }
        filtered.add(value);
      }
      final visible = filtered.take(location == 'card' ? 2 : limit).toList();
      if (settings.style == 'text') {
        return Text(
          visible.join(' · '),
          style: TextStyle(
            fontSize: 11,
            color: overlay ? Colors.white : colors.onSurfaceVariant,
          ),
        );
      }
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final value in visible)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: overlay
                    ? Colors.black.withValues(alpha: .58)
                    : MediaBadgeData.kind(value) == MediaBadgeKind.dynamicRange
                    ? colors.primaryContainer.withValues(alpha: .65)
                    : colors.surfaceContainerHighest.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (settings.graphic) ...[
                    Icon(
                      MediaBadgeData.kind(value).icon,
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
