import '../media/playback_focus.dart';

import 'dart:async';
import 'dart:io';

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

/// Prime one chunk of the next turn. The iterator pauses the source until the
/// turn is consumed, so lookahead cannot accumulate an entire audio response.
class _SpeechAudioLookahead {
  _SpeechAudioLookahead(Stream<List<int>> source)
    : _iterator = StreamIterator(source) {
    _first = _iterator
        .moveNext()
        .then<({bool ready, Object? error, StackTrace? stack})>(
          (ready) => (ready: ready, error: null, stack: null),
          onError: (Object error, StackTrace stack) =>
              (ready: false, error: error, stack: stack),
        );
  }

  final StreamIterator<List<int>> _iterator;
  late final Future<({bool ready, Object? error, StackTrace? stack})> _first;

  Stream<List<int>> read() async* {
    final first = await _first;
    if (first.error != null) {
      Error.throwWithStackTrace(first.error!, first.stack!);
    }
    if (!first.ready) return;
    do {
      yield _iterator.current;
    } while (await _iterator.moveNext());
  }

  Future<void> cancel() => _iterator.cancel();
  Future<bool> get failedBeforeAudio async => (await _first).error != null;
}

/// Owns only sound production. Reader transport and saved reading progress keep
/// their existing SpeechSession contract.
class AdvancedSpeechSource {
  AdvancedSpeechSource(
    this.methods, {
    SpeechCloudConfig? config,
    SpeechCloudClient Function(SpeechCloudConfig)? clientFactory,
    SpeechLocalVoice? localVoice,
    Future<Directory?> Function(SpeechMode)? localDirectory,
  }) : config = config ?? SpeechCloudConfig.instance,
       clientFactory = clientFactory ?? ((config) => SpeechCloudClient(config)),
       _local = localVoice ?? SpeechLocalVoice(),
       _localDirectory = localDirectory ?? _defaultLocalDirectory;
  final SpeechCloudConfig config;
  final SpeechCloudClient Function(SpeechCloudConfig) clientFactory;
  final MethodChannel methods;
  String _chapter = '';
  List<SpeechTurn>? _annotated;
  List<SpeechTurn>? _heuristicTurns;
  String? _annotationKey;
  int _generation = 0;
  SpeechCloudClient? _client;
  final SpeechLocalVoice _local;
  final Future<Directory?> Function(SpeechMode) _localDirectory;
  static Future<Directory?> _defaultLocalDirectory(SpeechMode mode) async {
    if (mode == SpeechMode.local) {
      return await SpeechLocalModel.instance.check()
          ? SpeechLocalModel.instance.directory
          : null;
    }
    return await KokoroModel.instance.check()
        ? KokoroModel.instance.directory
        : null;
  }

  bool _localFinished = false;
  void prepare(List<SpeechSegment> segments) {
    final buffer = StringBuffer();
    var position = 0;
    for (final segment in segments) {
      if (segment.start > position) {
        buffer.write('\n');
        buffer.write(' ' * (segment.start - position - 1));
      }
      buffer.write(segment.text);
      position = segment.end;
    }
    final chapter = buffer.toString();
    if (chapter != _chapter) {
      _chapter = chapter;
      _annotated = null;
      _heuristicTurns = null;
      _annotationKey = null;
    }
  }

  void cancel({bool keepCompletedLocal = false}) {
    if (!keepCompletedLocal || !_localFinished) _local.close();
    _localFinished = false;
    _generation++;
    _client?.close();
    _client = null;
  }

  Future<void> speak(
    SpeechSegment segment,
    SpeechSettings settings, {
    String focusOwner = 'tts',
    void Function(String)? onError,
  }) async {
    cancel(
      keepCompletedLocal:
          settings.mode == SpeechMode.local ||
          settings.mode == SpeechMode.kokoro,
    );
    final generation = _generation;
    await PlaybackFocus.acquire(
      focusOwner,
      stillWanted: () => generation == _generation,
    );
    if (generation != _generation) return;
    final token = '$generation-${DateTime.now().microsecondsSinceEpoch}';
    final client = _client = clientFactory(config);
    Directory? localDirectory;
    if (settings.mode == SpeechMode.local ||
        settings.mode == SpeechMode.kokoro) {
      localDirectory = await _localDirectory(settings.mode);
      if (localDirectory == null) {
        throw FormatException(
          settings.mode == SpeechMode.kokoro
              ? 'Kokoro 模型未安装'
              : '离线模型缺失或损坏，请先准备模型',
        );
      }
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
      _SpeechAudioLookahead? nextAudio;
      try {
        var effective = settings;
        List<SpeechTurn> heuristic() => _chapter.isEmpty
            ? SpeechTurns.regex(segment.text, dialogue: true)
            : SpeechTurns.slice(
                _heuristicTurns ??= SpeechTurns.regex(_chapter, dialogue: true),
                segment.start,
                segment.end,
              );
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
            turns = heuristic();
          } else {
            turns = SpeechTurns.slice(_annotated!, segment.start, segment.end);
          }
        } else {
          turns = settings.autoDialogue
              ? heuristic()
              : SpeechTurns.regex(segment.text, dialogue: false);
        }
        turns = turns.where((turn) => turn.text.trim().isNotEmpty).toList();
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
        String voiceFor(SpeechTurn turn) => switch (turn.role) {
          SpeechRole.narrator => effective.narratorVoice,
          SpeechRole.male => effective.maleVoice,
          SpeechRole.female => effective.femaleVoice,
        };
        _SpeechAudioLookahead prime(SpeechTurn turn) => _SpeechAudioLookahead(
          client.audio(turn.text, voiceFor(turn), effective.rate / .5),
        );
        for (var index = 0; index < turns.length; index++) {
          if (generation != _generation) return;
          final turn = turns[index];
          final voice = voiceFor(turn);
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
            final directory = localDirectory;
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
            final prefetched = nextAudio;
            nextAudio = null;
            var audio = prefetched ?? prime(turn);
            if (prefetched != null && await prefetched.failedBeforeAudio) {
              await prefetched.cancel();
              if (generation != _generation) return;
              // Some services reject overlapping requests. Retry the turn
              // once in sequence if its speculative request produced no audio.
              audio = prime(turn);
            }
            try {
              var carry = <int>[];
              await for (final bytes in audio.read()) {
                if (generation != _generation) return;
                if (bytes.isNotEmpty && index + 1 < turns.length) {
                  nextAudio ??= prime(turns[index + 1]);
                }
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
            } finally {
              await audio.cancel();
            }
          }
          if (turn.pauseMs > 0) {
            await methods.invokeMethod<void>('streamPCM', {
              'token': token,
              'bytes': Uint8List(sampleRate * turn.pauseMs ~/ 1000 * 2),
            });
          }
          if (effective.mode != SpeechMode.system) {
            await methods.invokeMethod<void>('streamMark', {
              'token': token,
              'offset': turn.end,
            });
          }
        }
        if (generation == _generation) {
          await methods.invokeMethod<void>('streamFinish', {'token': token});
          if (generation == _generation &&
              (effective.mode == SpeechMode.local ||
                  effective.mode == SpeechMode.kokoro)) {
            _localFinished = true;
          }
        }
      } catch (error) {
        if (generation == _generation) {
          final message = error is SpeechProviderException
              ? error.message
              : error is TimeoutException
              ? '语音服务连接超时，请检查网络后重试'
              : error is SocketException
              ? '无法连接语音服务，请检查网络'
              : '听书服务不可用，请检查接口、模型和音色配置';
          onError?.call(message);
          try {
            await methods.invokeMethod<void>('streamFail', {
              'token': token,
              'message': message,
            });
          } catch (_) {
            /* The platform may already be tearing down. */
          }
        }
      } finally {
        client.close();
        await nextAudio?.cancel();
        if (identical(_client, client)) _client = null;
      }
    }());
  }
}
