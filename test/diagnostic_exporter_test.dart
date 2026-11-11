import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/settings/diagnostic_exporter.dart';
import 'package:lume_box/core/util/lume_log.dart';

void main() {
  test('redaction is stable across repeated persistence and exports', () {
    var message =
        'failed https://cdn.test/private?token=secret User-Agent,Referer';
    for (var i = 0; i < 5; i++) {
      message = DiagnosticExporter.redact(message);
      expect(
        message,
        'failed https://cdn.test/[path omitted] User-Agent,Referer',
      );
    }
    expect(
      DiagnosticExporter.redact(
        'https://cdn.test/[path omitted] omitted] omitted]',
      ),
      'https://cdn.test/[path omitted]',
    );
  });
  test(
    'diagnostic ZIP preserves useful context and excludes sensitive values',
    () {
      final result = DiagnosticExporter.build(
        created: DateTime(2026, 10, 16),
        metadata: {
          'app': {'version': '1.0.136', 'build': '136'},
          'apiKey': 'my-private-key',
          'configuration': {
            'token': 'tmdb-private-token',
            'imageStyle': 'photo',
          },
          'source': {
            'id': 'source-a',
            'name': '示例站点',
            'error': 'GET https://user:pass@source.test/private/book?token=private-url-token',
          },
        },
        logs: [
          LogEntry(
            time: DateTime(2026, 10, 16),
            level: LogLevel.error,
            message: 'Playback failed source-a\nAuthorization: Bearer private-bearer\nCookie: cf_clearance=private-cookie; a=b\nAPI-Key: private-api\ntoken=private-token\nC:\\Users\\private-user\\settings.json\n/data/user/private-user/config.json\ncontact private@example.com',
            detail: 'stack: player.dart:42',
          ),
        ],
      );
      final archive = ZipDecoder().decodeBytes(result.bytes);
      expect(
        archive.files.map((file) => file.name),
        containsAll(['diagnostics.json', 'recent-logs.txt', 'README.txt']),
      );
      final text = archive.files
          .map((file) => utf8.decode(file.content as List<int>))
          .join('\n');
      for (final secret in [
        'my-private-key',
        'tmdb-private-token',
        'private-url-token',
        'private-bearer',
        'private-cookie',
        'private-api',
        'private-token',
        'private-user',
        'private@example.com',
        'user:pass',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('source-a'));
      expect(text, contains('示例站点'));
      expect(text, contains('source.test'));
      expect(text, contains('player.dart:42'));
      expect(text, contains('photo'));
    },
  );
  test('empty diagnostics remains a valid readable ZIP', () {
    final result = DiagnosticExporter.build(
      created: DateTime(2026),
      metadata: {'version': 'unavailable'},
      logs: [],
    );
    expect(result.name, endsWith('.zip'));
    expect(ZipDecoder().decodeBytes(result.bytes).files.length, 3);
  });
}
