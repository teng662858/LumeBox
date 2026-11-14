import 'package:flutter/foundation.dart';

import '../media/media_library.dart';

class AudioBookFailure implements Exception {
  const AudioBookFailure(this.message, {this.retryChapter});
  final String message;
  final int? retryChapter;
  @override
  String toString() => message;
}

class ResolvedAudio {
  const ResolvedAudio(this.url, {this.headers = const {}});
  final Uri url;
  final Map<String, String> headers;
}

/// Engine-neutral playlist item. Pages never construct just_audio objects.
class AudioBookTrack {
  const AudioBookTrack({
    required this.id,
    required this.episode,
    required this.album,
    this.cover,
    this.resolve,
    this.initialMedia,
  });
  final String id, album;
  final String? cover;
  final ResourceEpisode episode;
  final Future<ResolvedAudio> Function()? resolve;
  final ResolvedAudio? initialMedia;

  bool canReuseFor(AudioBookTrack next) {
    if (identical(this, next)) return true;
    final incoming = next.initialMedia;
    return id == next.id &&
        album == next.album &&
        cover == next.cover &&
        episode.title == next.episode.title &&
        episode.url == next.episode.url &&
        mapEquals(episode.headers, next.episode.headers) &&
        (resolve == null) == (next.resolve == null) &&
        (incoming == null ||
            initialMedia?.url == incoming.url &&
                mapEquals(initialMedia?.headers, incoming.headers));
  }
}
