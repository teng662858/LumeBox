import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/speech/speech_cloud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final endpoints = <String, String>{};
  final secrets = <String, String>{};

  setUp(() {
    root = Directory.systemTemp.createTempSync('lumebox-speech-provider');
    endpoints.clear();
    secrets.clear();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('lumebox/speech'), (
      call,
    ) async {
      if (call.method != 'speechGetKey') return null;
      final kind = (call.arguments as Map)['kind'] as String? ?? '';
      final endpoint = endpoints[kind];
      if (endpoint == null) return jsonEncode({'endpoint': '', 'key': ''});
      return jsonEncode({'endpoint': endpoint, 'key': secrets[kind] ?? ''});
    });
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/speech'),
      null,
    );
  });

  test('MiMo streams base64 PCM from chat completions', () async {
    const endpoint = 'https://api.xiaomimimo.com/v1';
    endpoints['mimo'] = endpoint;
    secrets['mimo'] = 'secret';
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsProvider = SpeechTtsProvider.mimo;
    final client = SpeechCloudClient(
      config,
      client: MockClient((request) async {
        expect(request.url.toString(), '$endpoint/chat/completions');
        expect(request.headers['Authorization'], 'Bearer secret');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'mimo-v2.5-tts');
        expect(body['audio']['voice'], '白桦');
        expect(body['audio']['format'], 'pcm16');
        expect(body['messages'].last['content'], '你好');
        return http.Response(
          'data: {"choices":[{"delta":{"audio":{"data":"AQIDBA=="}}}]}\n\ndata: [DONE]\n\n',
          200,
        );
      }),
    );
    expect(await client.audio('你好', '白桦', 1).expand((part) => part).toList(), [
      1,
      2,
      3,
      4,
    ]);
    client.close();
  });

  test(
    'MiMo reports authentication, quota, rate and service errors safely',
    () async {
      const endpoint = 'https://api.xiaomimimo.com/v1';
      endpoints['mimo'] = endpoint;
      secrets['mimo'] = 'secret';
      final config = SpeechCloudConfig();
      await config.load();
      config.ttsProvider = SpeechTtsProvider.mimo;
      for (final item in {
        401: '密钥无效',
        402: '余额或额度',
        403: '账号权限',
        429: '过于频繁',
        503: '暂时不可用',
      }.entries) {
        final client = SpeechCloudClient(
          config,
          client: MockClient((_) async => http.Response('secret', item.key)),
        );
        await expectLater(
          client.audio('你好', '冰糖', 1).toList(),
          throwsA(
            isA<SpeechProviderException>().having(
              (e) => e.message,
              'message',
              allOf(contains(item.value), isNot(contains('secret'))),
            ),
          ),
        );
        client.close();
      }
    },
  );

  test('Azure Speech requests raw 24k PCM with escaped SSML', () async {
    endpoints['azure'] = 'eastasia';
    secrets['azure'] = 'azure-key';
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsProvider = SpeechTtsProvider.azure;
    config.azureRegion = 'eastasia';

    final client = SpeechCloudClient(
      config,
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
        );
        expect(request.headers['Ocp-Apim-Subscription-Key'], 'azure-key');
        expect(
          request.headers['X-Microsoft-OutputFormat'],
          'raw-24khz-16bit-mono-pcm',
        );
        expect(
          request.headers['Content-Type'],
          startsWith('application/ssml+xml'),
        );
        expect(request.body, contains('xml:lang="zh-CN"'));
        expect(request.body, contains('<voice name="zh-CN-XiaoxiaoNeural">'));
        expect(request.body, contains('你好&amp;世界'));
        expect(request.body, contains('rate="+0%"'));
        return http.Response.bytes([0, 0, 2, 0], 200);
      }),
    );
    expect(await client.audio('你好&世界', 'alloy', 1).expand((b) => b).toList(), [
      0,
      0,
      2,
      0,
    ]);
    client.close();
  });

  test('Azure SSML maps Chinese voices and clamps prosody rate', () {
    final slow = SpeechCloudClient.azureSsml('文本', 'zh-CN-YunxiNeural', .2);
    expect(slow, contains('<voice name="zh-CN-YunxiNeural">'));
    expect(slow, contains('rate="-50%"'));
    final fast = SpeechCloudClient.azureSsml('文本', 'nova', 4);
    expect(fast, contains('<voice name="zh-CN-XiaoyiNeural">'));
    expect(fast, contains('rate="+100%"'));
  });

  test('Volcengine sends PCM request and decodes base64 audio', () async {
    endpoints['volc'] = 'app-123';
    secrets['volc'] = 'volc-token';
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsProvider = SpeechTtsProvider.volcengine;
    config.volcAppId = 'app-123';
    config.volcCluster = 'volcano_tts';

    final client = SpeechCloudClient(
      config,
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://openspeech.bytedance.com/api/v1/tts',
        );
        expect(request.headers['Authorization'], 'Bearer;volc-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['app']['appid'], 'app-123');
        expect(body['app']['cluster'], 'volcano_tts');
        expect(body['audio']['voice_type'], 'BV700_streaming');
        expect(body['audio']['encoding'], 'pcm');
        expect(body['audio']['sample_rate'], 24000);
        expect(body['audio']['speed_ratio'], 1.0);
        expect(body['request']['text'], '你好');
        expect(body['request']['operation'], 'query');
        return http.Response(
          jsonEncode({
            'code': 3000,
            'message': 'Success',
            'data': base64Encode([1, 2, 3, 4]),
          }),
          200,
        );
      }),
    );
    expect(await client.audio('你好', 'alloy', 1).expand((b) => b).toList(), [
      1,
      2,
      3,
      4,
    ]);
    client.close();
  });

  test('Volcengine maps male voice and surfaces provider errors', () async {
    endpoints['volc'] = 'app-123';
    secrets['volc'] = 'volc-token';
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsProvider = SpeechTtsProvider.volcengine;
    config.volcAppId = 'app-123';

    var calls = 0;
    final client = SpeechCloudClient(
      config,
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['audio']['voice_type'], 'BV705_streaming');
        return http.Response(
          jsonEncode({'code': 3001, 'message': 'quota exceeded', 'data': ''}),
          200,
        );
      }),
    );
    await expectLater(
      client.audio('你好', 'onyx', 1).toList(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('quota exceeded'),
        ),
      ),
    );
    expect(calls, 1);
    client.close();
  });

  test('provider key is bound to its own endpoint', () async {
    endpoints['azure'] = 'eastasia';
    secrets['azure'] = 'azure-key';
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsProvider = SpeechTtsProvider.azure;
    config.azureRegion = 'japaneast';

    var requests = 0;
    final client = SpeechCloudClient(
      config,
      client: MockClient((_) async {
        requests++;
        return http.Response.bytes([0, 0], 200);
      }),
    );
    await expectLater(
      client.audio('你好', 'alloy', 1).toList(),
      throwsFormatException,
    );
    expect(requests, 0);
    client.close();
  });
}
