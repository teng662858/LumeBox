import 'dart:async';

import '../../core/player/player_factory.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import 'video_player_settings.dart';

import 'package:flutter/services.dart';

import '../../core/player/playback_orientation.dart';

import 'dart:io';

import '../../core/net/ios_verified_webview.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import 'playback_preference_wiring.dart';
import 'video_play_target.dart';

String playbackEntryDirectionKey(VideoPlayTarget target) =>
    'video.entry.direction.${target.identity}';

/// Entry preflight uses the same UA and verified resource cookies as playback.
Future<void> preparePlaybackEntry(
  PlayerPrelaunch prelaunch,
  PlayerMedia media,
  PlayerSettings? settings, {
  Duration sizeTimeout = const Duration(milliseconds: 250),
}) async {
  final request = PlaybackPreferenceWiring.applyUserAgent(
    media,
    PlayerExperienceStore.current,
  );
  final headers = Platform.isIOS
      ? await IosVerifiedWebView.resourceHeaders(
          media.uri.toString(),
          request.headers ?? const {},
        )
      : request.headers;
  await prelaunch.prepareMedia(
    media,
    settings: settings,
    sizeTimeout: sizeTimeout,
    requestMedia: PlayerMedia(
      uri: media.uri,
      title: media.title,
      headers: headers,
    ),
  );
}

/// Set the route's entry direction before pushing it. Unknown sizes keep the
/// current lock; dimensions can still resolve later without blocking playback.
Future<void> applyPlaybackEntryOrientation(
  PlayerPrelaunch? prelaunch, {
  String? previousDirection,
}) async {
  final mode = PlaybackOrientationController.instance.orientation;
  List<DeviceOrientation> orientations;
  if (mode == PlaybackOrientation.portrait) {
    orientations = const [DeviceOrientation.portraitUp];
  } else if (mode == PlaybackOrientation.landscape) {
    orientations = const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ];
  } else {
    final stats = prelaunch?.preparedStats;
    final hasSize = (stats?.width ?? 0) > 0 && (stats?.height ?? 0) > 0;
    final direction = hasSize
        ? (stats!.width! < stats.height! ? 'portrait' : 'landscape')
        : previousDirection;
    if (direction != 'portrait' && direction != 'landscape') return;
    orientations = direction == 'portrait'
        ? const [DeviceOrientation.portraitUp]
        : const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ];
  }
  await SystemChrome.setPreferredOrientations(orientations);
}

/// Common entry for source, captured, downloaded and media-library videos.
Future<PlayerPrelaunch?> preparePlaybackRoute(
  PlayerMedia media, {
  ReadingLibrary? library,
  PlayerPrelaunch? prelaunch,
  VideoPlayTarget? target,
  bool Function()? stillActive,
}) async {
  const catalog = PlatformPlayerKernelCatalog();
  final available = PlayerKernel.values.where(catalog.isAvailable).toList();
  if (prelaunch == null && available.isEmpty) return null;
  final store =
      library ??
      ReadingLibrary.find(Section.video) ??
      await ReadingLibrary.open(Section.video);
  final settings = VideoPlayerSettingsStore(store).load();
  final previousDirection = target == null
      ? null
      : store.setting(playbackEntryDirectionKey(target));
  final entry =
      prelaunch ??
      PlayerPrelaunch.start(
        catalog.isAvailable(settings.kernel)
            ? settings.kernel
            : available.first,
      );
  try {
    if (PlaybackOrientationController.instance.orientation ==
            PlaybackOrientation.auto &&
        previousDirection == null) {
      // Keep the preparation owned by the prelaunch. The route may paint while
      // it loads; take() joins that same task rather than creating another player.
      await preparePlaybackEntry(
        entry,
        media,
        settings.copyWith(kernel: entry.kernel),
      ).timeout(const Duration(milliseconds: 350), onTimeout: () {});
    }
    if (stillActive != null && !stillActive()) {
      await entry.discard();
      return null;
    }
    await applyPlaybackEntryOrientation(
      entry,
      previousDirection: previousDirection,
    );
    return entry;
  } catch (_) {
    await entry.discard();
    rethrow;
  }
}
