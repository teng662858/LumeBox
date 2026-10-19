import 'dart:io';
import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled pack prepares verified files without a picker; invalid imports preserve the installed model', () async {
    final root = await Directory.systemTemp.createTemp('lumebox-vits-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    var picks = 0;
    final model = SpeechLocalModel(
      pickArchive: () async {
        picks++;
        return null;
      },
    );
    try {
      expect(await model.check(), false);
      expect(await model.prepare(), true);
      expect(picks, 0);
      expect(model.ready, true);
      expect(model.error, isNull);
      expect(await model.check(), true);
      final archive = File('${root.path}/voice.tar.bz2');
      await archive.writeAsString('incomplete archive');
      expect(await model.prepare(archiveFile: XFile(archive.path)), false);
      expect(model.error, contains('校验失败'));
      expect(model.ready, true);
      expect(await model.check(), true);
      expect(
        await File('${model.directory!.path}/rule.far').exists(),
        false,
        reason: 'Unused 180 MB FAR data must not be extracted',
      );
      final tokens = File('${model.directory!.path}/tokens.txt');
      await tokens.writeAsString('tampered');
      expect(await model.check(), false);
      expect(model.ready, false);
    } finally {
      model.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('iOS picker types are present and cancellation or platform failure is reported safely', () async {
    expect(
      SpeechLocalModel.archiveType.uniformTypeIdentifiers,
      contains('public.data'),
    );
    final picked = Completer<XFile?>();
    final model = SpeechLocalModel(pickArchive: () => picked.future);
    final installing = model.prepare(fromFile: true);
    expect(model.preparing, true);
    expect(await model.prepare(fromFile: true), false);
    picked.complete(null);
    expect(await installing, false);
    expect(model.preparing, false);
    expect(model.ready, false);
    expect(model.error, isNull);
    model.dispose();
    final broken = SpeechLocalModel(
      pickArchive: () async => throw PlatformException(code: 'picker_failed'),
    );
    expect(await broken.prepare(fromFile: true), false);
    expect(broken.preparing, false);
    expect(broken.error, contains('无法打开文件选择器'));
    broken.dispose();
  });
}
