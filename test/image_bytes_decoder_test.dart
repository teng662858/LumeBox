import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart'
    show
        AEADParameters,
        AESEngine,
        BlockCipher,
        CBCBlockCipher,
        ECBBlockCipher,
        GCMBlockCipher,
        KeyParameter,
        ParametersWithIV;
import 'package:lume_box/core/reading/image_bytes_decoder.dart';

void main() {
  test(
    'base64 XOR covers match the public renderer and reject an incorrect key',
    () {
      final png = Uint8List.fromList([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        1,
        2,
        3,
        4,
        5,
      ]);
      final key = utf8.encode('sample-key');
      final cipher = Uint8List.fromList(
        List.generate(png.length, (i) => png[i] ^ key[i % key.length]),
      );
      final body = Uint8List.fromList(utf8.encode(base64Encode(cipher)));
      expect(
        decodeSourceImage(body, {
          'x-lume-image-encoding': 'xor-base64',
          'x-lume-image-key': 'sample-key',
        }),
        orderedEquals(png),
      );
      expect(
        () => decodeSourceImage(body, {
          'x-lume-image-encoding': 'xor-base64',
          'x-lume-image-key': 'wrong',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy multi-block ECB/CBC covers decode off UI, including data URIs',
    () async {
      final key = Uint8List.fromList(utf8.encode('0123456789abcdef'));
      final iv = Uint8List.fromList(utf8.encode('abcdef0123456789'));
      final image = Uint8List.fromList(
        List.generate(256 * 1024, (i) => i % 251),
      );
      for (final cbc in [false, true]) {
        for (final inline in [false, true]) {
          final plain = inline
              ? Uint8List.fromList(
                  utf8.encode('data:image/png;base64,${base64Encode(image)}'),
                )
              : image;
          final padding = 16 - plain.length % 16;
          final padded = Uint8List(plain.length + padding)..setAll(0, plain);
          padded.fillRange(plain.length, padded.length, padding);
          final BlockCipher cipher = cbc
              ? (CBCBlockCipher(AESEngine())
                  ..init(true, ParametersWithIV(KeyParameter(key), iv)))
              : (ECBBlockCipher(AESEngine())..init(true, KeyParameter(key)));
          final encrypted = Uint8List(padded.length);
          for (var offset = 0; offset < padded.length; offset += 16) {
            cipher.processBlock(padded, offset, encrypted, offset);
          }
          var uiResponded = false;
          Timer.run(() => uiResponded = true);
          final decoded = await decodeLegacySourceImageInBackground(
            cbc
                ? Uint8List.fromList(utf8.encode(base64Encode(encrypted)))
                : encrypted,
            key,
            iv: cbc ? iv : null,
          );
          expect(uiResponded, isTrue);
          expect(decoded, image);
        }
      }
      expect(
        await decodeLegacySourceImageInBackground(Uint8List(3), key),
        isNull,
      );
    },
  );
  const fernetHeaders = {
    'X-Lume-Image-Encoding': 'fernet',
    'X-Lume-Image-Key': 'NyGRG56A8i5J2JMqh7da83r2MMfgbM7Ppw1aCF8YnAY=',
  };
  test('encrypted cover decoding yields to UI events and propagates malformed payloads', () async {
    const headers = {
      'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
      'X-Lume-Image-Key': 'my2ecret782ecret',
      'X-Lume-Image-IV': 'my2ecret782ecret',
    };
    var responsive = false;
    Timer.run(() => responsive = true);
    final decoded = await decodeSourceImageInBackground(
      base64Decode('2PYbUWttRSwkvhc43GjR7b0ZD9UVipvpW1dructvID0='),
      headers,
    );
    expect(responsive, isTrue);
    expect(utf8.decode(decoded), 'reader-image-fixture');
    await expectLater(
      decodeSourceImageInBackground(Uint8List(3), headers),
      throwsFormatException,
    );
    final plain = Uint8List.fromList([
      0x89,
      0x50,
      0x4e,
      0x47,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    expect(
      identical(await decodeSourceImageInBackground(plain, headers), plain),
      isTrue,
    );
  });
  test(
    'Fernet full and encrypted-prefix images reconstruct the original PNG',
    () {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=',
      );
      for (final token in [
        'gAAAAAAAAAABBQUFBQUFBQUFBQUFBQUFBXezJcxgBrQChEp93jxOA0kTSqLkKIVkK40nOKMLKHQdMB2vTirf3s8-v58vjUiBVURBYT_ZdCJiK67ztol0g1q3A3k4SKyCxNMB8xwVlojIjUEP0qiq_CSyra3qivk0fZxh_uUIUFe4bZIYZNirymY6luHKqZ_mgUN2XhIHn0FOB75p7qadfULW-QKEYnXlsZ7DtOGyUq5Af07tsD8eNUM',
        'gAAAAAAAAAABBQUFBQUFBQUFBQUFBQUFBXezJcxgBrQChEp93jxOA0kTSqLkKIVkK40nOKMLKHQdMB2vTirf3s8-v58vjUiBVURBYT_ZdCJiK67ztol0g1qbTOFfLzcnpoxA5Wxz5JTwpFLyYb5c9iNrQB-ZRdDty7WLzrmBWNNE6_4bRYAkyTg@@@CAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=',
      ]) {
        expect(
          decodeSourceImage(
            Uint8List.fromList(utf8.encode(token)),
            fernetHeaders,
          ),
          png,
        );
      }
      expect(identical(decodeSourceImage(png, fernetHeaders), png), isTrue);
    },
  );
  test('Fernet signature corruption and malformed image payloads fail', () {
    final token =
        'gAAAAAAAAAABBQUFBQUFBQUFBQUFBQUFBXezJcxgBrQChEp93jxOA0kTSqLkKIVkK40nOKMLKHQdMB2vTirf3s8-v58vjUiBVURBYT_ZdCJiK67ztol0g1q3A3k4SKyCxNMB8xwVlojIjUEP0qiq_CSyra3qivk0fZxh_uUIUFe4bZIYZNirymY6luHKqZ_mgUN2XhIHn0FOB75p7qadfULW-QKEYnXlsZ7DtOGyUq5Af07tsD8eNUM';
    final raw = base64Url.decode(base64Url.normalize(token));
    raw[raw.length - 1] ^= 1;
    for (final invalid in [
      base64UrlEncode(raw),
      'not-a-token',
      '$token@@@bad',
    ]) {
      expect(
        () => decodeSourceImage(
          Uint8List.fromList(utf8.encode(invalid)),
          fernetHeaders,
        ),
        throwsFormatException,
      );
    }
  });
  const mh18Headers = {
    'X-Lume-Image-Encoding': 'aes-cbc-nopadding',
    'X-Lume-Image-Key': 'f5d965df75336270',
    'X-Lume-Image-IV': '97b60394abc2fbe1',
  };
  test('十八漫画公开阅读器 NoPadding 算法与独立 Node 密文一致', () {
    final bytes = base64Decode(
      '3eKMR0wnLS34vbK+a7RYO+Sg59cqbQxbd0uXTdOuo7uplj/lyzZAx8EnxO6OKvGXULd5QgLsvtunIt77KVDrX6XtBWyLMVxPoiTjER+LZ+I=',
    );
    final decoded = decodeSourceImage(bytes, mh18Headers);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=',
    );
    expect(decoded.take(png.length), png);
    expect(decoded.skip(png.length), everyElement(0));
  });
  test('十八漫画混合明文图片原样保留，不重复解密', () {
    for (final signature in [
      [0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0, 0, 0, 0, 0],
      [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50],
    ]) {
      final bytes = Uint8List.fromList(signature);
      expect(identical(decodeSourceImage(bytes, mh18Headers), bytes), isTrue);
      expect(
        identical(
          decodeSourceImage(bytes, {
            ...mh18Headers,
            'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
          }),
          bytes,
        ),
        isTrue,
      );
    }
  });
  test('NoPadding 不完整分组和错误解密内容明确失败', () {
    expect(
      () => decodeSourceImage(Uint8List(15), mh18Headers),
      throwsFormatException,
    );
    expect(
      () => decodeSourceImage(Uint8List(16), mh18Headers),
      throwsFormatException,
    );
  });
  test('corrupt encoded image bytes report a format failure', () {
    final bytes = base64Decode('2PYbUWttRSwkvhc43GjR7b0ZD9UVipvpW1dructvID0=');
    bytes[bytes.length - 1] ^= 1;
    expect(
      () => decodeSourceImage(bytes, const {
        'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
        'X-Lume-Image-Key': 'my2ecret782ecret',
        'X-Lume-Image-IV': 'my2ecret782ecret',
      }),
      throwsFormatException,
    );
  });
  test(
    'public reader AES-CBC bytes match an independent Node crypto fixture',
    () {
      final result = decodeSourceImage(
        base64Decode('2PYbUWttRSwkvhc43GjR7b0ZD9UVipvpW1dructvID0='),
        const {
          'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
          'X-Lume-Image-Key': 'my2ecret782ecret',
          'X-Lume-Image-IV': 'my2ecret782ecret',
        },
      );
      expect(utf8.decode(result), 'reader-image-fixture');
    },
  );
  test(
    'ordinary images pass through and invalid encrypted images are rejected',
    () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(identical(decodeSourceImage(bytes, const {}), bytes), isTrue);
      expect(
        () => decodeSourceImage(bytes, const {
          'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
          'X-Lume-Image-Key': 'short',
        }),
        throwsFormatException,
      );
    },
  );
  test('tvimage1 envelope (听友听书 影视封面) round-trips and rejects tampering', () {
    // 按站点前端 decodeImageEnvelope 的反向构造：头是明文 JSON、正文 AES-256-GCM、
    // wrapped_key = key XOR SHA-256(固定串 + nonce + 摘要 + 0 + asset_id + 0 + role)。
    const assetId = 'asset-9e1c';
    const role = 'work-cover';
    final key = Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + 5) & 0xff),
    );
    final nonce = Uint8List.fromList(
      List.generate(12, (i) => (i * 3 + 1) & 0xff),
    );
    final image = Uint8List.fromList([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      ...List.generate(200, (i) => (i * 13) & 0xff),
    ]);
    final digest = crypto.sha256.convert(image).bytes;
    final material = <int>[
      ...utf8.encode('tv.image-envelope/v3/wrapped-key'),
      0,
      ...nonce,
      ...digest,
      0,
      ...utf8.encode(assetId),
      0,
      ...utf8.encode(role),
    ];
    final mask = crypto.sha256.convert(material).bytes;
    final wrapped = List<int>.generate(32, (i) => key[i] ^ mask[i]);
    String b64url(List<int> bytes) =>
        base64Url.encode(bytes).replaceAll('=', '');
    final header = utf8.encode(
      jsonEncode({
        'schema': 'tv.image-envelope',
        'version': 3,
        'algorithm': 'AES-256-GCM',
        'asset_id': assetId,
        'role': role,
        'nonce': b64url(nonce),
        'wrapped_key': b64url(wrapped),
        'plaintext_sha256': digest
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'plaintext_bytes': image.length,
        'mime_type': 'image/png',
      }),
    );
    final aad = Uint8List.fromList(header);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
    final body = cipher.process(image);
    final headLength = ByteData(4)..setUint32(0, header.length, Endian.big);
    final envelope = Uint8List.fromList([
      ...utf8.encode('TVIMAGE1'),
      ...headLength.buffer.asUint8List(),
      ...header,
      ...body,
    ]);
    final decoded = decodeSourceImage(envelope, const {
      'x-lume-image-encoding': 'tvimage1',
    });
    expect(decoded, image);

    final tampered = Uint8List.fromList(envelope)
      ..[envelope.length - 1] ^= 0x01;
    expect(
      () => decodeSourceImage(tampered, const {
        'x-lume-image-encoding': 'tvimage1',
      }),
      throwsFormatException,
    );
    expect(
      () => decodeSourceImage(
        Uint8List.fromList(utf8.encode('TVIMAGE1')),
        const {'x-lume-image-encoding': 'tvimage1'},
      ),
      throwsFormatException,
    );
  });
}
