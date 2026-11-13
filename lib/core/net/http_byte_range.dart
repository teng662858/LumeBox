import 'dart:io';
import 'dart:typed_data';

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

({int start, int end})? prepareHttpByteResponse(
  HttpRequest request, int length, String contentType,
) {
  final response = request.response;
  response.headers.set('Content-Type', contentType);
  response.headers.set('Accept-Ranges', 'bytes');
  var start = 0, end = length - 1;
  final range = request.headers.value('range');
  if (range != null) {
    final offsets = parseHttpByteRange(range, length);
    if (offsets == null) {
      response.statusCode = 416;
      response.headers.set('Content-Range', 'bytes */$length');
      return null;
    }
    start = offsets.start;
    end = offsets.end;
    response.statusCode = 206;
    response.headers.set(
      'Content-Range',
      'bytes $start-$end/$length',
    );
  }
  response.contentLength = end - start + 1;
  return (start: start, end: end);
}

void serveHttpBytes(HttpRequest request, Uint8List bytes, String contentType) {
  final offsets = prepareHttpByteResponse(request, bytes.length, contentType);
  if (offsets != null && request.method != 'HEAD') {
    request.response.add(Uint8List.sublistView(bytes, offsets.start, offsets.end + 1));
  }
}
