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
