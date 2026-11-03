import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import 'windows_key_protection.dart';

/// Authenticated encryption for local credentials. Keys never enter backups.
class LocalCipher {
  LocalCipher(Uint8List key) : _key = Uint8List.fromList(key) {
    if (key.length != 32) throw ArgumentError('需要 256 位密钥');
  }
  final Uint8List _key;
  static const prefix = 'LUMESEC1:';
  static final Map<String, Future<LocalCipher>> _pending = {};

  /// Isolated sample previews may supply a disposable key in debug builds only.
  @visibleForTesting
  static void configurePreview(String directory, Uint8List key) {
    if (!kDebugMode) throw StateError('Preview keys require a debug build');
    _pending[directory] = Future.value(LocalCipher(key));
  }

  static Uint8List random(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static Future<LocalCipher> open() async {
    final directory = await getApplicationSupportDirectory();
    final future = _pending.putIfAbsent(directory.path, () async {
      Uint8List key;
      if (Platform.isIOS) {
        final value = await const MethodChannel('lumebox/source_repository')
            .invokeMethod<String>('storageKey');
        if (value == null) throw StateError('无法读取本机安全存储密钥');
        key = base64Decode(value);
      } else if (Platform.isWindows) {
        final file = File('${directory.path}/private-storage.key');
        await file.parent.create(recursive: true);
        if (await file.exists()) {
          key = WindowsKeyProtection.unprotect(await file.readAsBytes());
        } else {
          key = random(32);
          final temp = File('${file.path}.tmp');
          await temp.writeAsBytes(
            WindowsKeyProtection.protect(key),
            flush: true,
          );
          await temp.rename(file.path);
        }
      } else {
        throw UnsupportedError('此平台尚未提供系统密钥存储');
      }
      return LocalCipher(key);
    });
    try {
      return await future;
    } catch (_) {
      if (identical(_pending[directory.path], future)) {
        _pending.remove(directory.path);
      }
      rethrow;
    }
  }

  String seal(String text, {required String context}) {
    final iv = random(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_key),
          128,
          iv,
          Uint8List.fromList(utf8.encode(context)),
        ),
      );
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(text)));
    return '$prefix${base64Encode([...iv, ...encrypted])}';
  }

  String reveal(String text, {required String context}) {
    if (!text.startsWith(prefix)) return text; // Legacy data, migrated on open.
    try {
      final bytes = base64Decode(text.substring(prefix.length));
      if (bytes.length < 28) throw const FormatException();
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(_key),
            128,
            bytes.sublist(0, 12),
            Uint8List.fromList(utf8.encode(context)),
          ),
        );
      return utf8.decode(cipher.process(bytes.sublist(12)));
    } catch (_) {
      throw const FormatException('私密配置解密失败：密钥不匹配或数据已损坏');
    }
  }
}

class BackupCipher {
  static const format = 'lumebox-encrypted-configuration';
  static const iterations = 210000;

  static Uint8List _derive(String password, Uint8List salt, int count) {
    if (password.isEmpty) throw const FormatException('请输入备份密码');
    if (salt.length != 16 || count < 100000 || count > 1000000) {
      throw const FormatException('备份密钥参数无效');
    }
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, count, 32));
    return kdf.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Future<String> encode(String plaintext, {String? password}) async {
    if (utf8.encode(plaintext).length > 47 * 1024 * 1024) {
      throw const FormatException('配置数据过大，无法生成 64MB 以内的加密备份');
    }
    final salt = LocalCipher.random(16);
    final portable = password != null;
    final cipher = portable
        ? LocalCipher(
            await Isolate.run(() => _derive(password, salt, iterations)),
          )
        : await LocalCipher.open();
    final header = {
      'format': format,
      'version': 1,
      'alg': 'A256GCM',
      'kdf': portable ? 'PBKDF2-SHA256' : 'device',
      if (portable) 'iterations': iterations,
      if (portable) 'salt': base64Encode(salt),
    };
    final context = jsonEncode(header);
    return jsonEncode({
      ...header,
      'payload': cipher.seal(plaintext, context: context),
    });
  }

  static bool isEncrypted(String text) {
    try {
      return (jsonDecode(text) as Map)['format'] == format;
    } catch (_) {
      return false;
    }
  }

  static bool needsPassword(String text) {
    try {
      final d = jsonDecode(text) as Map;
      return d['format'] == format && d['kdf'] != 'device';
    } catch (_) {
      return false;
    }
  }

  static Future<String> decode(String text, {String? password}) async {
    if (utf8.encode(text).length > 64 * 1024 * 1024) {
      throw const FormatException('备份文件过大');
    }
    final value = jsonDecode(text);
    if (value is! Map || value['format'] != format) return text;
    if (value['version'] != 1 ||
        value['alg'] != 'A256GCM' ||
        !['device', 'PBKDF2-SHA256'].contains(value['kdf']) ||
        value['payload'] is! String ||
        !(value['payload'] as String).startsWith(LocalCipher.prefix)) {
      throw const FormatException('不支持的加密备份格式');
    }
    final portable = value['kdf'] == 'PBKDF2-SHA256';
    final header = {
      'format': format,
      'version': 1,
      'alg': 'A256GCM',
      'kdf': value['kdf'],
      if (portable) 'iterations': value['iterations'],
      if (portable) 'salt': value['salt'],
    };
    try {
      final cipher = portable
          ? LocalCipher(
              await Isolate.run(
                () => _derive(
                  password ?? '',
                  base64Decode(value['salt'] as String),
                  value['iterations'] as int,
                ),
              ),
            )
          : await LocalCipher.open();
      return cipher.reveal(
        value['payload'] as String,
        context: jsonEncode(header),
      );
    } catch (_) {
      throw const FormatException('备份解密失败：请检查密码、设备或文件完整性');
    }
  }
}
