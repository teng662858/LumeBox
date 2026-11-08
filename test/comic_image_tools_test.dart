import 'package:lume_box/core/translation/text_translation.dart';

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
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/session/section.dart';
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

  test('recognize sorts OCR regions for single-speaker reading', () async {
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method != 'recognize') {
        throw StateError('unexpected ${call.method}');
      }
      return [
        {'text': '底部', 'x': .1, 'y': .8, 'width': .5, 'height': .1},
        {'text': '右上', 'x': .6, 'y': .1, 'width': .2, 'height': .1},
        {'text': '左上', 'x': .1, 'y': .1, 'width': .2, 'height': .1},
        {'text': '  ', 'x': .3, 'y': .5, 'width': .1, 'height': .1},
      ];
    });
    final tools = ComicImageTools();
    expect(await tools.recognize(bytes), ['左上', '右上', '底部']);
    tools.dispose();
  });

  test('长图相邻行按实际文字高度排序，不把相隔面板误判为同一行', () async {
    messenger.setMockMethodCallHandler(
      ComicImageTools.channel,
      (call) async => [
        {'text': '下面一行', 'x': .1, 'y': .112, 'width': .3, 'height': .002},
        {'text': '上面一行', 'x': .8, 'y': .1, 'width': .1, 'height': .002},
      ],
    );
    final tools = ComicImageTools();
    expect(await tools.recognize(bytes), ['上面一行', '下面一行']);
    tools.dispose();
  });

  test(
    'selected bubble combines OCR lines into one translation request',
    () async {
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'recognize') {
          return [
            {
              'text': 'selected-bubble-line-one',
              'x': .1,
              'y': .1,
              'width': .7,
              'height': .2,
            },
            {
              'text': 'selected-bubble-line-two',
              'x': .1,
              'y': .4,
              'width': .7,
              'height': .2,
            },
          ];
        }
        if (call.method == 'translate') {
          expect((call.arguments as Map)['texts'], [
            'selected-bubble-line-one\nselected-bubble-line-two',
          ]);
          return ['一整句对白'];
        }
        return null;
      });
      final tools = ComicImageTools();
      tools.preferences.ai = false;
      addTearDown(tools.dispose);
      final regions = await tools.translateSelectedRegion(bytes);
      expect(regions.single.translation, '一整句对白');
      expect(regions.single.width, 1);
    },
  );

  test('部分翻译失败仍返回成功区域，失败对白保留原图并给出简短提示', () async {
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'recognize') {
        return [
          {
            'text': 'partial-regression-one',
            'x': .1,
            'y': .1,
            'width': .3,
            'height': .1,
          },
          {
            'text': 'partial-regression-two',
            'x': .1,
            'y': .4,
            'width': .3,
            'height': .1,
          },
        ];
      }
      if (call.method == 'translate') {
        throw PlatformException(
          code: 'translation_partial',
          message: 'unsupported pair',
          details: ['成功译文', ''],
        );
      }
      return null;
    });
    final tools = ComicImageTools();
    addTearDown(tools.dispose);
    final regions = await tools.translate(bytes);
    expect(regions.length, 1);
    expect(regions.single.translation, '成功译文');
    expect(tools.lastTranslationWarning, contains('成功译文与原图已保留'));
  });

  test('长图多于 250 个文字区域分批翻译，保留文字与全图坐标对应', () async {
    final batches = <List<String>>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'recognize') {
        return [
          for (var i = 0; i < 251; i++)
            {
              'text': 'line-$i',
              'x': .1,
              'y': i / 300,
              'width': .5,
              'height': .001,
            },
        ];
      }
      if (call.method == 'translate') {
        final texts = List<String>.from((call.arguments as Map)['texts']);
        batches.add(texts);
        return texts.map((value) => '译$value').toList();
      }
      return null;
    });
    final tools = ComicImageTools();
    final output = await tools.translate(bytes);
    expect(batches.map((batch) => batch.length), [100, 100, 51]);
    expect(output, hasLength(251));
    expect(output.last.text, 'line-250');
    expect(output.last.translation, '译line-250');
    expect(output.last.y, closeTo(250 / 300, .00001));
    tools.dispose();
  });

  test('翻译分批同时限制文字长度，单区域超限有明确错误', () async {
    var oversized = false;
    final batches = <List<String>>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'recognize') {
        return [
          for (var i = 0; i < (oversized ? 1 : 2); i++)
            {
              'text': oversized ? '字' * 40001 : '${'字' * 24999}$i',
              'x': .1,
              'y': i * .2,
              'width': .5,
              'height': .1,
            },
        ];
      }
      if (call.method == 'translate') {
        final texts = List<String>.from((call.arguments as Map)['texts']);
        batches.add(texts);
        return texts.map((value) => '译文').toList();
      }
      return null;
    });
    final tools = ComicImageTools();
    expect(await tools.translate(bytes), hasLength(2));
    expect(batches.map((batch) => batch.length), [1, 1]);
    oversized = true;
    await expectLater(tools.translate(bytes), throwsFormatException);
    expect(batches, hasLength(2));
    tools.dispose();
  });

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
      await tester.scrollUntilVisible(
        find.byKey(const Key('advanced-image-models')),
        250,
      );
      await tester.ensureVisible(
        find.byKey(const Key('advanced-image-models')),
      );
      await tester.tap(find.byKey(const Key('advanced-image-models')));
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('import-super-resolution-model'));
      await tester.scrollUntilVisible(
        button,
        250,
        scrollable: find.byType(Scrollable).first,
      );
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
    await tester.scrollUntilVisible(
      find.byKey(const Key('advanced-image-models')),
      250,
    );
    await tester.ensureVisible(find.byKey(const Key('advanced-image-models')));
    await tester.tap(find.byKey(const Key('advanced-image-models')));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('import-super-resolution-model'));
    await tester.scrollUntilVisible(
      button,
      250,
      scrollable: find.byType(Scrollable).first,
    );
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
    await TextTranslationService.shared.clear();
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

  test('all eight waifu2x models are bundled with the app', () async {
    for (final name in ComicImageTools.bundledModelNames) {
      final data = await rootBundle.load('assets/models/waifu2x/$name.mlmodel');
      expect(
        data.lengthInBytes,
        greaterThan(1 * 1024 * 1024),
        reason: '$name 应随 App 打包',
      );
    }
  });

  test(
    'installBundledModels installs all eight models via native channel',
    () async {
      final installed = <String>[];
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'importModel') {
          installed.add((call.arguments as Map)['name'] as String);
        }
        return null;
      });
      final tools = ComicImageTools();
      await tools.installBundledModels();
      tools.dispose();
      expect(installed, <String>[
        'noise0.mlmodel',
        'noise1.mlmodel',
        'noise2.mlmodel',
        'noise3.mlmodel',
        'photo0.mlmodel',
        'photo1.mlmodel',
        'photo2.mlmodel',
        'photo3.mlmodel',
      ]);
    },
  );

  test('automatic upscale ranges are gated by the master switch', () {
    final settings = ComicImageToolsSettings();
    final tools = ComicImageTools(settings: settings);
    expect(tools.surfaceEnabled(UpscaleSurface.reader), isFalse);
    settings.automatic = true;
    expect(tools.surfaceEnabled(UpscaleSurface.reader), isTrue);
    expect(tools.surfaceEnabled(UpscaleSurface.cover), isFalse);
    expect(tools.surfaceEnabled(UpscaleSurface.videoPoster), isFalse);
    settings.upscaleCovers = true;
    settings.upscaleVideoPosters = true;
    expect(tools.surfaceEnabled(UpscaleSurface.cover), isTrue);
    expect(tools.surfaceEnabled(UpscaleSurface.videoPoster), isTrue);
    tools.dispose();
  });

  test(
    'new auto ranges and colorize config persist; concurrency clamps',
    () async {
      final dir = Directory.systemTemp.createTempSync('comic-image-settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async =>
            call.method == 'getApplicationSupportDirectory' ? dir.path : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        ),
      );
      final settings = ComicImageToolsSettings()
        ..automatic = true
        ..upscaleCovers = true
        ..upscaleVideoPosters = true
        ..concurrency = 9
        ..colorizeEndpoint = 'https://image.example/v1/images/edits'
        ..colorizeModel = 'image-model'
        ..colorizeProtocol = 'seedream'
        ..colorizePrompt = 'colorize'
        ..serverTranslation = true
        ..imageTranslationEndpoint = 'https://manga.example'
        ..serverOcr = 'mocr'
        ..serverTranslator = 'deepl';
      await settings.save();
      final reloaded = ComicImageToolsSettings();
      await reloaded.boot();
      expect(reloaded.automatic, isTrue);
      expect(reloaded.upscaleCovers, isTrue);
      expect(reloaded.upscaleVideoPosters, isTrue);
      expect(reloaded.concurrency, 4);
      expect(reloaded.colorizeProtocol, 'seedream');
      expect(
        reloaded.colorizeEndpoint,
        'https://image.example/v1/images/edits',
      );
      expect(reloaded.colorizeModel, 'image-model');
      expect(reloaded.colorizePrompt, 'colorize');
      expect(reloaded.serverTranslation, true);
      expect(reloaded.imageTranslationEndpoint, 'https://manga.example');
      expect(reloaded.serverOcr, 'mocr');
      expect(reloaded.serverTranslator, 'deepl');
    },
  );

  test('cloud colorize uploads multipart and accepts b64_json only', () async {
    final settings = ComicImageToolsSettings()
      ..colorizeEndpoint = 'https://image.example/v1/images/edits'
      ..colorizeModel = 'image-model';
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-secret');
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="model"'));
      expect(body, contains('image-model'));
      expect(body, contains('name="image"'));
      expect(body, contains('response_format'));
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);

    final bad = ComicImageTools(
      settings: settings,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'url': 'https://image.example/result.png'},
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(bad.dispose);
    await expectLater(bad.colorize(bytes), throwsFormatException);
  });

  test('Seedream 使用 JSON 原图上色，只生成一张图并读取 base64', () async {
    final settings = ComicImageToolsSettings()
      ..colorizeProtocol = 'seedream'
      ..colorizeEndpoint =
          'https://ark.cn-beijing.volces.com/api/v3/images/generations'
      ..colorizeModel = 'doubao-seedream-4-0-250828';
    final client = MockClient((request) async {
      expect(request.headers['Content-Type'], contains('application/json'));
      final body = jsonDecode(request.body) as Map;
      expect(body['model'], 'doubao-seedream-4-0-250828');
      expect(body['image'], 'data:image/png;base64,${base64Encode(bytes)}');
      expect(body['response_format'], 'b64_json');
      expect(body['sequential_image_generation'], 'disabled');
      expect(body['stream'], false);
      expect(body['size'], '2K');
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);
  });

  test('Seedream Flash 使用自己的密钥且不发送旧模型专有的组图参数', () async {
    final slots = <String>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      final slot = (call.arguments as Map)['slot'] as String;
      slots.add(slot);
      return slot == 'colorizeSeedream' ? 'ark-secret' : '';
    });
    final settings = ComicImageToolsSettings()
      ..colorizeProtocol = 'seedream'
      ..colorizeEndpoint =
          'https://ark.cn-beijing.volces.com/api/v3/images/generations'
      ..colorizeModel = 'doubao-seedream-5-0-flash-260915';
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer ark-secret');
      final body = jsonDecode(request.body) as Map;
      expect(body, isNot(contains('sequential_image_generation')));
      expect(body['image'], startsWith('data:image/png;base64,'));
      expect(body['output_format'], 'png');
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);
    expect(slots, ['colorizeSeedream']);
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

  test('上色独立密钥与 GPT Image 请求不会覆盖或读取翻译密钥', () async {
    final slots = <String>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      expect(call.method, 'getKey');
      slots.add((call.arguments as Map?)?['slot'] as String? ?? 'apiKey');
      return 'image-secret';
    });
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer image-secret');
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="image[]"'));
      expect(body, contains('name="output_format"'));
      expect(body, isNot(contains('response_format')));
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(
      settings: ComicImageToolsSettings()
        ..colorizeEndpoint = 'https://api.openai.com/v1/images/edits'
        ..colorizeModel = 'gpt-image-1-mini',
      client: client,
    );
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);
    expect(slots, ['colorize']);
  });

  test('上色兼容旧共用密钥，但错误的 DeepSeek/对话地址在上传前拦住', () async {
    var uploads = 0;
    final slots = <String>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      final slot = (call.arguments as Map?)?['slot'] as String? ?? 'apiKey';
      slots.add(slot);
      return slot == 'colorize' ? '' : 'legacy-secret';
    });
    final settings = ComicImageToolsSettings()
      ..colorizeEndpoint = 'https://image.example/v1/images/edits'
      ..colorizeModel = 'image-model';
    final client = MockClient((request) async {
      uploads++;
      expect(request.headers['Authorization'], 'Bearer legacy-secret');
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);
    expect(slots, ['colorize', 'apiKey']);
    slots.clear();
    for (final url in [
      'https://api.deepseek.com/v1',
      'https://image.example/v1/chat/completions',
    ]) {
      settings.colorizeEndpoint = url;
      await expectLater(tools.colorize(bytes), throwsFormatException);
    }
    expect(uploads, 1);
    expect(slots, isEmpty);
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

    // 按源隔离的子管线必须继承解码增强，否则自动超分在部分封面上会静默失效。
    final sub = pipeline.forSource(
      Section.comic,
      'source',
      NetworkProfile.none,
    );
    expect(sub.decodeTransform, isNotNull);
    sub.dispose();
  });

  test('自适应取色仅解码小图，不进入超分队列或污染展示缓存', () async {
    var enhanced = 0;
    final pipeline = SectionImagePipeline(
      cacheDir: '',
      diskCache: false,
      decodeTransform: (original) async {
        enhanced++;
        return original;
      },
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: bytes,
        headers: const {'content-type': 'image/png'},
      ),
    );
    addTearDown(pipeline.dispose);
    final sample = await pipeline.colorSample(
      'https://images.example/palette.png',
    );
    expect(sample, isNotNull);
    expect(sample!.width, lessThanOrEqualTo(64));
    expect(sample.height, lessThanOrEqualTo(64));
    expect(enhanced, 0);
    expect(pipeline.memoryCount, 0);
    sample.dispose();
    final display = await pipeline.image('https://images.example/palette.png');
    expect(display, isNotNull);
    expect(enhanced, 1);
    pipeline.release('https://images.example/palette.png');
  });

  test('封面与阅读器自动超分共用设备并发预算', () async {
    ComicImageTools.debugAutomaticSupported = true;
    addTearDown(() => ComicImageTools.debugAutomaticSupported = null);
    final firstStarted = Completer<void>(), finishFirst = Completer<void>();
    var calls = 0;
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (_) async {
      calls++;
      if (calls == 1) {
        firstStarted.complete();
        await finishFirst.future;
      }
      return bytes;
    });
    final settings = ComicImageToolsSettings()
      ..automatic = true
      ..upscaleCovers = true
      ..concurrency = 1;
    final reader = ComicImageTools(settings: settings),
        covers = ComicImageTools(settings: settings);
    addTearDown(reader.dispose);
    addTearDown(covers.dispose);
    final a = reader.automatic(bytes);
    await firstStarted.future;
    final b = covers.automatic(bytes, surface: UpscaleSurface.cover);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: '封面不能另开一个并发池抢占阅读器预算');
    finishFirst.complete();
    await Future.wait([a, b]);
    expect(calls, 2);
  });

  test('手动超分和自动封面共用预算，退出排队阅读器不会唤醒其他页面', () async {
    ComicImageTools.debugAutomaticSupported = true;
    addTearDown(() => ComicImageTools.debugAutomaticSupported = null);
    final started = Completer<void>(), finish = Completer<void>();
    var calls = 0;
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method != 'superResolve') return null;
      calls++;
      if (calls == 1) {
        started.complete();
        await finish.future;
      }
      return bytes;
    });
    final settings = ComicImageToolsSettings()
      ..automatic = true
      ..upscaleCovers = true
      ..concurrency = 1;
    final manual = ComicImageTools(settings: settings);
    final closingReader = ComicImageTools(settings: settings);
    final covers = ComicImageTools(settings: settings);
    addTearDown(manual.dispose);
    addTearDown(closingReader.dispose);
    addTearDown(covers.dispose);
    final a = manual.superResolve(bytes);
    await started.future;
    final b = closingReader.automatic(bytes);
    final c = covers.automatic(bytes, surface: UpscaleSurface.cover);
    await Future<void>.delayed(Duration.zero);
    closingReader.dispose();
    expect(await b, bytes);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: '取消自己不能把其他页面排队任务放行');
    finish.complete();
    await Future.wait([a, c]);
    expect(calls, 2);
  });

  test('降低并发设置后，排队任务等待所有超额任务完成', () async {
    final started = Completer<void>();
    final gates = [Completer<void>(), Completer<void>()];
    var calls = 0;
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method != 'superResolve') return null;
      final index = calls++;
      if (calls == 2) started.complete();
      if (index < gates.length) await gates[index].future;
      return bytes;
    });
    final settings = ComicImageToolsSettings()..concurrency = 2;
    final tools = ComicImageTools(settings: settings);
    addTearDown(tools.dispose);
    final a = tools.superResolve(bytes), b = tools.superResolve(bytes);
    await started.future;
    final c = tools.superResolve(bytes);
    settings.concurrency = 1;
    gates.first.complete();
    await a;
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    gates.last.complete();
    await Future.wait([b, c]);
    expect(calls, 3);
  });

  testWidgets('服务器翻译设置适配 320pt 与大字号，日文识别选项可见', (tester) async {
    final settings = ComicImageToolsSettings.instance;
    final previous = settings.serverTranslation,
        previousOcr = settings.serverOcr;
    settings.serverTranslation = true;
    settings.serverOcr = 'mocr';
    addTearDown(() {
      settings.serverTranslation = previous;
      settings.serverOcr = previousOcr;
    });
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const ComicImageToolsSettingsPage(translation: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('服务器识别模型'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('日文漫画（manga-ocr）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('apply-to-page returns enhanced bytes when allowApply', (
    tester,
  ) async {
    Uint8List? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              applied = await Navigator.of(context).push<Uint8List>(
                MaterialPageRoute<Uint8List>(
                  builder: (_) => ComicImageToolsPage(
                    allowApply: true,
                    loadOriginal: () async => bytes,
                  ),
                ),
              );
            },
            child: const Text('open tools'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open tools'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 超分当前图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用到当前页'));
    await tester.pumpAndSettle();
    expect(applied, bytes);
  });

  testWidgets('SR settings fit 320pt and expose the new sections', (
    tester,
  ) async {
    // 320pt 宽 + 拉高视口：一次建完整个设置页，直接检查排版与所有新区块。
    tester.view.physicalSize = const Size(320, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const ComicImageToolsSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in <String>[
      '自动超分的额外范围',
      '漫画 / 猫源封面',
      '视频海报',
      '内置模型 · 自动准备',
      'AI 上色（实验性 · 云端）',
      '保存上色配置',
    ]) {
      expect(find.text(text), findsOneWidget, reason: '缺少「$text」');
    }
    final promptLabel = find.text('上色提示词');
    final promptField = find.ancestor(
      of: promptLabel,
      matching: find.byType(TextField),
    );
    expect(promptField, findsOneWidget);
    expect(
      tester.getRect(promptLabel).top,
      greaterThanOrEqualTo(tester.getRect(promptField).top),
      reason: '浮动标签应位于输入框内部',
    );
    expect(tester.takeException(), isNull);
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
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
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
