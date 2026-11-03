import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source_package.dart';

void main() {
  test('PY独立总订阅完整展开304个源，保留运行时、归属和稳定ID', () async {
    final index = jsonDecode(
      File('sources/python-collection.json').readAsStringSync(),
    ) as Map;
    final published = (index['sources'] as List)
        .cast<Map>()
        .where((row) => row['status'] == 'published')
        .toList();
    final ids = <String>{};
    for (final section in [Section.comic, Section.video]) {
      final skipped = <String>[];
      final resolver = SourceSubscription(
        onSkip: (url, error) => skipped.add("$url: $error"),
        section: section.id,
        fetch: (url) async {
          final path = Uri.decodeComponent(
            Uri.parse(url).path.split('/main/').last,
          );
          final bytes = File('sources/$path').readAsBytesSync();
          return SourceFetchResult(
            bytes: Uint8List.fromList(bytes),
            text: utf8.decode(bytes),
          );
        },
      );
      final refs = await resolver.resolveRefs([
        'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/subscriptions/python.json',
      ]);
      for (final ref in refs) {
        expect(SourcePackage.kindOf(ref.script), SourcePackageKind.python);
        final meta = SourceMetadata.parseHeader(ref.script)!;
        expect(meta.category, section.id);
        expect(ids.add(meta.id), isTrue, reason: '同一源不能在两个板块重复导入');
      }
      expect(resolver.complete, isTrue, reason: skipped.join("\n"));
    }
    expect(ids, published.map((r) => r['id']).toSet());
    expect(ids.length, 304);
  });
}
