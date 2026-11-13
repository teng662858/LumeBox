import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/playback_diagnostics.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../video/playback_entry_preparation.dart';
import '../video/playback_quality_preference.dart';
import '../video/source_playback.dart';
import '../video/video_download_center.dart';
import '../video/video_play_target.dart';
import '../video/video_player_page.dart';
import '../video/video_player_settings.dart';
import 'audio_player_page.dart';

Future<void> openMediaResource(
  BuildContext context,
  MediaResource entry, {
  int? index,
  Duration? position,
  ResolvedMedia? initialMedia,
  bool restartAudio = false,
  VideoDownloadCenter? downloadCenter,
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
          initialPosition: position,
          restart: restartAudio,
        ),
      ),
    );
    return;
  }
  final origin = entry.originSection,
      sourceId = entry.sourceId,
      itemId = entry.itemId;
  final sourced = origin != null && sourceId != null && itemId != null;
  final route = ModalRoute.of(context);
  final library = sourced ? await ReadingLibrary.open(origin) : null;
  if (!context.mounted || route?.isCurrent == false) return;
  final manager = sourced ? LumeSources.manager(origin) : null;
  var selected = index ?? 0;
  if (index == null && library != null) {
    final saved = library.videoProgress(itemId!, sourceId: sourceId);
    final found = entry.episodes.indexWhere((e) => e.id == saved?.chapterId);
    if (found >= 0) selected = found;
  }
  if (selected < 0 || selected >= entry.episodes.length) {
    throw StateError('所选剧集已从目录移除');
  }
  final episode = entry.episodes[selected];
  final target = sourced
      ? VideoPlayTarget(
          sourceId: sourceId,
          itemId: itemId,
          title: entry.title,
          cover: entry.cover,
          chapterIndex: selected,
          chapterId: episode.id,
          chapterTitle: episode.title,
        )
      : null;
  DownloadedVideoPlayback? offline;
  try {
    if (sourced) {
      try {
        offline = await (downloadCenter ?? VideoDownloadCenter.instance)
            .completedPlayback(sourceId, itemId, episode.id, section: origin);
      } catch (_) {
        PlaybackDiagnostics.record('offline-lookup-failed', source: sourceId);
      }
      if (!context.mounted || route?.isCurrent == false) return;
    }
    DataSource? source;
    var qualities = const <VideoQuality>[];
    final title = target?.mediaTitle ?? entry.title;
    final PlayerMedia playback;
    if (offline != null) {
      playback = offline.media(title);
    } else {
      var media = initialMedia;
      if (media == null && episode.url == null && sourced) {
        source = await manager!.open(sourceId);
        if (!context.mounted || route?.isCurrent == false) return;
        if (source == null) throw StateError('源不可用');
        final content = await source.content(
          itemId: itemId,
          chapterId: episode.id,
        );
        if (!context.mounted || route?.isCurrent == false) return;
        if (content is! VideoContent) throw StateError('源没有返回视频地址');
        qualities = SourcePlayback.contentQualities(content, source: source);
        final quality = PlaybackQualityPreference.select(
          qualities,
          VideoPlayerSettingsStore(library!).load(),
        );
        media = ResolvedMedia(
          quality?.url ?? content.url,
          headers:
              quality?.headers ??
              SourcePlayback.contentHeaders(content, source: source),
        );
      }
      media ??= await service.resolve(entry, episode);
      if (!context.mounted || route?.isCurrent == false) return;
      playback = PlayerMedia(
        uri: media.url,
        headers: media.headers,
        title: title,
      );
    }
    final prepared = await preparePlaybackRoute(
      playback,
      library: library,
      target: target,
      stillActive: () => context.mounted && route?.isCurrent != false,
    );
    if (!context.mounted || route?.isCurrent == false) {
      await prepared?.discard();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          media: playback,
          initialPosition: position,
          prelaunch: prepared,
          title: entry.title,
          target: target,
          library: library,
          source: source,
          sourceManager: manager,
          qualities: qualities,
        ),
      ),
    );
  } finally {
    await offline?.close();
  }
}
