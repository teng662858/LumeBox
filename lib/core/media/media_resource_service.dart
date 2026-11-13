import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../source/source.dart';
import '../cat/cat_data_source.dart';
import '../cat/cat_service.dart';
import '../session/section.dart';
import '../net/waf.dart';
import '../net/source_request_log.dart';
import 'media_library.dart';
import '../audio_book/audio_book_track.dart';

class MediaResourceService {
  MediaResourceService({
    this.probe = const MediaTrackProbe(),
    MediaLibrary? library,
  }) : library = library ?? MediaLibrary.instance;
  final MediaTrackProbe probe;
  final MediaLibrary library;
  static SourceManager sourceManager(Section section) => section == Section.cat
      ? CatAggregateSourceManager(CatService.instance)
      : LumeSources.manager(section);

  List<AudioBookTrack> audioTracks(
    MediaResource resource, {
    int? initialIndex,
    ResolvedMedia? initialMedia,
  }) => [
    for (var i = 0; i < resource.episodes.length; i++)
      _audioTrack(
        resource,
        resource.episodes[i],
        initialMedia: i == initialIndex ? initialMedia : null,
      ),
  ];

  AudioBookTrack _audioTrack(
    MediaResource resource,
    ResourceEpisode episode, {
    ResolvedMedia? initialMedia,
  }) {
    var prepared = initialMedia;
    return AudioBookTrack(
      id: '${resource.id}/${episode.id}',
      episode: episode,
      album: resource.title,
      cover: resource.cover,
      resolve: () async {
        final media = prepared ?? await resolve(resource, episode);
        prepared = null;
        return ResolvedAudio(media.url, headers: media.headers);
      },
    );
  }

  static Uri? address(ChapterContent? content) {
    if (content is VideoContent) return content.url;
    return null;
  }

  static Map<String, String> headers(
    ChapterContent? content, {
    DataSource? source,
  }) {
    final result = content is VideoContent
        ? Map<String, String>.of(content.headers)
        : <String, String>{};
    if (source == null) return result;
    final ua =
        WafSessions.userAgentFor(source.section, source.id)?.trim() ?? '';
    final url = address(content);
    final cookie =
        url != null && SourceRequestLog.ownsHost(source.id, url.toString())
        ? WafSessions.cookiesFor(source.section, source.id)?.trim() ?? ''
        : '';
    if (ua.isNotEmpty) {
      result.removeWhere((key, _) => key.toLowerCase() == 'user-agent');
      result['User-Agent'] = ua;
    }
    if (cookie.isNotEmpty &&
        !result.keys.any((key) => key.toLowerCase() == 'cookie')) {
      result['Cookie'] = cookie;
    }
    return result;
  }

  Future<MediaResource> source({
    required DataSource source,
    required SourceItem item,
    required List<SourceChapter> chapters,
    ResourceKind? hint,
    ChapterContent? firstContent,
    MediaTrackInfo? trackInfo,
    bool deferContent = false,
  }) async {
    await library.boot();
    final origin = source is CatDataSource ? Section.cat : source.section;
    final id = MediaResource.sourceKey(origin, source.id, item.id);
    final previous = library.byId(id);
    if (previous?.manual == true) {
      return library.add(
        MediaResource(
          id: id,
          title: item.title,
          kind: previous!.kind,
          destination: previous.destination,
          manual: true,
          originSection: origin,
          sourceId: source.id,
          itemId: item.id,
          cover: item.cover ?? previous.cover,
          episodes: chapters.isEmpty
              ? previous.episodes
              : [
                  for (final chapter in chapters)
                    ResourceEpisode(id: chapter.id, title: chapter.title),
                ],
        ),
      );
    }
    final content =
        firstContent ??
        (deferContent || chapters.isEmpty
            ? null
            : await source.content(
                itemId: item.id,
                chapterId: chapters.first.id,
              ));
    final uri = address(content);
    final tracks =
        trackInfo ??
        (uri == null
            ? const MediaTrackInfo()
            : await probe.inspect(
                uri,
                headers: headers(content, source: source),
              ));
    final kind = tracks.kind ?? hint ?? ResourceKind.video;
    return library.add(
      MediaResource(
        id: id,
        title: item.title,
        kind: kind,
        destination: kind.defaultSection,
        originSection: origin,
        sourceId: source.id,
        itemId: item.id,
        cover: item.cover,
        episodes: [
          for (final chapter in chapters)
            ResourceEpisode(id: chapter.id, title: chapter.title),
        ],
      ),
    );
  }

  Future<MediaResource> file(
    File input, {
    required String name,
    ResourceKind? chosen,
  }) async {
    final support = await getApplicationSupportDirectory();
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final target = File(
      '${support.path}/media/$id/${Uri.encodeComponent(name)}',
    );
    await target.parent.create(recursive: true);
    await input.copy(target.path);
    final tracks = await probe.inspect(target.uri);
    final kind = chosen ?? tracks.kind ?? ResourceKind.video;
    return library.add(
      MediaResource(
        id: id,
        title: name,
        kind: kind,
        destination: kind.defaultSection,
        manual: chosen != null,
        episodes: [ResourceEpisode(id: id, title: name, url: target.uri)],
      ),
    );
  }

  Future<ResolvedMedia> resolve(
    MediaResource resource,
    ResourceEpisode episode,
  ) async {
    if (episode.url != null) {
      return ResolvedMedia(episode.url!, headers: episode.headers);
    }
    final section = resource.originSection,
        sourceId = resource.sourceId,
        item = resource.itemId;
    if (section == null || sourceId == null || item == null) {
      throw StateError('缺少源引用');
    }
    final source = await sourceManager(section).open(sourceId);
    if (source == null) throw StateError('源不可用');
    final content = await source.content(itemId: item, chapterId: episode.id);
    final uri = address(content);
    if (uri == null) throw StateError('源没有返回媒体地址');
    return ResolvedMedia(uri, headers: headers(content, source: source));
  }
}

class ResolvedMedia {
  const ResolvedMedia(this.url, {this.headers = const {}});
  final Uri url;
  final Map<String, String> headers;
}
