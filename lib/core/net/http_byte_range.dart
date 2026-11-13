/// Parses one HTTP byte range against a known representation length.
/// Returns inclusive offsets, or null for an invalid or unsatisfiable range.
({int start, int end})? parseHttpByteRange(String header, int length) {
  if (length <= 0) return null;
  final match = RegExp(
    r'^bytes=(\d*)-(\d*)$',
    caseSensitive: false,
  ).firstMatch(header.trim());
  if (match == null) return null;
  final first = match[1]!, last = match[2]!;
  // An arbitrarily large decimal offset is past EOF. An equally large
  // suffix or end offset may still describe a valid range.
  int bounded(String digits) =>
      (int.tryParse(digits) ?? length).clamp(0, length);
  if (first.isEmpty) {
    if (last.isEmpty) return null;
    final count = bounded(last);
    return count == 0 ? null : (start: length - count, end: length - 1);
  }
  final start = bounded(first);
  final end = last.isEmpty ? length - 1 : bounded(last).clamp(0, length - 1);
  return start > end ? null : (start: start, end: end);
}
