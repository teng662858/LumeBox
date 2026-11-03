import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class SpeechLocalModel extends ChangeNotifier {
  SpeechLocalModel({Future<XFile?> Function()? pickArchive})
    : _pickArchive = pickArchive ?? _selectArchive;

  final Future<XFile?> Function() _pickArchive;
  static Future<XFile?> _selectArchive() =>
      openFile(acceptedTypeGroups: const [archiveType]);
  static final instance = SpeechLocalModel();
  static const assets = 'assets/speech/vits_aishell3';
  bool ready = false, preparing = false;
  String? error;
  Directory? directory;
  Future<bool>? _checking;
  Future<Map<String, dynamic>> get _manifest async =>
      jsonDecode(await rootBundle.loadString('$assets/manifest.json'))
          as Map<String, dynamic>;
  Future<bool> check() {
    if (preparing) return Future.value(ready);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<bool> _check() async {
    final support = await getApplicationSupportDirectory();
    directory = Directory('${support.path}/speech/vits_aishell3');
    final manifest = await _manifest;
    final path = directory!.path;
    final valid = await Isolate.run(() => _valid(path, manifest));
    if (!preparing) ready = valid;
    notifyListeners();
    return ready;
  }

  static Future<bool> _valid(
    String directory,
    Map<String, dynamic> manifest,
  ) async {
    for (final item in manifest['files'] as List) {
      final file = File('$directory/${item['name']}');
      if (!await file.exists() ||
          await file.length() != item['bytes'] ||
          (await sha256.bind(file.openRead()).first).toString() !=
              item['sha256']) {
        return false;
      }
    }
    return true;
  }

  static const archiveType = XTypeGroup(
    label: '离线音色包',
    extensions: ['bz2'],
    mimeTypes: ['application/x-bzip2'],
    // iOS ignores extensions and requires UTIs. File providers can classify a
    // tar.bz2 as generic data; the archive hash still enforces the exact pack.
    uniformTypeIdentifiers: ['public.data'],
  );

  Future<bool> prepare({XFile? archiveFile, bool fromFile = false}) async {
    if (preparing) return false;
    preparing = true;
    error = null;
    notifyListeners();
    Directory? staging;
    var choosingFile = fromFile && archiveFile == null;
    try {
      final picked = archiveFile ?? (fromFile ? await _pickArchive() : null);
      choosingFile = false;
      if (fromFile && picked == null) return false;
      final support = await getApplicationSupportDirectory();
      directory = Directory('${support.path}/speech/vits_aishell3');
      final parent = Directory('${support.path}/speech');
      await parent.create(recursive: true);
      staging = await parent.createTemp('prepare-');
      final archive = File('${staging.path}/pack.tar.bz2');
      final manifest = await _manifest;
      Map<String, dynamic>? bundled;
      if (picked == null) {
        bundled = jsonDecode(
          await rootBundle.loadString('$assets/runtime/manifest.json'),
        ) as Map<String, dynamic>;
        if (bundled['sourceSha256'] != manifest['archiveSha256']) {
          throw const FormatException('内置音色版本不匹配');
        }
      }
      final expectedArchive =
          bundled?['archiveSha256'] ?? manifest['archiveSha256'];
      if (picked != null) {
        await picked.saveTo(archive.path);
      } else {
        // The shipped pack is split into bounded assets. Assemble it on demand
        // rather than opening a file picker or downloading it again.
        final sink = archive.openWrite();
        try {
          for (final part in bundled!['parts'] as List) {
            final ByteData bytes;
            try {
              bytes = await rootBundle.load('$assets/runtime/${part['name']}');
            } catch (_) {
              throw const FormatException('内置音色资源缺失，请选择从文件安装');
            }
            if (bytes.lengthInBytes != part['bytes']) {
              throw const FormatException('内置音色资源不完整，请选择从文件安装');
            }
            sink.add(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            );
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
      }
      final path = staging.path;
      await Isolate.run(() async {
        if ((await sha256.bind(File('$path/pack.tar.bz2').openRead()).first)
                .toString() !=
            expectedArchive) {
          throw const FormatException('模型压缩包校验失败');
        }
        final input = InputFileStream('$path/pack.tar.bz2');
        final output = OutputFileStream('$path/pack.tar');
        try {
          BZip2Decoder().decodeStream(input, output);
        } finally {
          input.close();
          output.close();
        }
        final tar = InputFileStream('$path/pack.tar');
        try {
          final archive = TarDecoder().decodeStream(tar);
          final wanted = {
            for (final file in manifest['files'] as List)
              file['name'] as String,
          };
          await Directory('$path/model').create();
          for (final entry in archive) {
            final name = entry.name.replaceAll('\\', '/').split('/').last;
            if (!wanted.contains(name) ||
                !entry.isFile ||
                entry.isSymbolicLink) {
              continue;
            }
            final target = OutputFileStream('$path/model/$name');
            try {
              entry.writeContent(target);
            } finally {
              target.close();
            }
          }
        } finally {
          tar.close();
        }
        if (!await _valid('$path/model', manifest)) {
          throw const FormatException('模型文件校验失败');
        }
      });
      // Only the owned model directory is replaced, after complete validation.
      if (await directory!.exists()) await directory!.delete(recursive: true);
      await Directory('${staging.path}/model').rename(directory!.path);
      ready = true;
      return true;
    } catch (failure) {
      error = choosingFile
          ? '无法打开文件选择器，请重试或启用内置音色包'
          : failure is FormatException
          ? '${failure.message}；请重试或选择官方完整音色包'
          : '音色包安装失败，请检查剩余空间后重试';
      return false;
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      preparing = false;
      notifyListeners();
    }
  }
}

/// Kokoro is installed separately from the bundled VITS voice.
class KokoroModel extends ChangeNotifier {
  static final instance = KokoroModel();
  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2';
  static const digest =
      '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c';
  bool ready = false, preparing = false;
  String? error;
  Directory? directory;

  Future<bool> check() async {
    final support = await getApplicationSupportDirectory();
    directory = Directory('${support.path}/speech/kokoro');
    ready =
        await File('${directory!.path}/.ready').exists() &&
        await File('${directory!.path}/model.int8.onnx').exists() &&
        await File('${directory!.path}/voices.bin').exists();
    notifyListeners();
    return ready;
  }

  Future<bool> install() async {
    if (preparing) return false;
    preparing = true;
    error = null;
    notifyListeners();
    Directory? stage;
    final client = HttpClient();
    try {
      final support = await getApplicationSupportDirectory();
      final parent = Directory('${support.path}/speech');
      await parent.create(recursive: true);
      stage = await parent.createTemp('kokoro-');
      final archive = File('${stage.path}/model.tar.bz2');
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) throw const FormatException('下载模型失败');
      final sink = archive.openWrite();
      var count = 0;
      try {
        await for (final bytes in response.timeout(
          const Duration(seconds: 45),
        )) {
          count += bytes.length;
          if (count > 200 * 1024 * 1024) throw const FormatException('模型文件过大');
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if ((await sha256.bind(archive.openRead()).first).toString() != digest) {
        throw const FormatException('模型校验失败');
      }
      final path = stage.path;
      await Isolate.run(() {
        final input = InputFileStream('$path/model.tar.bz2');
        final output = OutputFileStream('$path/model.tar');
        try {
          BZip2Decoder().decodeStream(input, output);
        } finally {
          input.closeSync();
          output.closeSync();
        }
        final tar = InputFileStream('$path/model.tar');
        try {
          final entries = TarDecoder().decodeStream(tar);
          const prefix = 'kokoro-int8-multi-lang-v1_1/';
          for (final entry in entries) {
            if (!entry.isFile ||
                entry.isSymbolicLink ||
                !entry.name.startsWith(prefix)) {
              continue;
            }
            final relative = entry.name.substring(prefix.length);
            if (relative.isEmpty ||
                relative.contains('..') ||
                relative.contains('\\') ||
                relative.startsWith('/')) {
              throw const FormatException('模型文件路径无效');
            }
            final file = File('$path/data/$relative');
            file.parent.createSync(recursive: true);
            final target = OutputFileStream(file.path);
            try {
              entry.writeContent(target);
            } finally {
              target.closeSync();
            }
          }
        } finally {
          tar.closeSync();
        }
        for (final name in [
          'model.int8.onnx',
          'voices.bin',
          'tokens.txt',
          'lexicon-us-en.txt',
          'lexicon-zh.txt',
        ]) {
          if (!File('$path/data/$name').existsSync()) {
            throw const FormatException('模型文件不完整');
          }
        }
      });
      final target = Directory('${parent.path}/kokoro');
      if (await target.exists()) await target.delete(recursive: true);
      directory = await Directory('${stage.path}/data').rename(target.path);
      await File('${target.path}/.ready').writeAsString(digest, flush: true);
      ready = true;
      return true;
    } catch (e) {
      error = e is FormatException ? e.message : '模型下载或安装失败，请检查网络与存储空间';
      return false;
    } finally {
      client.close(force: true);
      if (stage != null && await stage.exists()) {
        await stage.delete(recursive: true);
      }
      preparing = false;
      notifyListeners();
    }
  }
}

/// A cancellable per-playback worker. The native callback delivers generated
/// chunks without blocking Flutter's UI isolate. No network or LLM is involved.
class SpeechLocalVoice {
  Future<_LocalSpeechWorker>? _worker;
  void close() {
    final current = _worker;
    _worker = null;
    if (current != null) {
      unawaited(current.then((worker) => worker.close(), onError: (_) {}));
    }
  }

  Stream<Uint8List> synthesize(
    String text,
    String path,
    int voice,
    double speed, {
    bool kokoro = false,
  }) async* {
    final worker = await (_worker ??= _LocalSpeechWorker.create(
      path,
      kokoro: kokoro,
    ));
    if (worker.closed) return;
    worker.commands.send([text, voice, speed]);
    while (!worker.closed && await worker.messages.moveNext()) {
      final message = worker.messages.current;
      if (message == 'done') return;
      if (message == 'error') throw const FormatException('离线语音合成失败');
      if (message is TransferableTypedData) {
        yield message.materialize().asUint8List();
      }
    }
  }

  static void generate(List<Object> args) async {
    final send = args[0] as SendPort;
    final commands = ReceivePort();
    sherpa.OfflineTts? tts;
    try {
      sherpa.initBindings();
      final path = args[1] as String;
      final kokoro = args.length > 2 && args[2] == true;
      tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            numThreads: 2,
            debug: false,
            vits: kokoro
                ? const sherpa.OfflineTtsVitsModelConfig()
                : sherpa.OfflineTtsVitsModelConfig(
                    model: '$path/vits-aishell3.onnx',
                    lexicon: '$path/lexicon.txt',
                    tokens: '$path/tokens.txt',
                  ),
            kokoro: kokoro
                ? sherpa.OfflineTtsKokoroModelConfig(
                    model: '$path/model.int8.onnx',
                    voices: '$path/voices.bin',
                    tokens: '$path/tokens.txt',
                    dataDir: '$path/espeak-ng-data',
                    dictDir: '$path/dict',
                    lexicon: '$path/lexicon-us-en.txt,$path/lexicon-zh.txt',
                  )
                : const sherpa.OfflineTtsKokoroModelConfig(),
          ),
          ruleFsts: kokoro
              ? [
                  '$path/date-zh.fst',
                  '$path/number-zh.fst',
                  '$path/phone-zh.fst',
                ].join(',')
              : [
                  'date',
                  'number',
                  'new_heteronym',
                  'phone',
                ].map((n) => '$path/$n.fst').join(','),
          maxNumSenetences: 1,
        ),
      );
      if (tts.sampleRate != (kokoro ? 24000 : 8000) || tts.numSpeakers < 1) {
        throw const FormatException('模型音频格式无效');
      }
      send.send(commands.sendPort);
      await for (final request in commands) {
        if (request == 'close') break;
        final job = request as List;
        tts.generateWithCallback(
          text: job[0] as String,
          sid: (job[1] as int).clamp(0, tts.numSpeakers - 1),
          speed: job[2] as double,
          callback: (samples) {
            final bytes = ByteData(samples.length * 2);
            for (var i = 0; i < samples.length; i++) {
              bytes.setInt16(
                i * 2,
                (samples[i].clamp(-1, 1) * 32767).round(),
                Endian.little,
              );
            }
            send.send(
              TransferableTypedData.fromList([bytes.buffer.asUint8List()]),
            );
            return 1;
          },
        );
        send.send('done');
      }
    } catch (_) {
      send.send('error');
    } finally {
      tts?.free();
      commands.close();
    }
  }
}

class _LocalSpeechWorker {
  _LocalSpeechWorker(this.port, this.messages, this.commands);
  final ReceivePort port;
  final StreamIterator<dynamic> messages;
  final SendPort commands;
  bool closed = false;
  static Future<_LocalSpeechWorker> create(
    String path, {
    bool kokoro = false,
  }) async {
    final port = ReceivePort();
    final messages = StreamIterator(port);
    await Isolate.spawn(SpeechLocalVoice.generate, [
      port.sendPort,
      path,
      kokoro,
    ]);
    if (!await messages.moveNext() || messages.current is! SendPort) {
      port.close();
      await messages.cancel();
      throw const FormatException('无法加载离线语音模型');
    }
    return _LocalSpeechWorker(port, messages, messages.current as SendPort);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Never kill an isolate inside FFI: it must free the native ONNX model.
    // Stop audio immediately; let the bounded current sentence finish privately.
    commands.send('close');
    port.close();
    await messages.cancel();
  }
}
