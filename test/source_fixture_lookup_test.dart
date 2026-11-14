import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_scripts.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-fixture-lookup-');
  });
  tearDown(() => root.delete(recursive: true));
  Future<File> source(String path) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '// LumeSource: {"id":"fixture_video","name":"测试","version":"1.0"}\n',
    );
    return file;
  }

  test('legacy script names resolve only a unique stable source ID', () async {
    await source('snapshots/player.js');
    expect(sourceAssetPath('fixture_video.js', cache: root), isNull);
    final renamed = await source('video/中文源.js');
    expect(File(sourceAssetPath('fixture_video.js', cache: root)!).uri, renamed.uri);
    await source('video/duplicate.js');
    expect(sourceAssetPath('fixture_video.js', cache: root), isNull);
    final exact = await source('video/fixture_video.js');
    expect(File(sourceAssetPath('fixture_video.js', cache: root)!).uri, exact.uri);
  });
}
