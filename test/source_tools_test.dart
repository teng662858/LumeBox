import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_tools.dart';

/// 宿主原生工具（`LumeSource.tools.*`）的行为约定。
///
/// 这些能力是「源里不写纯 JS 加密」的前提：AES / 摘要 / HMAC / XOR 全在 Dart 侧
/// （pointycastle + crypto 包）算，比源内纯 JS 快一到两个数量级。
/// 向量用 node:crypto 生成，保证与主流实现（CryptoJS / OpenSSL）对齐。
void main() {
  final key = base64Encode(List<int>.filled(16, 1));
  final iv = base64Encode(List<int>.filled(16, 2));

  test('AES-CBC/PKCS7 往返，且密文与 node:crypto 一致', () {
    final plain = utf8.encode('hello 世界');
    final encrypted = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': iv,
      'data': base64Encode(plain),
      'mode': 'CBC',
      'encrypt': true,
    }) as String;
    expect(encrypted, 'xBoV6q8HZ1Xo2iBw+vRwRQ==');

    final decrypted = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': iv,
      'data': encrypted,
      'mode': 'CBC',
      'encrypt': false,
    }) as String;
    expect(utf8.decode(base64Decode(decrypted)), 'hello 世界');
  });

  test('AES-CTR 流模式不需要填充', () {
    final out = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': iv,
      'data': base64Encode(utf8.encode('hello')),
      'mode': 'CTR',
      'encrypt': true,
    }) as String;
    expect(out, 'f7N4nxY=');
  });

  test('AES-GCM 密文带 16 字节认证标签，可解回原文', () {
    final encrypted = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': base64Encode(List<int>.filled(12, 3)),
      'data': base64Encode(utf8.encode('hello gcm')),
      'mode': 'GCM',
      'encrypt': true,
    }) as String;
    expect(encrypted, 'USBHRTFdJSeZTShm2n58p+e7/S60/ucH1Q==');

    final decrypted = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': base64Encode(List<int>.filled(12, 3)),
      'data': encrypted,
      'mode': 'GCM',
      'encrypt': false,
    }) as String;
    expect(utf8.decode(base64Decode(decrypted)), 'hello gcm');
  });

  test('AES 参数校验：密钥长度、ECB 不需要 IV', () {
    expect(
      () => SourceTools.run(<String, dynamic>{
        'operation': 'aes',
        'key': base64Encode([1, 2, 3]),
        'iv': iv,
        'data': '',
      }),
      throwsA(isA<FormatException>()),
    );
    final ecb = SourceTools.run(<String, dynamic>{
      'operation': 'aes',
      'key': key,
      'iv': '',
      'data': base64Encode(List<int>.filled(16, 0)),
      'mode': 'ECB',
      'encrypt': false,
      'padding': 'none',
    });
    expect(ecb, isA<String>());
  });

  test('HMAC-SHA256 与 node:crypto 一致', () {
    final out = SourceTools.run(<String, dynamic>{
      'operation': 'hmac',
      'algorithm': 'sha256',
      'key': 'key123',
      'data': 'data456',
    }) as String;
    expect(out, 'b3880868d6658fdd2a6f0b1c75342275b88b42071a1b2ec6e6b769b939cc2cbc');
  });

  test('XOR 按密钥循环，输出 base64', () {
    final out = SourceTools.run(<String, dynamic>{
      'operation': 'xor',
      'key': 'k',
      'data': 'abcd',
    }) as String;
    expect(out, 'CgkIDw==');
  });

  test('摘要支持 md5/sha1/sha256/sha512，未知算法报错', () {
    expect(
      SourceTools.run(<String, dynamic>{'operation': 'digest', 'algorithm': 'md5', 'data': 'abc'}),
      '900150983cd24fb0d6963f7d28e17f72',
    );
    expect(
      () => SourceTools.run(<String, dynamic>{'operation': 'digest', 'algorithm': 'md9', 'data': 'abc'}),
      throwsA(isA<FormatException>()),
    );
  });
}
