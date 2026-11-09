import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/speech/speech_advanced.dart';
import 'package:lume_box/core/speech/speech_cloud.dart';
import 'package:lume_box/core/speech/speech_settings.dart';
import 'package:lume_box/core/speech/speech_segments.dart';

class _ControlledAudio extends SpeechCloudClient {
  _ControlledAudio(super.config);
  final started = <String>[];
  final nextStarted = Completer<void>();
  @override
  Stream<List<int>> audio(String text, String voice, double speed) async* {
    started.add(text);
    if (started.length == 2) nextStarted.complete();
    yield [started.length, 0];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('系统分角色朗读在跨片段后沿用同一角色，并由原生回报进度', () async {
    const methods = MethodChannel('lumebox/speech');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final source = AdvancedSpeechSource(methods);
    final finished = Completer<void>();
    final roles = <String>[];
    var pcmMarks = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'streamSystem') {
        roles.add((call.arguments as Map)['role'] as String);
      }
      if (call.method == 'streamMark') pcmMarks++;
      if (call.method == 'streamFinish') finished.complete();
      return null;
    });
    addTearDown(() {
      source.cancel();
      messenger.setMockMethodCallHandler(methods, null);
    });
    const third = SpeechSegment(text: '乙：又见面了。', start: 12);
    source.prepare(const [
      SpeechSegment(text: '甲：你好。', start: 0),
      SpeechSegment(text: '乙：你好。', start: 6),
      third,
    ]);
    await source.speak(third, const SpeechSettings(autoDialogue: true));
    await finished.future.timeout(const Duration(seconds: 2));
    expect(roles, ['female']);
    expect(pcmMarks, 0);
  });
  test('在线下一角色在当前 PCM 等待期间预取，播放仍按原顺序', () async {
    const methods = MethodChannel('lumebox/speech');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final audio = _ControlledAudio(SpeechCloudConfig());
    final source = AdvancedSpeechSource(methods, clientFactory: (_) => audio);
    final firstPcm = Completer<void>();
    final finished = Completer<void>();
    final received = <int>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'streamPCM') {
        received.add(((call.arguments as Map)['bytes'] as Uint8List).first);
        if (received.length == 1) await firstPcm.future;
      }
      if (call.method == 'streamFinish') finished.complete();
      return null;
    });
    addTearDown(() {
      if (!firstPcm.isCompleted) firstPcm.complete();
      source.cancel();
      messenger.setMockMethodCallHandler(methods, null);
    });
    await source.speak(
      const SpeechSegment(text: '旁白：第一段。\n妹妹：第二段。', start: 0),
      const SpeechSettings(mode: SpeechMode.cloud, autoDialogue: true),
    );
    await audio.nextStarted.future.timeout(const Duration(seconds: 2));
    expect(received, [1]);
    firstPcm.complete();
    await finished.future.timeout(const Duration(seconds: 2));
    expect(received, [1, 2]);
  });
  for (final failure in ['network', 'invalid SSML', 'rewritten text']) {
    test(
      'AI $failure automatically falls back to plain TTS without failed event',
      () async {
        final config = SpeechCloudConfig();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => '.cache/speech-unit-config',
            );
        final finished = Completer<void>();
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('lumebox/speech'), (
              call,
            ) async {
              methods.add(call.method);
              if (call.method == 'speechGetKey') {
                return jsonEncode({
                  'endpoint': (call.arguments as Map)['kind'] == 'llm'
                      ? 'https://llm.example/v1'
                      : 'https://tts.example/v1',
                  'key': 'unit-only',
                });
              }
              if (call.method == 'streamFinish') finished.complete();
              return null;
            });
        await config.load();
        config.ttsUrl = 'https://tts.example/v1';
        config.ttsModel = 'user-tts';
        config.llmUrl = 'https://llm.example/v1';
        config.llmModel = 'user-llm';
        var llmCalls = 0, ttsCalls = 0;
        final source = AdvancedSpeechSource(
          const MethodChannel('lumebox/speech'),
          config: config,
          clientFactory: (config) => SpeechCloudClient(
            config,
            client: MockClient((request) async {
              if (request.url.host == 'llm.example') {
                llmCalls++;
                expect(
                  jsonDecode(request.body)['messages'][1]['content'],
                  '妹妹：你好！\n旁白：结束。',
                );
                if (failure == 'network') throw http.ClientException('offline');
                return http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {
                          'content': failure == 'invalid SSML'
                              ? 'bad'
                              : '<speak>总结</speak>',
                        },
                      },
                    ],
                  }),
                  200,
                );
              }
              ttsCalls++;
              expect(
                jsonDecode(request.body)['input'],
                isNot(contains('<speak>')),
              );
              return http.Response.bytes([0, 0, 1, 0], 200);
            }),
          ),
        );
        const chapter = '妹妹：你好！\n旁白：结束。';
        source.prepare([const SpeechSegment(text: chapter, start: 0)]);
        await source.speak(
          const SpeechSegment(text: chapter, start: 0),
          const SpeechSettings(mode: SpeechMode.cloudAi, autoDialogue: true),
        );
        await finished.future.timeout(const Duration(seconds: 2));
        expect(llmCalls, 1);
        expect(ttsCalls, 2);
        expect(methods, contains('streamPCM'));
        expect(methods, contains('streamMark'));
        expect(methods, isNot(contains('streamFail')));
        source.cancel();
      },
    );
  }
}
