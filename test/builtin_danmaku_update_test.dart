import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/cat/builtin_danmaku_bundle.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/builtin_danmaku_release.json').readAsStringSync(),
  ) as Map;
  test('publisher signature accepts the release and rejects modified data', () {
    final data = utf8.encode(fixture['manifest']);
    final signature = base64Decode(fixture['signature']);
    expect(BuiltinDanmakuBundle.signed(data, signature), isTrue);
    expect(BuiltinDanmakuBundle.signed([...data, 32], signature), isFalse);
    expect(BuiltinDanmakuBundle.signed(data, [0, 1]), isFalse);
  });
  for (final tamper in [false, true]) {
    test(
      'downloaded component activates only after signature and hash checks: tamper=$tamper',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'builtin-danmaku-update',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final requested = <String>[];
        final client = MockClient((request) async {
          requested.add(request.url.path);
          final name = request.url.pathSegments.last;
          final value = switch (name) {
            'main' => jsonEncode({'sha': 'a' * 40}),
            'manifest.json' => fixture['manifest'] as String,
            'manifest.sig' => fixture['signature'] as String,
            _ => '${fixture['files'][name]}${tamper ? 'changed' : ''}',
          };
          return http.Response(value, 200);
        });
        await BuiltinDanmakuBundle.update(directory, {}, client: client);
        expect(await File('${directory.path}/active.json').exists(), !tamper);
        expect(
          requested
              .where((p) => p.contains('/mobile/'))
              .every((p) => p.contains('/${'a' * 40}/')),
          isTrue,
        );
        client.close();
      },
    );
  }
}
