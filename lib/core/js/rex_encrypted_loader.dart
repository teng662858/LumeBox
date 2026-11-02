import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../net/lume_http.dart';
import 'source_script.dart';

/// REXENC v2: official key-session service unwraps kb; AES-GCM authenticates JS.
/// Only encrypted source is persisted. Keys and plaintext stay in this loader.
class RexEncryptedLoader {
  RexEncryptedLoader(this.http);
  final LumeHttp http;
  static const endpoint = 'https://api.rexnow.tv/api/widgets/key-session';
  final Map<String, Future<Uint8List>> _pending = {};
  final Map<String, (DateTime, Uint8List)> _keys = {};
  bool _disposed = false;

  void clear() {
    _disposed = true;
    for (final record in _keys.values) {
      record.$2.fillRange(0, record.$2.length, 0);
    }
    _keys.clear();
  }

  Future<Uint8List> _key(String mkv, String kb) async {
    if (_disposed) throw const FormatException('REX 加载器已释放');
    final id = '$mkv:$kb';
    final cached = _keys[id];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    return _pending.putIfAbsent(id, () async {
      try {
        final response = await http.sendBytes(
          url: endpoint,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'LumeBox/1.0',
          },
          bodyBytes: utf8.encode(jsonEncode({'mkv': mkv, 'kb': kb})),
          followRedirects: false,
          maxBytes: 16 * 1024,
          timeout: const Duration(seconds: 30),
        );
        if (response.statusCode != 200) {
          throw FormatException('REX 内容密钥服务返回 HTTP ${response.statusCode}');
        }
        final value = jsonDecode(response.text);
        if (value is! Map || value['key'] is! String) {
          throw const FormatException('REX 内容密钥响应格式无效');
        }
        final key = base64Decode(value['key'] as String);
        if (key.length != 32) throw const FormatException('REX 内容密钥长度无效');
        if (_disposed) {
          key.fillRange(0, key.length, 0);
          throw const FormatException('REX 加载器已释放');
        }
        if (_keys.length >= 32) _keys.remove(_keys.keys.first);
        _keys[id] = (DateTime.now(), key);
        return key;
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('REX 内容密钥加载失败，请检查网络后重试');
      } finally {
        _pending.remove(id);
      }
    });
  }

  Future<String> load(String source) async {
    final script = stripScriptBom(source);
    final match = RegExp(r'^(?:\s*//[^\n]*\n)*\s*(REXENC|FWENC)\r?\n')
        .firstMatch(script);
    if (match == null) return source;
    if (match.group(1) == 'FWENC') {
      throw const FormatException('FWENC 与 REXENC 协议不同，当前不支持此加密格式');
    }
    if (script.length > 8 * 1024 * 1024) {
      throw const FormatException('REX 模块文件过大');
    }
    final lines = script.substring(match.end).trim().split(RegExp(r'\r?\n'));
    if (lines.length != 2) throw const FormatException('REXENC 信封损坏');
    Map header;
    Uint8List iv, encrypted;
    try {
      final raw = jsonDecode(lines[0]);
      if (raw is! Map) throw const FormatException();
      header = raw;
      if (header['v'] != 2 ||
          header['alg'] != 'A256GCM' ||
          header['mkv'] != 'rex-1') {
        throw const FormatException();
      }
      iv = base64Decode(header['iv'] as String);
      if (iv.length != 12 ||
          base64Decode(header['kb'] as String).length != 60) {
        throw const FormatException();
      }
      encrypted = base64Decode(lines[1]);
      if (encrypted.length <= 16) throw const FormatException();
    } catch (_) {
      throw const FormatException('REXENC 版本、算法或信封字段无效');
    }
    final key = await _key(header['mkv'] as String, header['kb'] as String);
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
      final plaintext = utf8.decode(cipher.process(encrypted));
      if (!plaintext.contains('WidgetMetadata')) throw const FormatException();
      // Preserve the persisted module identity; do not write decrypted code back.
      final metadata = SourceMetadata.parseHeader(source);
      final prefix = metadata == null
          ? ''
          : '// LumeRuntime: rex\n// LumeSource: ${jsonEncode({'id': metadata.id, 'name': metadata.name, 'version': metadata.version, 'category': 'video'})}\n';
      return '$prefix$plaintext';
    } catch (_) {
      _keys.remove('${header['mkv']}:${header['kb']}');
      throw const FormatException('REXENC 认证解密失败：密钥不匹配或模块已损坏');
    }
  }
}
