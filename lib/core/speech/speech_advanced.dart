import '../media/playback_focus.dart';

import 'dart:async';

import 'package:flutter/services.dart';

import 'speech_cloud.dart';
import 'speech_settings.dart';
import 'speech_segments.dart';
import 'speech_turns.dart';
import 'speech_local.dart';

abstract interface class ChapterSpeechBackend {
  void prepareChapter(List<SpeechSegment> segments);
  Future<void> speakSegment(SpeechSegment segment);
}

/// Owns only sound production. Reader transport and saved reading progress keep
/// their existing SpeechSession contract.
class AdvancedSpeechSource {
  AdvancedSpeechSource(
    this.methods, {
    SpeechCloudConfig? config,
    SpeechCloudClient Function(SpeechCloudConfig)? clientFactory,
  }) : config = config ?? SpeechCloudConfig.instance,
       clientFactory = clientFactory ?? ((config) => SpeechCloudClient(config));
  final SpeechCloudConfig config;
  final SpeechCloudClient Function(SpeechCloudConfig) clientFactory;
  final MethodChannel methods;
  String _chapter = '';
  List<SpeechTurn>? _annotated;
  String? _annotationKey;
  int _generation = 0;
  SpeechCloudClient? _client;
  final _local = SpeechLocalVoice();
  void prepare(List<SpeechSegment> segments) {
    final buffer = StringBuffer();
    var position = 0;
    for (final segment in segments) {
      if (segment.start > position) {
        buffer.write(' ' * (segment.start - position));
      }
      buffer.write(segment.text);
      position = segment.end;
    }
    final chapter = buffer.toString();
    if (chapter != _chapter) {
      _chapter = chapter;
      _annotated = null;
      _annotationKey = null;
    }
  }

  void cancel() {
    _local.close();
    _generation++;
    _client?.close();
    _client = null;
  }

  Future<void> speak(SpeechSegment segment, SpeechSettings settings) async {
    await PlaybackFocus.acquire('tts');
    cancel();
    final generation = _generation;
    final token = '$generation-${DateTime.now().microsecondsSinceEpoch}';
    final client = _client = clientFactory(config);
    if (settings.mode == SpeechMode.local &&
        !await SpeechLocalModel.instance.check()) {
      throw const FormatException('离线模型缺失或损坏，请先准备模型');
    }
    if (settings.mode == SpeechMode.kokoro &&
        !await KokoroModel.instance.check()) {
      throw const FormatException('Kokoro 模型未安装');
    }
    if (generation != _generation) return;
    final sampleRate = settings.mode == SpeechMode.local ? 8000 : 24000;
    await methods.invokeMethod<void>('streamBegin', {
      'token': token,
      'sampleRate': sampleRate,
      'pitch': settings.pitch,
      'volume': settings.volume,
      'background': settings.backgroundPlayback,
    });
    // Start returns immediately so the existing transport remains responsive
    // while the provider is buffering or the LLM is preparing the chapter.
    unawaited(() async {
      try {
        var effective = settings;
        List<SpeechTurn> turns;
        if (settings.mode == SpeechMode.cloudAi && settings.autoDialogue) {
          await config.load();
          if (generation != _generation) return;
          final cacheKey =
              '${config.revision}\n${config.llmUrl}\n${config.llmModel}\n$_chapter';
          if (_annotationKey != cacheKey) {
            try {
              final result = await client
                  .annotate(_chapter.isEmpty ? segment.text : _chapter)
                  .timeout(const Duration(seconds: 15));
              if (generation != _generation) return;
              _annotated = result;
              _annotationKey = cacheKey;
            } catch (_) {
              if (generation != _generation) return;
              _annotated = null;
              _annotationKey = cacheKey;
            }
          }
          if (_annotated == null) {
            effective = settings.copyWith(mode: SpeechMode.cloud);
            turns = SpeechTurns.regex(segment.text, dialogue: true);
          } else {
            turns = SpeechTurns.slice(_annotated!, segment.start, segment.end);
          }
        } else {
          turns = SpeechTurns.regex(
            segment.text,
            dialogue: settings.autoDialogue,
          );
        }
        if (effective.mode != settings.mode) {
          // AI failed before any audio was queued: use the complete simple-mode
          // profile, including its native pitch/volume, without altering storage.
          await methods.invokeMethod<void>('streamBegin', {
            'token': token,
            'sampleRate': sampleRate,
            'pitch': effective.pitch,
            'volume': effective.volume,
            'background': effective.backgroundPlayback,
          });
        }
        for (final turn in turns) {
          if (generation != _generation) return;
          final voice = switch (turn.role) {
            SpeechRole.narrator => effective.narratorVoice,
            SpeechRole.male => effective.maleVoice,
            SpeechRole.female => effective.femaleVoice,
          };
          if (effective.mode == SpeechMode.system) {
            await methods.invokeMethod<void>('streamSystem', {
              'token': token,
              'text': turn.text,
              'offset': turn.start,
              'voice': voice,
              'role': turn.role.name,
              'rate': effective.rate,
              'pitch': effective.pitch,
              'volume': effective.volume,
            });
          } else if (effective.mode == SpeechMode.local ||
              effective.mode == SpeechMode.kokoro) {
            final kokoro = effective.mode == SpeechMode.kokoro;
            final directory = kokoro
                ? KokoroModel.instance.directory
                : SpeechLocalModel.instance.directory;
            if (directory == null) {
              throw const FormatException('离线模型尚未就绪');
            }
            await for (final bytes in _local.synthesize(
              turn.text,
              directory.path,
              int.tryParse(voice) ?? 0,
              effective.rate / .5,
              kokoro: kokoro,
            )) {
              for (var offset = 0; offset < bytes.length; offset += 8000) {
                if (generation != _generation) return;
                await methods.invokeMethod<void>('streamPCM', {
                  'token': token,
                  'bytes': Uint8List.sublistView(
                    bytes,
                    offset,
                    (offset + 8000).clamp(0, bytes.length),
                  ),
                });
              }
            }
          } else {
            var carry = <int>[];
            await for (final bytes in client.audio(
              turn.text,
              voice,
              effective.rate / .5,
            )) {
              if (generation != _generation) return;
              final joined = [...carry, ...bytes];
              final count = joined.length - joined.length % 2;
              carry = joined.sublist(count);
              for (var offset = 0; offset < count; offset += 24000) {
                final end = (offset + 24000).clamp(0, count);
                await methods.invokeMethod<void>('streamPCM', {
                  'token': token,
                  'bytes': Uint8List.fromList(joined.sublist(offset, end)),
                });
                if (generation != _generation) return;
              }
            }
            if (carry.isNotEmpty) throw const FormatException('PCM 数据不完整');
          }
          if (turn.pauseMs > 0) {
            await methods.invokeMethod<void>('streamPCM', {
              'token': token,
              'bytes': Uint8List(sampleRate * turn.pauseMs ~/ 1000 * 2),
            });
          }
          await methods.invokeMethod<void>('streamMark', {
            'token': token,
            'offset': turn.end,
          });
        }
        if (generation == _generation) {
          await methods.invokeMethod<void>('streamFinish', {'token': token});
        }
      } catch (_) {
        if (generation == _generation) {
          try {
            await methods.invokeMethod<void>('streamFail', {
              'token': token,
              'message': '听书服务不可用，请检查接口、模型和音色配置',
            });
          } catch (_) {
            /* The platform may already be tearing down. */
          }
        }
      } finally {
        client.close();
        if (identical(_client, client)) _client = null;
      }
    }());
  }
}
