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
  SpeechLocalModel({Future<XFile?> Function()? pickArchive, Uri? downloadUri})
    : _pickArchive = pickArchive ?? _selectArchive,
      _downloadUri = downloadUri ?? Uri.parse(url);

  final Future<XFile?> Function() _pickArchive;
  final Uri _downloadUri;
  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-aishell3.tar.bz2';
  static const archiveBytes = 146922607;
  HttpClient? _client;
  bool _cancelled = false;
  bool present = false;
  String phase = '';
  double? progress;

  void cancel() {
    if (!preparing) return;
    _cancelled = true;
    phase = '正在取消';
    _client?.close(force: true);
    notifyListeners();
  }

  Future<void> remove() async {
    if (preparing) return;
    final support = await getApplicationSupportDirectory();
    directory = Directory('${support.path}/speech/vits_aishell3');
    if (await directory!.exists()) await directory!.delete(recursive: true);
    ready = false;
    present = false;
    error = null;
    notifyListeners();
  }

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
    present = await directory!.exists();
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
    _cancelled = false;
    phase = fromFile || archiveFile != null ? '正在选择文件' : '正在连接';
    progress = null;
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
      if (picked != null) {
        phase = '正在读取文件';
        notifyListeners();
        await picked.saveTo(archive.path);
      } else {
        final client = _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20);
        final request = await client.getUrl(_downloadUri);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (_cancelled) throw const FormatException('已取消');
        if (response.statusCode != 200) throw const FormatException('下载模型失败');
        phase = '正在下载';
        notifyListeners();
        final sink = archive.openWrite();
        var count = 0;
        try {
          await for (final bytes in response.timeout(
            const Duration(seconds: 45),
          )) {
            if (_cancelled) throw const FormatException('已取消');
            count += bytes.length;
            if (count > archiveBytes) throw const FormatException('模型文件过大');
            final next = (count / archiveBytes).clamp(0.0, 1.0);
            if (progress == null || next - progress! >= .01) {
              progress = next;
              notifyListeners();
            }
            sink.add(bytes);
          }
        } finally {
          await sink.close();
        }
      }
      if (_cancelled) throw const FormatException('已取消');
      phase = '正在校验并解压';
      progress = null;
      notifyListeners();
      final expectedArchive = manifest['archiveSha256'];
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
      if (_cancelled) throw const FormatException('已取消');
      // Only the owned model directory is replaced, after complete validation.
      if (await directory!.exists()) await directory!.delete(recursive: true);
      await Directory('${staging.path}/model').rename(directory!.path);
      ready = true;
      present = true;
      return true;
    } catch (failure) {
      error = _cancelled
          ? '已取消'
          : choosingFile
          ? '无法打开文件选择器，请重试'
          : failure is FormatException
          ? '${failure.message}；请重试或选择官方完整音色包'
          : '音色包安装失败，请检查剩余空间后重试';
      return false;
    } finally {
      _client?.close(force: true);
      _client = null;
      phase = '';
      progress = null;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      preparing = false;
      notifyListeners();
    }
  }
}

/// Kokoro is installed separately from the VITS voice.
class KokoroModel extends ChangeNotifier {
  KokoroModel({Uri? downloadUri})
    : _downloadUri = downloadUri ?? Uri.parse(url);
  final Uri _downloadUri;
  static final instance = KokoroModel();
  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2';
  static const digest =
      '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c';
  bool ready = false, preparing = false, present = false;
  String? error;
  Directory? directory;
  String phase = '';
  double? progress;
  HttpClient? _client;
  bool _cancelled = false;
  static const requiredSizes = <String, int>{
    'model.int8.onnx': 114203914,
    'voices.bin': 53790720,
    'tokens.txt': 1111,
    'lexicon-us-en.txt': 5956885,
    'lexicon-zh.txt': 2120131,
    'date-zh.fst': 59154,
    'number-zh.fst': 64482,
    'phone-zh.fst': 88630,
    'dict/jieba.dict.utf8': 5071204,
    'espeak-ng-data/phontab': 55796,
  };

  static const requiredHashes = <String, String>{
    'model.int8.onnx':
        '05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222',
    'voices.bin':
        'e64a5a581d8c2a350d848f51c3121657cd83aa07ed6109172177345874a7244c',
    'tokens.txt':
        '931ab2df2400cd65d580a22402024c2347ced8ae9ea300e545144b1aacc48e14',
    'lexicon-us-en.txt':
        '7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14',
    'lexicon-zh.txt':
        'fea060803db3e59193987f1a3436f56917bda09f3b3595b6588e46ae60cebf93',
    'date-zh.fst':
        'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718',
    'number-zh.fst':
        '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd',
    'phone-zh.fst':
        '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7',
    'dict/jieba.dict.utf8':
        '3043b77068e09c9904f27cad82f12b6ebe9dbdb5aeff3b25e45ab7f9c1122b55',
    'espeak-ng-data/phontab':
        '886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6',
  };
  Future<bool>? _checking;
  String? _checkedSignature;

  void cancel() {
    if (!preparing) return;
    _cancelled = true;
    phase = '正在取消';
    _client?.close(force: true);
    notifyListeners();
  }

  Future<void> remove() async {
    if (preparing) return;
    await check();
    final target = directory;
    if (target != null && await target.exists()) {
      await target.delete(recursive: true);
    }
    ready = false;
    present = false;
    _checkedSignature = null;
    error = null;
    notifyListeners();
  }

  Future<bool> check() {
    if (preparing) return Future.value(ready);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<bool> _check() async {
    final support = await getApplicationSupportDirectory();
    directory = Directory('${support.path}/speech/kokoro');
    final root = directory!;
    present = await root.exists();
    final marker = File('${root.path}/.ready');
    var valid = false;
    try {
      valid = await marker.exists() && await marker.readAsString() == digest;
    } on FileSystemException {
      valid = false;
    } on FormatException {
      valid = false;
    }
    final signature = StringBuffer();
    if (valid) {
      for (final entry in requiredSizes.entries) {
        final stat = await File('${root.path}/${entry.key}').stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size != entry.value) {
          valid = false;
          break;
        }
        signature.write(
          '${entry.key}:${stat.size}:${stat.modified.microsecondsSinceEpoch};',
        );
      }
    }
    if (valid && _checkedSignature != signature.toString()) {
      final rootPath = root.path;
      try {
        valid = await Isolate.run(() async {
          for (final entry in requiredHashes.entries) {
            final actual = await sha256
                .bind(File('$rootPath/${entry.key}').openRead())
                .first;
            if (actual.toString() != entry.value) return false;
          }
          return true;
        });
      } on FileSystemException {
        valid = false;
      }
      _checkedSignature = valid ? signature.toString() : null;
    }
    ready = valid;
    notifyListeners();
    return ready;
  }

  Future<bool> install() async {
    if (preparing) return false;
    preparing = true;
    _cancelled = false;
    phase = '正在连接';
    progress = null;
    error = null;
    notifyListeners();
    Directory? stage;
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final support = await getApplicationSupportDirectory();
      final parent = Directory('${support.path}/speech');
      await parent.create(recursive: true);
      stage = await parent.createTemp('kokoro-');
      final archive = File('${stage.path}/model.tar.bz2');
      final request = await client.getUrl(_downloadUri);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (_cancelled) throw const FormatException('已取消');
      phase = '正在下载';
      notifyListeners();
      if (response.statusCode != 200) throw const FormatException('下载模型失败');
      final sink = archive.openWrite();
      var count = 0;
      try {
        await for (final bytes in response.timeout(
          const Duration(seconds: 45),
        )) {
          if (_cancelled) throw const FormatException('已取消');
          count += bytes.length;
          final next = (count / 147052523).clamp(0.0, 1.0);
          if (progress == null || next - progress! >= .01) {
            progress = next;
            notifyListeners();
          }
          if (count > 200 * 1024 * 1024) throw const FormatException('模型文件过大');
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if (_cancelled) throw const FormatException('已取消');
      phase = '正在校验';
      progress = null;
      notifyListeners();
      if ((await sha256.bind(archive.openRead()).first).toString() != digest) {
        throw const FormatException('模型校验失败');
      }
      if (_cancelled) throw const FormatException('已取消');
      phase = '正在解压';
      notifyListeners();
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
      if (_cancelled) throw const FormatException('已取消');
      final target = Directory('${parent.path}/kokoro');
      if (await target.exists()) await target.delete(recursive: true);
      directory = await Directory('${stage.path}/data').rename(target.path);
      await File('${target.path}/.ready').writeAsString(digest, flush: true);
      _checkedSignature = null;
      present = true;
      ready = true;
      return true;
    } catch (e) {
      error = _cancelled
          ? '已取消'
          : e is TimeoutException
          ? '连接超时，请检查网络后重试'
          : e is FormatException
          ? e.message
          : '模型下载或安装失败，请检查网络与存储空间';
      return false;
    } finally {
      client.close(force: true);
      _client = null;
      if (stage != null && await stage.exists()) {
        await stage.delete(recursive: true);
      }
      preparing = false;
      phase = '';
      progress = null;
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
