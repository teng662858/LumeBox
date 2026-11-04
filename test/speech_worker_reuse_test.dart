import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_advanced.dart';
import 'package:lume_box/core/speech/speech_local.dart';
import 'package:lume_box/core/speech/speech_segments.dart';
import 'package:lume_box/core/speech/speech_settings.dart';

class FakeVoice extends SpeechLocalVoice {
  int closes = 0;
  int calls = 0;
  @override
  void close() {
    closes++;
  }

  @override
  Stream<Uint8List> synthesize(
    String text,
    String path,
    int voice,
    double speed, {
    bool kokoro = false,
  }) async* {
    calls++;
    yield Uint8List.fromList([0, 0]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'completed adjacent local segments reuse voice worker; stop releases it',
    () async {
      final voice = FakeVoice();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final finishes = StreamController<void>.broadcast();
      messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/speech'),
        (call) async {
          if (call.method == 'streamFinish') finishes.add(null);
          return null;
        },
      );
      final source = AdvancedSpeechSource(
        const MethodChannel('lumebox/speech'),
        localVoice: voice,
        localDirectory: (_) async => Directory('fake'),
      );
      const settings = SpeechSettings(mode: SpeechMode.local);
      try {
        var finished = finishes.stream.first;
        await source.speak(
          const SpeechSegment(text: '第一段', start: 0),
          settings,
        );
        await finished;
        await Future<void>.delayed(Duration.zero);
        final baseline = voice.closes;
        finished = finishes.stream.first;
        await source.speak(
          const SpeechSegment(text: '第二段', start: 3),
          settings,
        );
        await finished;
        await Future<void>.delayed(Duration.zero);
        expect(voice.calls, 2);
        expect(voice.closes, baseline);
        source.cancel();
        expect(voice.closes, baseline + 1);
      } finally {
        messenger.setMockMethodCallHandler(
          const MethodChannel('lumebox/speech'),
          null,
        );
        await finishes.close();
      }
    },
  );
}
