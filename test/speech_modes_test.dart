import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/speech/speech_settings.dart';
import 'package:lume_box/core/speech/speech_turns.dart';
import 'package:lume_box/core/speech/speech_cloud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('four modes preserve independent profiles and legacy configuration', () {
    var settings = SpeechSettings.decode('{"rate":0.7,"pitch":1.2}');
    expect(settings.mode, SpeechMode.system);
    settings = settings
        .copyWith(mode: SpeechMode.cloud)
        .copyWith(
          rate: .9,
          pitch: .8,
          volume: .3,
          narratorVoice: 'custom',
          autoDialogue: true,
        );
    settings = settings.copyWith(mode: SpeechMode.local).copyWith(rate: .4);
    settings = SpeechSettings.decode(settings.encode());
    expect(settings.copyWith(mode: SpeechMode.system).rate, .7);
    final online = settings.copyWith(mode: SpeechMode.cloud);
    expect(online.rate, .9);
    expect(online.pitch, .8);
    expect(online.volume, .3);
    expect(online.narratorVoice, 'custom');
    expect(online.autoDialogue, true);
    expect(online.copyWith(mode: SpeechMode.local).rate, .4);
    expect(online.copyWith(mode: SpeechMode.cloudAi).rate, .5);
  });
  test('corrupt voice profiles cannot throw on mode switching', () {
    final settings = SpeechSettings.decode(
      '{"profiles":{"cloud":{"narratorVoice":4,"rate":"bad"}}}',
    );
    expect(settings.copyWith(mode: SpeechMode.cloud).rate, .5);
    expect(settings.copyWith(mode: SpeechMode.cloud).narratorVoice, 'alloy');
  });
  test(
    'regex never alters source text positions and respects master switch',
    () {
      const text = '旁白：夜深了。\n妹妹：你好！\n哥哥：你好。\n妹妹：再见。😀';
      final turns = SpeechTurns.regex(text, dialogue: true);
      expect(turns.map((t) => t.role), [
        SpeechRole.narrator,
        SpeechRole.female,
        SpeechRole.male,
        SpeechRole.female,
      ]);
      for (final turn in turns) {
        expect(text.substring(turn.start, turn.end), turn.text);
      }
      expect(
        SpeechTurns.regex(
          text,
          dialogue: false,
        ).every((t) => t.role == SpeechRole.narrator),
        true,
      );
      expect(SpeechTurns.regex(text, dialogue: false).single.text, text);
    },
  );
  test('SSML validates entire original text, maps offsets and pauses', () {
    const text = '夜深了。\n你好，😀！';
    final turns = SpeechTurns.ssml(
      '<speak><voice name="narrator">夜深了。</voice>'
      '<break time="0.5s"/><voice name="female">你好，😀！</voice></speak>',
      text,
    );
    expect(turns.first.pauseMs, 500);
    expect(turns.last.role, SpeechRole.female);
    expect(turns.last.start, 5);
    expect(SpeechTurns.slice(turns, 6, text.length).first.start, 0);
    for (final bad in [
      '<speak>摘要</speak>',
      '<speak>夜深了。</speak>',
      '<speak><voice name="unknown">$text</voice></speak>',
      '<!DOCTYPE speak><speak>$text</speak>',
    ]) {
      expect(() => SpeechTurns.ssml(bad, text), throwsFormatException);
    }
  });
  test(
    'cloud endpoint supports base/full URL and rejects credential redirects',
    () {
      expect(
        SpeechCloudConfig.endpoint(
          'https://example.com/v1',
          '/audio/speech',
        ).toString(),
        'https://example.com/v1/audio/speech',
      );
      expect(
        SpeechCloudConfig.endpoint(
          'https://example.com/api/v1/audio/speech',
          '/audio/speech',
        ).path,
        '/api/v1/audio/speech',
      );
      expect(
        () => SpeechCloudConfig.endpoint('http://example.com', '/audio/speech'),
        throwsFormatException,
      );
      expect(
        () => SpeechCloudConfig.endpoint(
          'https://secret@example.com',
          '/audio/speech',
        ),
        throwsFormatException,
      );
    },
  );
  test('simple TTS sends plain text PCM request, no LLM request', () async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => null);
    // load() requires a real support directory; use a unique non-existent file
    // under the test runner's temporary directory, without any account secrets.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          paths,
          (_) async => '.cache/speech-unit-config',
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          (_) async => jsonEncode({
            'endpoint': 'https://example.com/v1',
            'key': 'test-only-key',
          }),
        );
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsUrl = 'https://example.com/v1';
    config.ttsModel = 'user-model';
    var calls = 0;
    final client = SpeechCloudClient(
      config,
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/v1/audio/speech');
        expect(request.followRedirects, false);
        final body = jsonDecode(request.body);
        expect(body['response_format'], 'pcm');
        expect(body['model'], 'user-model');
        expect(body['input'], '你好');
        expect(body.containsKey('messages'), false);
        return http.Response.bytes([0, 0, 1, 0], 200);
      }),
    );
    expect(await client.audio('你好', 'custom', 1).expand((b) => b).toList(), [
      0,
      0,
      1,
      0,
    ]);
    expect(calls, 1);
    client.close();
  });
  test('a provider change cannot send another provider key', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => '.cache/speech-unit-config',
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          (_) async => jsonEncode({
            'endpoint': 'https://old.example/v1',
            'key': 'do-not-send',
          }),
        );
    final config = SpeechCloudConfig();
    await config.load();
    config.ttsUrl = 'https://new.example/v1';
    config.ttsModel = 'user-model';
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
