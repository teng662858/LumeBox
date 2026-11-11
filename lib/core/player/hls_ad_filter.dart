/// Only remove explicitly delimited ad breaks in finite, unencrypted HLS.
/// Discontinuities and different segment hosts alone are never evidence of ads.
abstract final class HlsAdFilter {
  static String filter(String text) {
    if (!text.contains('#EXT-X-ENDLIST') ||
        text.contains('#EXT-X-STREAM-INF:') ||
        text.contains('#EXT-X-KEY:') ||
        text.contains('#EXT-X-MAP:') ||
        text.contains('#EXT-X-BYTERANGE:')) {
      return text;
    }
    final lines = text.split('\n');
    final output = <String>[];
    var ad = false, removed = false;
    for (final line in lines) {
      final tag = line.trim();
      if (tag.startsWith('#EXT-X-CUE-OUT:') || tag == '#EXT-X-CUE-OUT') {
        if (ad) return text;
        ad = true;
        continue;
      }
      if (tag == '#EXT-X-CUE-IN' || tag.startsWith('#EXT-X-CUE-IN:')) {
        if (!ad) return text;
        ad = false;
        removed = true;
        output.add('#EXT-X-DISCONTINUITY');
        continue;
      }
      if (!ad) output.add(line);
    }
    if (ad ||
        !removed ||
        !output.any(
          (l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'),
        )) {
      return text;
    }
    return output.join('\n');
  }
}
