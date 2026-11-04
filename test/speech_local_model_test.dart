import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'download cancellation and bad archive preserve installed data',
    () async {
      final root = await Directory.systemTemp.createTemp('lumebox-vits-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      final target = Directory('${root.path}/speech/vits_aishell3');
      await target.create(recursive: true);
      final old = File('${target.path}/old');
      await old.writeAsString('keep');
      final prior = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.add([1, 2, 3]);
        await request.response.flush();
        if (!received.isCompleted) received.complete();
      });
      final model = SpeechLocalModel(
        downloadUri: Uri.parse('http://127.0.0.1:${server.port}/model'),
      );
      try {
        final pending = model.prepare();
        await received.future.timeout(const Duration(seconds: 5));
        model.cancel();
        expect(await pending, false);
        expect(model.error, '已取消');
        expect(await old.readAsString(), 'keep');
        final bad = File('${root.path}/bad.bz2');
        await bad.writeAsString('invalid');
        expect(await model.prepare(archiveFile: XFile(bad.path)), false);
        expect(model.error, contains('校验失败'));
        expect(await old.readAsString(), 'keep');
        expect(await model.check(), false);
        expect(model.present, true);
        await model.remove();
        expect(await target.exists(), false);
        expect(model.present, false);
      } finally {
        model.dispose();
        await server.close(force: true);
        HttpOverrides.global = prior;
        await root.delete(recursive: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
      }
    },
  );

  test('file chooser cancellation and errors are reported safely', () async {
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
    expect(model.error, isNull);
    model.dispose();
    final broken = SpeechLocalModel(
      pickArchive: () async => throw PlatformException(code: 'picker_failed'),
    );
    expect(await broken.prepare(fromFile: true), false);
    expect(broken.error, contains('无法打开文件选择器'));
    broken.dispose();
  });
}
