/// Optional source-provided stills. Times are seconds; no video seek is required.
class VideoPreview {
  const VideoPreview(this.seconds, this.url, {this.headers = const {}});
  final int seconds;
  final Uri url;
  final Map<String, String> headers;
  static List<VideoPreview> parse(Object? value) {
    if (value is! List) return const [];
    final result = <VideoPreview>[];
    for (final item in value.take(2000)) {
      if (item is! Map) continue;
      final seconds = num.tryParse('${item['time'] ?? item['seconds']}');
      final url = Uri.tryParse('${item['url'] ?? ''}');
      if (seconds == null ||
          !seconds.isFinite ||
          seconds < 0 ||
          seconds > 604800 ||
          url == null ||
          !['http', 'https'].contains(url.scheme)) {
        continue;
      }
      result.add(
        VideoPreview(
          seconds.toInt(),
          url,
          headers: {
            if (item['headers'] is Map)
              for (final e in (item['headers'] as Map).entries)
                if (e.value is String) '${e.key}': e.value as String,
          },
        ),
      );
    }
    result.sort((a, b) => a.seconds.compareTo(b.seconds));
    return result;
  }
}
