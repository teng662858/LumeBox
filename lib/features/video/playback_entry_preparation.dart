import 'dart:async';

import '../../core/player/player_factory.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import 'video_player_settings.dart';

import 'package:flutter/services.dart';

import '../../core/player/playback_orientation.dart';

import 'dart:io';

import '../../core/net/ios_verified_webview.dart';
import '../../core/media/media_library.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/highest_hls.dart';
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import 'playback_preference_wiring.dart';
import 'video_play_target.dart';

String playbackEntryDirectionKey(VideoPlayTarget target) =>
    'video.entry.direction.${target.identity}';

String? playbackDirectionFromDimensions(Object? width, Object? height) {
  final w = num.tryParse('$width');
  final h = num.tryParse('$height');
  if (w == null ||
      h == null ||
      !w.isFinite ||
      !h.isFinite ||
      w <= 0 ||
      h <= 0) {
    return null;
  }
  return w < h ? 'portrait' : 'landscape';
}

/// Entry preflight uses the same UA and verified resource cookies as playback.
Future<void> preparePlaybackEntry(
  PlayerPrelaunch prelaunch,
  PlayerMedia media,
  PlayerSettings? settings, {
  Duration sizeTimeout = const Duration(milliseconds: 250),
  void Function(String)? onEarlyDirection,
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
  if (onEarlyDirection != null) {
    unawaited(() async {
      if (media.uri.scheme == 'file' && Platform.isIOS) {
        final tracks = await const MediaTrackProbe().inspect(
          media.uri,
          includeDimensions: true,
        );
        final direction = playbackDirectionFromDimensions(
          tracks.width,
          tracks.height,
        );
        if (direction != null) onEarlyDirection(direction);
      } else {
        final portrait = await HighestHls.entryIsPortrait(media.uri, headers);
        if (portrait != null) {
          onEarlyDirection(portrait ? 'portrait' : 'landscape');
        }
      }
    }());
  }
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

/// Set the route's entry direction before pushing it. Actual player dimensions
/// override provisional directions once they arrive.
Future<void> applyPlaybackEntryOrientation(
  PlayerPrelaunch? prelaunch, {
  String? entryDirection,
  String? fallbackDirection,
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
    final direction =
        playbackDirectionFromDimensions(stats?.width, stats?.height) ??
        entryDirection ??
        fallbackDirection;
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
  String? sourceDirection,
  String? fallbackDirection,
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
  final remembered = target == null
      ? null
      : store.setting(playbackEntryDirectionKey(target));
  var direction =
      sourceDirection ??
      (remembered == 'portrait' || remembered == 'landscape'
          ? remembered
          : null);
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
        direction == null) {
      // Entry direction is optional metadata. Never load a native media item
      // here: take() must transfer the kernel without waiting on the CDN or on
      // buffering that can only finish after the visible page calls play().
      direction =
          await (() async {
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
                if (media.uri.scheme == 'file' && Platform.isIOS) {
                  final tracks = await const MediaTrackProbe().inspect(
                    media.uri,
                    includeDimensions: true,
                  );
                  return playbackDirectionFromDimensions(
                    tracks.width,
                    tracks.height,
                  );
                }
                final portrait = await HighestHls.entryIsPortrait(
                  media.uri,
                  headers,
                );
                return portrait == null
                    ? null
                    : portrait
                    ? 'portrait'
                    : 'landscape';
              })()
              .timeout(const Duration(milliseconds: 350), onTimeout: () => null)
              .catchError((Object _) => null);
    }
    if (stillActive != null && !stillActive()) {
      await entry.discard();
      return null;
    }
    await applyPlaybackEntryOrientation(
      entry,
      entryDirection: direction,
      fallbackDirection: fallbackDirection,
    );
    return entry;
  } catch (_) {
    await entry.discard();
    rethrow;
  }
}
