import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/media_range_response.dart';

void main() {
  const oldDate = 'Mon, 10 Nov 2025 10:00:00 GMT';
  const newDate = 'Tue, 11 Nov 2025 10:00:00 GMT';

  Future<List<int>> assemble(List<Map<String, String>> validators) {
    MediaRangeResponse part(int offset) {
      final headers = {
        'content-range': 'bytes $offset-$offset/${validators.length}',
        ...validators[offset],
      };
      return MediaRangeResponse(
        Stream.value([offset]),
        206,
        Uri.parse('https://media.test/list.m3u8'),
        (name) => headers[name],
        const {},
      );
    }

    return completeMediaBody(
      part(0),
      next: (_, offset) async => part(offset),
    ).fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  }

  for (final (name, headers) in [
    (
      'omitted ETag',
      [
        {'etag': '"one"', 'last-modified': oldDate},
        {'last-modified': oldDate},
      ],
    ),
    (
      'new ETag alongside the same date',
      [
        {'last-modified': oldDate},
        {'etag': '"one"', 'last-modified': oldDate},
      ],
    ),
    (
      'alternating validator kinds',
      [
        {'etag': '"one"'},
        {'last-modified': oldDate},
        {'etag': '"one"'},
      ],
    ),
    (
      'stable ETag with refreshed metadata',
      [
        {'etag': '"one"', 'last-modified': oldDate},
        {'etag': '"one"', 'last-modified': newDate},
        {'last-modified': newDate},
      ],
    ),
  ]) {
    test('contiguous ranges accept $name', () async {
      expect(await assemble(headers), List.generate(headers.length, (i) => i));
    });
  }

  for (final (name, headers) in [
    (
      'changed ETag',
      [
        {'etag': '"one"', 'last-modified': oldDate},
        {'etag': '"two"', 'last-modified': oldDate},
      ],
    ),
    (
      'changed date without ETag',
      [
        {'last-modified': oldDate},
        {'last-modified': newDate},
      ],
    ),
    (
      'changed date when ETag is omitted',
      [
        {'etag': '"one"', 'last-modified': oldDate},
        {'last-modified': newDate},
      ],
    ),
    (
      'changed ETag after an omitted response',
      [
        {'etag': '"one"', 'last-modified': oldDate},
        {'last-modified': oldDate},
        {'etag': '"two"', 'last-modified': oldDate},
      ],
    ),
  ]) {
    test('contiguous ranges reject $name', () async {
      await expectLater(assemble(headers), throwsA(isA<HttpException>()));
    });
  }
}
