import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:pointycastle/asn1.dart';

import '../security/local_cipher.dart';
import 'source_tools.dart';

/// Bounded, synchronous cryptographic primitives; no networking or file access.
class SourceCrypto {
  static Digest digest(String name) =>
      switch (name.toLowerCase().replaceAll('-', '').replaceAll('rsa', '')) {
        'md5' => MD5Digest(),
        'sha1' => SHA1Digest(),
        'sha224' => SHA224Digest(),
        'sha256' => SHA256Digest(),
        'sha384' => SHA384Digest(),
        'sha512' => SHA512Digest(),
        _ => throw const FormatException('不支持的摘要算法'),
      };
  static Object run(Map<String, dynamic> p) {
    Uint8List bytes(String name) {
      final raw = '${p[name] ?? ''}';
      if (raw.length > 8 * 1024 * 1024) throw const FormatException('加密输入过大');
      return base64Decode(raw);
    }

    final operation = p['operation'];
    if (operation == 'random') {
      final size = p['size'];
      if (size is! int || size < 0 || size > 1024 * 1024) {
        throw const FormatException('随机数长度无效');
      }
      return base64Encode(LocalCipher.random(size));
    }
    if (operation == 'digest' || operation == 'hmac') {
      final d = digest('${p['algorithm']}');
      if (operation == 'digest') return base64Encode(d.process(bytes('data')));
      final mac = HMac(d, d.byteLength)..init(KeyParameter(bytes('key')));
      return base64Encode(mac.process(bytes('data')));
    }
    if (operation == 'hkdf') {
      final d = digest('${p['algorithm']}');
      final length = p['length'];
      if (length is! int || length < 1 || length > 255 * d.digestSize) {
        throw const FormatException('HKDF 长度无效');
      }
      final kdf = HKDFKeyDerivator(d)
        ..init(
          HkdfParameters(bytes('key'), length, bytes('salt'), bytes('info')),
        );
      final output = Uint8List(length);
      kdf.deriveKey(null, 0, output, 0);
      return base64Encode(output);
    }
    if (operation == 'scrypt') {
      final int n = p['N'] as int? ?? 16384,
          r = p['r'] as int? ?? 8,
          parallel = p['p'] as int? ?? 1;
      final length = p['length'];
      if (n < 2 ||
          n > 65536 ||
          n & (n - 1) != 0 ||
          r < 1 ||
          r > 32 ||
          parallel < 1 ||
          parallel > 4 ||
          n * r * 128 > 32 * 1024 * 1024 ||
          n * r * parallel > 524288 ||
          length is! int ||
          length < 1 ||
          length > 4096) {
        throw const FormatException('scrypt 参数超出限制');
      }
      final kdf = Scrypt()
        ..init(ScryptParameters(n, r, parallel, length, bytes('salt')));
      return base64Encode(kdf.process(bytes('key')));
    }
    if (operation == 'pbkdf2') {
      final count = p['iterations'], length = p['length'];
      if (count is! int ||
          count < 1 ||
          count > 1000000 ||
          length is! int ||
          length < 1 ||
          length > 4096) {
        throw const FormatException('PBKDF2 参数超出限制');
      }
      final d = digest('${p['algorithm']}');
      final kdf = PBKDF2KeyDerivator(HMac(d, d.byteLength))
        ..init(Pbkdf2Parameters(bytes('salt'), count, length));
      return base64Encode(kdf.process(bytes('key')));
    }
    if (operation == 'aes') {
      final match = RegExp(r'^aes-(128|192|256)-(cbc|ecb|ctr|gcm|cfb|ofb)$')
          .firstMatch('${p['algorithm']}'.toLowerCase());
      if (match == null) throw const FormatException('不支持的 cipher 算法');
      final key = bytes('key'), iv = bytes('iv');
      if (key.length * 8 != int.parse(match.group(1)!)) {
        throw const FormatException('Cipher 密钥长度无效');
      }
      final mode = match.group(2)!;
      final encrypt = p['encrypt'] == true;
      var input = bytes('data');
      if (mode == 'gcm') {
        if (iv.isEmpty || iv.length > 60) {
          throw const FormatException('GCM IV 长度无效');
        }
        final int tagLength = p['tagLength'] as int? ?? 16;
        if (![4, 8, 12, 13, 14, 15, 16].contains(tagLength)) {
          throw const FormatException('GCM 标签长度无效');
        }
        if (!encrypt) {
          final tag = bytes('tag');
          if (tag.length != tagLength) {
            throw const FormatException('GCM 认证标签缺失');
          }
          input = Uint8List.fromList([...input, ...tag]);
        }
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            encrypt,
            AEADParameters(KeyParameter(key), tagLength * 8, iv, bytes('aad')),
          );
        final result = cipher.process(input);
        return {
          'data': base64Encode(
            encrypt ? result.sublist(0, result.length - tagLength) : result,
          ),
          if (encrypt)
            'tag': base64Encode(result.sublist(result.length - tagLength)),
        };
      }
      if (mode == 'ecb' ? iv.isNotEmpty : iv.length != 16) {
        throw const FormatException('Cipher IV 长度无效');
      }
      if (['ctr', 'cfb', 'ofb'].contains(mode)) {
        if (mode == 'ctr') {
          final cipher = CTRStreamCipher(AESEngine())
            ..init(encrypt, ParametersWithIV(KeyParameter(key), iv));
          return {'data': base64Encode(cipher.process(input))};
        }
        final BlockCipher block = mode == 'cfb'
            ? CFBBlockCipher(AESEngine(), 16)
            : OFBBlockCipher(AESEngine(), 16);
        block.init(encrypt, ParametersWithIV(KeyParameter(key), iv));
        // Feedback modes accept partial final blocks without adding padding.
        final padded = Uint8List((input.length + 15) ~/ 16 * 16)
          ..setAll(0, input);
        final out = Uint8List(padded.length);
        for (var i = 0; i < padded.length; i += 16) {
          block.processBlock(padded, i, out, i);
        }
        return {'data': base64Encode(out.sublist(0, input.length))};
      }
      if (input.isEmpty && p['padding'] == false) return {'data': ''};
      return {
        'data': SourceTools.run({
          'operation': 'aes',
          'key': p['key'],
          'iv': p['iv'] ?? '',
          'data': p['data'],
          'encrypt': encrypt,
          'mode': mode.toUpperCase(),
          'padding': p['padding'] == false ? 'none' : 'pkcs7',
        }),
      };
    }
    if (operation == 'rsa' || operation == 'sign' || operation == 'verify') {
      final key = _rsaKey(
        '${p['pem'] ?? ''}',
        private: p['private'] == true || operation == 'sign',
      );
      final random = FortunaRandom()
        ..seed(KeyParameter(LocalCipher.random(32)));
      final AsymmetricKeyParameter parameters = key is RSAPrivateKey
          ? PrivateKeyParameter<RSAPrivateKey>(key)
          : PublicKeyParameter<RSAPublicKey>(key as RSAPublicKey);
      if (operation != 'rsa') {
        final d = digest('${p['algorithm']}');
        final padding = p['padding'] ?? 1;
        if (padding != 1) throw const FormatException('RSA 签名仅支持 PKCS1 v1.5');
        final signer = Signer('${d.algorithmName}/RSA')
          ..init(operation == 'sign', parameters);
        return operation == 'sign'
            ? base64Encode(
                (signer.generateSignature(bytes('data')) as RSASignature).bytes,
              )
            : signer.verifySignature(
                bytes('data'),
                RSASignature(bytes('signature')),
              );
      }
      final padding = p['padding'] ?? 4;
      final AsymmetricBlockCipher cipher;
      if (padding == 1) {
        cipher = PKCS1Encoding(RSAEngine());
      } else if (padding == 3) {
        cipher = RSAEngine();
      } else if (padding == 4) {
        final name = '${p['oaepHash'] ?? 'sha1'}';
        cipher = OAEPEncoding.withCustomDigest(
          () => digest(name),
          RSAEngine(),
          bytes('label'),
        );
      } else {
        throw const FormatException('RSA 填充无效');
      }
      final encrypt = p['encrypt'] == true;
      cipher.init(encrypt, ParametersWithRandom(parameters, random));
      final input = bytes('data');
      if (input.length > cipher.inputBlockSize) {
        throw const FormatException('RSA 输入超过单块限制');
      }
      return base64Encode(cipher.process(input));
    }
    throw const FormatException('不支持的加密操作');
  }

  static RSAAsymmetricKey _rsaKey(String pem, {required bool private}) {
    if (pem.length > 16384 || pem.contains('ENCRYPTED')) {
      throw const FormatException('RSA PEM 格式无效');
    }
    var node =
        ASN1Parser(
              base64Decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '')),
            ).nextObject()
            as ASN1Sequence;
    if (node.elements!.length == 2 && node.elements![1] is ASN1BitString) {
      node =
          ASN1Parser(
                Uint8List.fromList(
                  (node.elements![1] as ASN1BitString).stringValues!,
                ),
              ).nextObject()
              as ASN1Sequence;
    } else if (node.elements!.length >= 3 &&
        node.elements![2] is ASN1OctetString) {
      node =
          ASN1Parser(
                Uint8List.fromList(
                  (node.elements![2] as ASN1OctetString).octets!,
                ),
              ).nextObject()
              as ASN1Sequence;
    }
    BigInt number(int i) => (node.elements![i] as ASN1Integer).integer!;
    final isPrivate = node.elements!.length > 2;
    final n = number(isPrivate ? 1 : 0);
    if (n.bitLength < 1024 || n.bitLength > 4096) {
      throw const FormatException('RSA 支持 1024–4096 位密钥');
    }
    if (private && !isPrivate) throw const FormatException('需要 RSA 私钥');
    return private
        ? RSAPrivateKey(n, number(3), number(4), number(5))
        : RSAPublicKey(n, number(isPrivate ? 2 : 1));
  }
}
