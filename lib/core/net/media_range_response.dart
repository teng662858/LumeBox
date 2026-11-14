import 'dart:async';
import 'dart:io';

import 'http_header_scope.dart';

final mediaContentRange = RegExp(
  r'^bytes (\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);

class MediaRangeResponse extends StreamView<List<int>> {
  MediaRangeResponse(
    super.stream,
    this.statusCode,
    this.uri,
    this.header,
    this.requestHeaders,
  );
  final int statusCode;
  final Uri uri;
  final String? Function(String name) header;
  final Map<String, String> requestHeaders;
  bool get hasOriginHeaders => requestHeaders.keys.any(isOriginBoundHttpHeader);
}

/// Assemble a single representation from an ordinary GET or contiguous HTTP ranges.
Stream<List<int>> completeMediaBody(
  MediaRangeResponse first, {
  required Future<MediaRangeResponse> Function(MediaRangeResponse, int) next,
  void Function(MediaRangeResponse)? playlistPart,
  bool allowRedirects = false,
}) async* {
  if (first.statusCode == 200) {
    yield* first;
    return;
  }
  final encoding = first.header('content-encoding');
  final resource = first.uri.removeFragment();
  String? etag;
  String? lastModified;
  var offset = 0;
  int? total;
  var part = first;
  while (true) {
    // Playlist origins may explicitly route their continuation ranges to a
    // CDN. The rewriter scopes child credentials across every such hop.
    if (!allowRedirects && part.uri.removeFragment() != resource) {
      await part.listen(null).cancel();
      throw const HttpException('媒体分片已变化');
    }
    final nextEtag = part.header('etag');
    final nextModified = part.header('last-modified');
    // Continuations may omit either header. Compare like validators, preferring
    // ETag, and retain it across omissions to catch a later revision change.
    final changed = etag != null && nextEtag != null
        ? etag != nextEtag
        : lastModified != null &&
              nextModified != null &&
              lastModified != nextModified;
    if (changed) {
      await part.listen(null).cancel();
      throw const HttpException('媒体分片已变化');
    }
    etag ??= nextEtag;
    lastModified = nextModified ?? lastModified;
    if (offset > 0 &&
        part.statusCode == 416 &&
        total == null &&
        part.header('content-range') == 'bytes */$offset') {
      await part.listen(null).cancel();
      return;
    }
    final range = mediaContentRange.firstMatch(
      part.header('content-range') ?? '',
    );
    final end = int.tryParse(range?[2] ?? '');
    final size = int.tryParse(range?[3] ?? '');
    if (part.statusCode != 206 ||
        part.header('content-encoding') != encoding ||
        int.tryParse(range?[1] ?? '') != offset ||
        end == null ||
        end < offset ||
        end == 0x7fffffffffffffff ||
        (size == null && range?[3] != '*') ||
        (size != null && total != null && size != total)) {
      await part.listen(null).cancel();
      throw const HttpException('媒体分片范围不匹配');
    }
    total ??= size;
    if (total != null && end >= total) {
      await part.listen(null).cancel();
      throw const HttpException('媒体分片长度无效');
    }
    playlistPart?.call(part);
    await for (final bytes in part) {
      if (bytes.length > end + 1 - offset) {
        throw const HttpException('媒体分片超过声明范围');
      }
      offset += bytes.length;
      yield bytes;
    }
    if (offset != end + 1) throw const HttpException('媒体分片不完整');
    if (offset == total) return;
    part = await next(part, offset);
  }
}
