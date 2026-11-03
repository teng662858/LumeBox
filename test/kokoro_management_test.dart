import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cancel stops download and a later attempt can retry', () async {
    final root = await Directory.systemTemp.createTemp('kokoro-cancel-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    final prior = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final first = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.binary;
      request.response.add([1, 2, 3]);
      await request.response.flush();
      if (requests == 1) {
        first.complete();
      } else {
        await request.response.close();
      }
    });
    final model = KokoroModel(
      downloadUri: Uri.parse('http://127.0.0.1:${server.port}/model'),
    );
    final installation = model.install();
    await first.future.timeout(const Duration(seconds: 5));
    model.cancel();
    expect(await installation, isFalse);
    expect(model.error, '已取消');
    expect(model.preparing, isFalse);
    expect(await model.install(), isFalse);
    expect(model.error, '模型校验失败');
    expect(requests, 2);
    await server.close(force: true);
    HttpOverrides.global = prior;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  test(
    'Kokoro rejects incomplete installation and removes only its own files',
    () async {
      final root = await Directory.systemTemp.createTemp('kokoro-management-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      final kokoro = Directory('${root.path}/speech/kokoro');
      final vits = Directory('${root.path}/speech/vits_aishell3');
      await kokoro.create(recursive: true);
      await vits.create(recursive: true);
      await File('${kokoro.path}/.ready').writeAsString(KokoroModel.digest);
      await File('${kokoro.path}/model.int8.onnx').writeAsString('truncated');
      await File('${vits.path}/keep').writeAsString('keep');
      final model = KokoroModel();
      expect(await model.check(), isFalse);
      expect(model.present, isTrue);
      await model.remove();
      expect(await kokoro.exists(), isFalse);
      expect(await File('${vits.path}/keep').exists(), isTrue);
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await root.delete(recursive: true);
    },
  );
}
