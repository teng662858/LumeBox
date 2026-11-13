import 'hls_attributes.dart';

/// Pair each variant declaration with its URI, skipping comments and blank lines.
Iterable<({int tag, int uri})> hlsVariants(List<String> lines) sync* {
  int? pending;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = i;
    } else if (line.startsWith('#EXT')) {
      pending = null;
    } else if (pending != null && line.isNotEmpty && !line.startsWith('#')) {
      yield (tag: pending, uri: i);
      pending = null;
    }
  }
}

/// Null means that the master does not declare enough to identify the stream.
bool? hlsVariantHasVideo(Map<String, String> attributes) {
  if (attributes.containsKey('RESOLUTION') ||
      attributes.containsKey('VIDEO') || attributes.containsKey('FRAME-RATE')) {
    return true;
  }
  final codecs = hlsAttributeValue(attributes['CODECS'] ?? '').split(',')
      .map((codec) => codec.trim().toLowerCase().split('.').first);
  const video = {'avc1', 'avc3', 'hvc1', 'hev1', 'dvh1', 'dvhe', 'av01', 'vp09', 'vp9', 'mp4v'};
  const audio = {'mp4a', 'ac-3', 'ec-3', 'ac-4', 'alac', 'flac', 'opus', 'mp3'};
  if (codecs.any(video.contains)) return true;
  return codecs.every(audio.contains) ? false : null;
}
