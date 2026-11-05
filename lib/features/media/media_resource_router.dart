import '../video/playback_entry_preparation.dart';
import '../../core/media/playback_focus.dart';

import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../../core/player/abstract_player.dart';
import '../video/video_player_page.dart';
import 'audio_player_page.dart';

Future<void> openMediaResource(
  BuildContext context,
  MediaResource entry, {
  int? index,
  ResolvedMedia? initialMedia,
  bool restartAudio = false,
}) async {
  if (entry.episodes.isEmpty) throw StateError('资源没有章节');
  final service = MediaResourceService();
  if (entry.kind == ResourceKind.audioBook) {
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AudioPlayerPage(
          resource: entry,
          tracks: service.audioTracks(
            entry,
            initialIndex: index,
            initialMedia: initialMedia,
          ),
          initialIndex: index,
          restart: restartAudio,
        ),
      ),
    );
    return;
  }
  {
    await PlaybackFocus.acquire('video');
    final media = await service.resolve(entry, entry.episodes[index ?? 0]);
    if (!context.mounted) return;
    final playback = PlayerMedia(
      uri: media.url,
      headers: media.headers,
      title: entry.title,
    );
    final prepared = await preparePlaybackRoute(
      playback,
      stillActive: () => context.mounted,
    );
    if (!context.mounted) {
      await prepared?.discard();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          media: playback,
          prelaunch: prepared,
          title: entry.title,
        ),
      ),
    );
    return;
  }
}
