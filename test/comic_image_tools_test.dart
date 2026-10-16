import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/reading/comic_image_tools.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/features/comic/comic_image_tools_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 80),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(40, 80);
    bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  const region = {'text': 'こんにちは', 'x': .2, 'y': .3, 'width': .4, 'height': .1};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      switch (call.method) {
        case 'recognize':
          return [region];
        case 'translate':
          return ['你好'];
        case 'getKey':
          return 'test-secret';
        case 'superResolve':
          return bytes;
        default:
          return null;
      }
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(ComicImageTools.channel, null),
  );

  test(
    'model picker supplies an iOS UTI as well as desktop extension filters',
    () {
      final type = ComicImageToolsSettingsPage.modelFileTypes.single;
      expect(type.extensions, contains('mlmodel'));
      expect(type.uniformTypeIdentifiers, contains('public.data'));
    },
  );
  testWidgets(
    'model picker failure is visible and the import button can retry',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ComicImageToolsSettingsPage(
            pickModelFile: () async {
              attempts++;
              throw PlatformException(code: 'picker_failed');
            },
          ),
        ),
      );
      final button = find.byKey(const Key('import-super-resolution-model'));
      await tester.scrollUntilVisible(button, 250);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('无法打开文件选择器或安装模型，请重试'), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancelling model selection clears the busy state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicImageToolsSettingsPage(pickModelFile: () async => null),
      ),
    );
    final button = find.byKey(const Key('import-super-resolution-model'));
    await tester.scrollUntilVisible(button, 250);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('已取消选择模型'), findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
  test(
    'AI photo and manga model types reach the native backend independently',
    () async {
      final calls = <Map>[];
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'superResolve') {
          calls.add(call.arguments as Map);
          return bytes;
        }
        return null;
      });
      final settings = ComicImageToolsSettings()
        ..imageStyle = 'photo'
        ..noise = 2;
      final tools = ComicImageTools(settings: settings);
      await tools.superResolve(bytes);
      settings.imageStyle = 'anime';
      await tools.superResolve(bytes);
      expect(calls.map((args) => args['imageStyle']), ['photo', 'anime']);
      expect(calls.map((args) => args['noise']), [2, 2]);
      tools.imageStyle = 'photo';
      await tools.superResolve(bytes);
      expect(calls.last['imageStyle'], 'photo', reason: '美图源选择覆盖全局漫画默认值');
      expect(settings.imageStyle, 'anime', reason: '源内模型选择不改全局设置');
      tools.dispose();
    },
  );

  test('model files match pinned provenance and license', () {
    final origin = jsonDecode(
      File('assets/models/waifu2x/ORIGIN.json').readAsStringSync(),
    ) as Map;
    for (final entry in (origin['sha256'] as Map).entries) {
      expect(
        sha256
            .convert(
              File('assets/models/waifu2x/${entry.key}').readAsBytesSync(),
            )
            .toString(),
        entry.value,
      );
    }
    expect(
      File('assets/models/waifu2x/LICENSE').readAsStringSync(),
      contains('Permission is hereby granted'),
    );
  });

  test(
    'device translation preserves OCR positions and original text',
    () async {
      final tools = ComicImageTools(settings: ComicImageToolsSettings());
      addTearDown(tools.dispose);
      final result = await tools.translate(bytes);
      expect(result.single.text, 'こんにちは');
      expect(result.single.translation, '你好');
      expect(result.single.x, .2);
      expect(result.single.y, .3);
      expect(result.single.height, .1);
    },
  );

  test(
    'AI sends text only, honors language and validates ordered JSON results',
    () async {
      final settings = ComicImageToolsSettings()
        ..ai = true
        ..endpoint = 'https://translation.example/v1/chat/completions'
        ..model = 'my-model';
      final client = MockClient((request) async {
        expect(request.followRedirects, false);
        expect(request.headers['Authorization'], 'Bearer test-secret');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'my-model');
        expect(
          jsonDecode(
            ((body['messages'] as List).last as Map)['content'] as String,
          ),
          ['こんにちは'],
        );
        expect(request.body, isNot(contains('image_url')));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '["你好"]'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      final tools = ComicImageTools(settings: settings, client: client);
      addTearDown(tools.dispose);
      expect((await tools.translate(bytes)).single.translation, '你好');
    },
  );

  test('malformed AI response cannot overwrite translation', () async {
    final settings = ComicImageToolsSettings()
      ..ai = true
      ..endpoint = 'https://translation.example/v1/chat/completions'
      ..model = 'my-model';
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '[]'},
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    await expectLater(tools.translate(bytes), throwsFormatException);
    for (final url in [
      'http://bad.example',
      'https://user:secret@example.com',
      'file:///tmp/model',
    ]) {
      expect(
        () => ComicImageTools.validateEndpoint(url),
        throwsFormatException,
      );
    }
  });

  test('closing reader cancels native jobs and rejects stale result', () async {
    final response = Completer<Object?>();
    final started = Completer<void>();
    final cancelled = <String>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'superResolve') {
        started.complete();
        return response.future;
      }
      if (call.method == 'cancel') {
        cancelled.add((call.arguments as Map)['id'] as String);
      }
      return null;
    });
    final tools = ComicImageTools();
    final future = tools.superResolve(bytes);
    final expectation = expectLater(future, throwsStateError);
    await started.future;
    tools.dispose();
    response.complete(bytes);
    await expectation;
    expect(cancelled, hasLength(1));
  });

  test(
    'automatic off returns exact original bytes without native calls',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (_) async {
        calls++;
        return null;
      });
      final tools = ComicImageTools(settings: ComicImageToolsSettings());
      expect(identical(await tools.automatic(bytes), bytes), true);
      expect(calls, 0);
      tools.dispose();
    },
  );

  test('decode enhancement leaves exported bytes unchanged', () async {
    final dir = Directory.systemTemp.createTempSync('comic-enhancement');
    var enhanced = 0;
    final pipeline = SectionImagePipeline(
      cacheDir: dir.path,
      diskCache: false,
      decodeTransform: (original) async {
        enhanced++;
        expect(original, bytes);
        return original;
      },
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: bytes,
        headers: const {'content-type': 'image/png'},
      ),
    );
    addTearDown(() {
      pipeline.dispose();
      dir.deleteSync(recursive: true);
    });
    final image = await pipeline.image('https://images.example/page.png');
    expect(image, isNotNull);
    expect(enhanced, 1);
    expect(await pipeline.bytes('https://images.example/page.png'), bytes);
    expect(enhanced, 1);
    pipeline.release('https://images.example/page.png');
  });

  testWidgets(
    'current page can translate, compare original and display failures',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ComicImageToolsPage(loadOriginal: () async => bytes)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('翻译当前页'));
      await tester.pumpAndSettle();
      expect(find.text('你好'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('你好'), findsNothing);
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'superResolve') {
          throw PlatformException(code: 'memory', message: '图片过大，原图保留');
        }
        return null;
      });
      await tester.tap(find.text('AI 超分当前图片'));
      await tester.pumpAndSettle();
      expect(find.text('图片过大，原图保留'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    },
  );
}
