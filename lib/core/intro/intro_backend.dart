import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'intro_models.dart';
import 'intro_signals.dart';

abstract interface class IntroScanBackend {
  Future<Map<String, Object?>> resources();
  Future<Map<String, Object?>> metadata(Uri uri, Map<String, String> headers);
  Future<IntroSample?> sample(
    Uri uri,
    Map<String, String> headers,
    int atMs,
    IntroOptions options,
    IntroCancellation token,
  );
  Future<IntroSample> infer(IntroSample sample, IntroOptions options);
  Future<void> cancel();
  Future<void> close();
}

class NativeIntroBackend implements IntroScanBackend {
  NativeIntroBackend({bool? platformSupported})
    : _platformSupported =
          platformSupported ?? (Platform.isIOS || Platform.isAndroid);
  final bool _platformSupported;
  static const channel = MethodChannel('lumebox/reference_intro');
  final String session = '${DateTime.now().microsecondsSinceEpoch}';
  bool _closed = false;
  bool _cancelled = false;
  bool _hasNativeSession = false;
  final Set<void Function()> _pending = {};

  Future<Map<String, Object?>?> _sessionCall(
    String method,
    Map<String, Object?> arguments,
    Duration timeout,
  ) async {
    if (_closed || _cancelled) throw const IntroCancelled();
    if (!_platformSupported) {
      throw MissingPluginException(
        'Native intro scanner requires iOS or Android',
      );
    }
    // A timed-out native request may still own a decoder and must be released.
    _hasNativeSession = true;
    try {
      return await _bounded(
        channel.invokeMapMethod<String, Object?>(method, arguments),
        timeout,
      );
    } on MissingPluginException {
      // Unsupported hosts never allocated native resources.
      _hasNativeSession = false;
      rethrow;
    }
  }

  Future<T> _bounded<T>(Future<T> work, Duration timeout) {
    final result = Completer<T>();
    late Timer timer;
    late void Function() stop;
    void finish(void Function() complete) {
      timer.cancel();
      _pending.remove(stop);
      if (!result.isCompleted) complete();
    }

    stop = () => finish(() => result.completeError(const IntroCancelled()));
    timer = Timer(
      timeout,
      () => finish(
        () => result.completeError(
          TimeoutException('Intro scanner timeout', timeout),
        ),
      ),
    );
    _pending.add(stop);
    work.then(
      (value) => finish(() => result.complete(value)),
      onError: (Object error, StackTrace stack) =>
          finish(() => result.completeError(error, stack)),
    );
    if (_closed || _cancelled) stop();
    return result.future;
  }

  Interpreter? _audio;
  IsolateInterpreter? _audioIsolate;
  Map<String, Object?>? _modelConfig;
  static Future<String>? _audioInstallation, _videoInstallation;
  static Future<String> installBundledModels({bool includeVideo = true}) =>
      includeVideo
      ? _videoInstallation ??= _installVideo()
      : _audioInstallation ??= _installAudio();
  static Future<String> _installAudio() async {
    try {
      final root = path.join(
        (await getApplicationSupportDirectory()).path,
        'reference_intro_models_3e0a7bfb',
      );
      final marker = File(path.join(root, 'audio.ready'));
      if (await marker.exists()) return root;
      await Directory(root).create(recursive: true);
      final audio = await rootBundle.load('assets/models/intro/yamnet.tflite');
      await File(path.join(root, 'yamnet.tflite')).writeAsBytes(
        audio.buffer.asUint8List(audio.offsetInBytes, audio.lengthInBytes),
        flush: true,
      );
      await marker.writeAsString('1', flush: true);
      return root;
    } catch (_) {
      _audioInstallation = null;
      rethrow;
    }
  }

  static Future<String> _installVideo() async {
    try {
      final root = await installBundledModels(includeVideo: false);
      if (!Platform.isIOS) return root;
      final marker = File(path.join(root, 'video.ready'));
      if (await marker.exists()) return root;
      final zipPath = path.join(root, 'models.zip');
      final bytes = await rootBundle.load(
        'assets/models/intro/mobileclip_s0.zip',
      );
      await File(zipPath).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      // Decode from a disk stream; never materialize uncompressed model weights
      // in a Dart archive alongside video textures. Audio-only never loads ZIP.
      await Isolate.run(() {
        final input = InputFileStream(zipPath);
        try {
          extractArchiveToDisk(ZipDecoder().decodeStream(input), root);
        } finally {
          input.closeSync();
        }
      });
      await File(zipPath).delete();
      await marker.writeAsString('1', flush: true);
      return root;
    } catch (_) {
      _videoInstallation = null;
      rethrow;
    }
  }

  Future<Map<String, Object?>> _config(IntroOptions options) async {
    if (_modelConfig != null) return _modelConfig!;
    final root =
        options.values['videoModelRoot'] as String? ??
        await installBundledModels();
    final prompts = jsonDecode(
      await rootBundle.loadString('assets/models/intro/prompts.json'),
    );
    return _modelConfig = {'root': root, 'prompts': prompts};
  }

  @override
  Future<Map<String, Object?>> resources() async {
    if (_closed || _cancelled) throw const IntroCancelled();
    if (!_platformSupported) {
      return const {'allowed': false, 'reason': 'Native scanner not available'};
    }
    final value = await channel.invokeMapMethod<String, Object?>('resources');
    return value ??
        const {'allowed': false, 'reason': 'Native scanner not available'};
  }

  @override
  Future<Map<String, Object?>> metadata(
    Uri uri,
    Map<String, String> headers,
  ) async =>
      await _sessionCall('metadata', {
        'url': uri.toString(),
        'headers': headers,
        'session': session,
      }, const Duration(seconds: 10)) ??
      {};
  @override
  Future<IntroSample?> sample(
    Uri uri,
    Map<String, String> headers,
    int atMs,
    IntroOptions options,
    IntroCancellation token,
  ) async {
    token.check();
    final value = await _sessionCall('sample', {
      'url': uri.toString(),
      'headers': headers,
      'atMs': atMs,
      'session': session,
      'ocr': options.enabled('ocr'),
      'audio':
          options.enabled('mfcc') ||
          options.enabled('joint') ||
          options.enabled('silence') ||
          options.enabled('audioAI'),
      'jpeg': options.enabled('videoAI'),
    }, const Duration(seconds: 8));
    token.check();
    if (value == null) return null;
    final audio = value['pcm'];
    // StandardMessageCodec byte arrays need not have a 4-byte-aligned offset.
    // Decode explicit little-endian PCM instead of constructing an unsafe view.
    final pcm = audio is Uint8List ? decodePcm(audio) : const <double>[];
    return IntroSample(
      atMs: (value['atMs'] as num?)?.toInt() ?? atMs,
      gray: value['gray'] as Uint8List? ?? Uint8List(0),
      pcm: pcm,
      text: '${value['text'] ?? ''}',
      textY: (value['textY'] as num?)?.toDouble(),
      jpeg: value['jpeg'] as Uint8List?,
      lines: (value['lines'] as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
      warnings: [
        if (value['ocrError'] == true) 'ocr-unavailable',
        if (value['audioError'] == true) 'audio-unavailable',
      ],
    );
  }

  static Float32List decodePcm(Uint8List audio) {
    final bytes = ByteData.sublistView(audio);
    return Float32List.fromList(
      List<double>.generate((audio.lengthInBytes ~/ 4).clamp(0, 15600), (i) {
        final sample = bytes.getFloat32(i * 4, Endian.little);
        return sample.isFinite ? sample.clamp(-1, 1) : 0;
      }),
    );
  }

  @override
  Future<IntroSample> infer(IntroSample sample, IntroOptions options) async {
    if (_closed || _cancelled) throw const IntroCancelled();
    final scores = <String, double>{};
    final warnings = [...sample.warnings];
    if (Platform.isIOS && options.enabled('videoAI') && sample.jpeg != null) {
      try {
        final config = await _config(options);
        if (_closed || _cancelled) throw const IntroCancelled();
        final result = await _sessionCall('classify', {
          ...config,
          'jpeg': sample.jpeg,
          'session': session,
        }, const Duration(seconds: 20));
        if (result != null) {
          for (final entry in result.entries) {
            if (entry.value is num) {
              scores[entry.key] = (entry.value as num).toDouble();
            }
          }
        }
      } on IntroCancelled {
        rethrow;
      } catch (_) {
        warnings.add('videoAI-unavailable');
      }
    }
    if (_closed || _cancelled) throw const IntroCancelled();
    if (options.enabled('audioAI') && sample.pcm.isNotEmpty) {
      try {
        if (_audio == null) {
          final root = await installBundledModels(includeVideo: false);
          final file = File(
            options.values['audioModelPath'] as String? ??
                path.join(root, 'yamnet.tflite'),
          );
          final interpreter = Interpreter.fromFile(
            file,
            options: InterpreterOptions()..threads = 1,
          );
          try {
            final shape = interpreter.getInputTensor(0).shape;
            if (shape.length != 1) {
              throw const FormatException(
                'YAMNet input must be mono PCM [samples]',
              );
            }
            interpreter.resizeInputTensor(0, [15600]);
            interpreter.allocateTensors();
            if (interpreter.getOutputTensor(0).shape.last != 521) {
              throw const FormatException(
                'YAMNet output must have 521 AudioSet classes',
              );
            }
            final worker = await IsolateInterpreter.create(
              address: interpreter.address,
            );
            _audio = interpreter;
            _audioIsolate = worker;
          } catch (_) {
            interpreter.close();
            rethrow;
          }
        }
        final input = List<double>.generate(
          15600,
          (i) => i < sample.pcm.length ? sample.pcm[i] : 0,
        );
        final outputs = <int, Object>{};
        final tensors = _audio!.getOutputTensors();
        for (var i = 0; i < tensors.length; i++) {
          final tensor = tensors[i];
          outputs[i] = List<double>.filled(
            tensor.numElements(),
            0,
          ).reshape(tensor.shape);
        }
        // Map keys are output ordinals, not the internal TensorFlow tensor IDs.
        final indexed = {
          for (var i = 0; i < outputs.length; i++)
            i: outputs.values.elementAt(i),
        };
        await _audioIsolate!.runForMultipleInputs([input], indexed);
        final row = (indexed[0] as List).first as List;
        scores['speech'] = (row[0] as num).toDouble();
        scores['music'] = (row[132] as num).toDouble();
      } catch (_) {
        warnings.add('audioAI-unavailable');
      }
    }
    return IntroSample(
      atMs: sample.atMs,
      gray: sample.gray,
      pcm: sample.pcm,
      text: sample.text,
      textY: sample.textY,
      ai: scores,
      jpeg: sample.jpeg,
      lines: sample.lines,
      warnings: warnings,
    );
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    for (final stop in _pending.toList()) {
      stop();
    }
    if (!_hasNativeSession) return;
    try {
      await channel.invokeMethod<void>('cancel', {'session': session});
    } catch (_) {
      /* no native work */
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await cancel();
    await _audioIsolate?.close();
    _audio?.close();
    _audio = null;
    if (!_hasNativeSession) return;
    try {
      await channel
          .invokeMethod<void>('release', {'session': session})
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {
      /* unsupported host */
    }
  }
}
