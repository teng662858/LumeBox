import '../video/playback_entry_preparation.dart';

import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../../core/player/abstract_player.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../video/playback_quality_preference.dart';
import '../video/source_playback.dart';
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
  final library = sourced ? await ReadingLibrary.open(origin) : null;
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
  DataSource? source;
  var qualities = const <VideoQuality>[];
  var media = initialMedia;
  if (media == null && episode.url == null && sourced) {
    source = await manager!.open(sourceId);
    if (source == null) throw StateError('源不可用');
    final content = await source.content(itemId: itemId, chapterId: episode.id);
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
  if (!context.mounted) return;
  final playback = PlayerMedia(
    uri: media.url,
    headers: media.headers,
    title: target?.mediaTitle ?? entry.title,
  );
  final prepared = await preparePlaybackRoute(
    playback,
    library: library,
    target: target,
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
}
