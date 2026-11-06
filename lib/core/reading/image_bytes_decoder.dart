import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

typedef _LegacyImageWork = ({Uint8List bytes, Uint8List key, Uint8List? iv});

/// 修复只混淆了**开头若干字节**的图片（Butterfly 系 App 的做法）。
///
/// 站点前端拿到图片后做 `for (i=0; i<100; i++) bytes[i] ^= key[i % key.length]`
/// 再交给浏览器，所以 CDN 上放的是「前 100 字节被 XOR、其余是原图」的文件。
/// 这里按同样的规则还原前 [length] 字节，后面的原样保留。
Uint8List xorRepairImageBytes(
  Uint8List bytes,
  Uint8List key, {
  int length = 100,
}) {
  if (bytes.isEmpty || key.isEmpty) return bytes;
  final limit = length <= 0
      ? bytes.length
      : (length < bytes.length ? length : bytes.length);
  final out = Uint8List.fromList(bytes);
  for (var index = 0; index < limit; index++) {
    out[index] ^= key[index % key.length];
  }
  return out;
}

Future<Uint8List?> decodeLegacySourceImageInBackground(
  Uint8List bytes,
  Uint8List key, {
  Uint8List? iv,
}) => compute(_decodeLegacyImageWork, (bytes: bytes, key: key, iv: iv));

Uint8List? _decodeLegacyImageWork(_LegacyImageWork work) {
  final iv = work.iv;
  final cipherBytes = iv == null
      ? work.bytes
      : base64Decode(base64.normalize(utf8.decode(work.bytes).trim()));
  final BlockCipher cipher = iv == null
      ? (ECBBlockCipher(AESEngine())..init(false, KeyParameter(work.key)))
      : (CBCBlockCipher(AESEngine())
          ..init(false, ParametersWithIV(KeyParameter(work.key), iv)));
  if (cipherBytes.isEmpty || cipherBytes.length % cipher.blockSize != 0) {
    return null;
  }
  final plain = Uint8List(cipherBytes.length);
  for (
    var offset = 0;
    offset < cipherBytes.length;
    offset += cipher.blockSize
  ) {
    cipher.processBlock(cipherBytes, offset, plain, offset);
  }
  final pad = plain.last;
  final body = pad > 0 && pad <= 16 && pad <= plain.length
      ? Uint8List.sublistView(plain, 0, plain.length - pad)
      : plain;
  final text = utf8.decode(body, allowMalformed: true);
  return decodeImageDataUri(text) ?? body;
}

Uint8List? decodeImageDataUri(String url) {
  final text = url.trim();
  if (!text.startsWith('data:')) return null;
  final comma = text.indexOf(',');
  if (comma <= 0) return null;
  var meta = text.substring(5, comma).toLowerCase();
  if (!meta.startsWith('image/')) {
    // Some sites emit the short form `data:png;base64,…` (9sex's decrypted
    // covers do). Accept only known image subtypes; do not turn `data:text/…`
    // into an image by accident.
    final subtype = meta.split(';').first;
    const imageSubtypes = {'png', 'jpeg', 'jpg', 'gif', 'webp', 'bmp', 'avif'};
    if (!imageSubtypes.contains(subtype)) return null;
    meta =
        'image/${subtype == 'jpg' ? 'jpeg' : subtype}'
        '${meta.substring(subtype.length)}';
  }
  final payload = text.substring(comma + 1);
  try {
    if (meta.contains('base64')) return base64Decode(payload);
    return Uint8List.fromList(Uri.decodeComponent(payload).codeUnits);
  } catch (_) {
    return null;
  }
}

Uint8List _decodeImageWork(
  ({Uint8List bytes, Map<String, String> headers}) work,
) => decodeSourceImage(work.bytes, work.headers);

/// CPU-heavy image decryption must not hold the scrolling UI isolate.
Future<Uint8List> decodeSourceImageInBackground(
  Uint8List bytes,
  Map<String, String> headers,
) {
  final encoded = headers.entries.any(
    (entry) =>
        entry.key.toLowerCase() == 'x-lume-image-encoding' &&
        entry.value.isNotEmpty,
  );
  if (!encoded || _isPlainImage(bytes)) return Future.value(bytes);
  return compute(_decodeImageWork, (bytes: bytes, headers: headers));
}

/// A source may describe its public reader's image encoding using local headers.
/// These fields are consumed locally and never sent to the image server.
Uint8List decodeSourceImage(Uint8List bytes, Map<String, String> headers) {
  String field(String name) =>
      headers.entries
          .where((entry) => entry.key.toLowerCase() == name)
          .map((entry) => entry.value)
          .firstOrNull ??
      '';
  final encoding = field('x-lume-image-encoding');
  if (encoding.isEmpty) return bytes;
  if (encoding == 'fernet') {
    if (_isPlainImage(bytes)) return bytes;
    return _decodeFernetImage(bytes, field('x-lume-image-key'));
  }
  // 听友听书（tingyou.fm）的影视封面是站方自研的 TVIMAGE1 信封：
  //   ['TVIMAGE1'][uint32 头长度][JSON 头][AES-256-GCM 密文 + 16 字节 tag]
  // 头里带 nonce / wrapped_key / plaintext_sha256，wrapped_key 与
  // SHA-256('tv.image-envelope/v3/wrapped-key\0' + nonce + 摘要 + 0 + asset_id + 0 + role)
  // 逐字节异或过；JSON 头本身又是 GCM 的 AAD。所以既没有固定密钥也没有固定 IV。
  if (encoding == 'tvimage1') {
    if (_isPlainImage(bytes)) return bytes;
    return _decodeTvImageEnvelope(bytes);
  }
  // Some sites store each JPEG byte-reversed (aido8's `.ttf` covers). The
  // reversal is a pure byte permutation, so it needs no key.
  if (encoding == 'reverse') {
    final reversed = Uint8List.fromList(bytes.reversed.toList());
    if (!_isPlainImage(reversed)) {
      throw const FormatException('Invalid reversed source image');
    }
    return reversed;
  }
  // INS AV 的图床把真图整段包成 `data:image/jpeg;base64,…` 纯文本下发
  //（响应头还写着 image/jpeg，直接当图片解会裂）。解出 data URI 即可，无密钥。
  if (encoding == 'xor-base64') {
    final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
    if (key.isEmpty) throw const FormatException('Missing XOR image key');
    final encoded = base64Decode(utf8.decode(bytes).trim());
    final decoded = xorRepairImageBytes(encoded, key, length: encoded.length);
    if (!_isPlainImage(decoded)) {
      throw const FormatException('Invalid XOR source image');
    }
    return decoded;
  }
  if (encoding == 'data-uri') {
    if (_isPlainImage(bytes)) return bytes;
    final inline = decodeImageDataUri(utf8.decode(bytes, allowMalformed: true));
    if (inline != null) return inline;
    throw const FormatException('Invalid data-uri source image');
  }
  // 杏吧的图床在真图前面塞 16 字节随机头（其后才是 RIFF/JPEG）。
  // 只在「跳过 16 字节后是合法图片」时跳过，明文图原样返回。
  if (encoding == 'strip-prefix-16') {
    if (_isPlainImage(bytes)) return bytes;
    if (bytes.length > 20 && _isPlainImage(Uint8List.sublistView(bytes, 16))) {
      return Uint8List.sublistView(bytes, 16);
    }
    throw const FormatException('Invalid prefixed source image');
  }
  // Butterfly 系 App 把图片前 N 字节（默认 100）与 imgKey 循环 XOR 再上传，
  // 后面的字节就是原图。长度用 `x-lume-image-length` 指定，省略按 100 算。
  if (encoding == 'xor-prefix') {
    if (_isPlainImage(bytes)) return bytes;
    final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
    if (key.isEmpty) {
      throw const FormatException('Invalid source image encoding parameters');
    }
    final declared = int.tryParse(field('x-lume-image-length')) ?? 100;
    if (declared <= 0) {
      throw const FormatException('Invalid source image encoding parameters');
    }
    return xorRepairImageBytes(bytes, key, length: declared);
  }
  // hxc 的 `.aes` 封面是「Base64 文本 → AES-128-ECB/NoPadding → data URI」。
  // 先解 Base64 再交给 ECB，和下面的原始二进制 ECB 路径分开。
  if (encoding == 'aes-ecb-base64') {
    final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
    if (!{16, 24, 32}.contains(key.length)) {
      throw const FormatException('Invalid source image encoding parameters');
    }
    Uint8List cipherBytes;
    try {
      cipherBytes = base64Decode(utf8.decode(bytes).trim());
    } on Object {
      throw const FormatException('Invalid base64 source image');
    }
    if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) {
      throw const FormatException('Invalid base64 source image');
    }
    final cipher = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));
    final plain = Uint8List(cipherBytes.length);
    for (var offset = 0; offset < cipherBytes.length; offset += 16) {
      cipher.processBlock(cipherBytes, offset, plain, offset);
    }
    final text = utf8
        .decode(plain, allowMalformed: true)
        .replaceAll('\u0000', '')
        .trim();
    final inline = decodeImageDataUri(text);
    if (inline != null) return inline;
    if (_isPlainImage(plain)) return plain;
    throw const FormatException('Invalid encoded source image');
  }
  final noPadding = encoding == 'aes-cbc-nopadding';
  final ivPrefixPadding = encoding == 'aes-cbc-pkcs7-ivprefix';
  if (encoding != 'aes-cbc-pkcs7' && !noPadding && !ivPrefixPadding) {
    throw const FormatException('Unsupported source image encoding');
  }
  // The public reader mixes encrypted business images with plain images.
  if (_isPlainImage(bytes)) return bytes;
  final key = Uint8List.fromList(utf8.encode(field('x-lume-image-key')));
  if (!{16, 24, 32}.contains(key.length) || bytes.isEmpty) {
    throw const FormatException('Invalid source image encoding parameters');
  }
  // A few sites put the CBC IV in the first 16 bytes of every image instead of
  // a fixed header (yuese's `.jpg.aes`). Both the IV and the ciphertext are
  // per-file, so they cannot be described by `x-lume-image-iv`.
  if (ivPrefixPadding) {
    if (bytes.length <= 16 || (bytes.length - 16) % 16 != 0) {
      throw const FormatException('Invalid iv-prefixed source image');
    }
    final iv = Uint8List.sublistView(bytes, 0, 16);
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            false,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
              ParametersWithIV(KeyParameter(key), iv),
              null,
            ),
          );
    try {
      final plain = cipher.process(Uint8List.sublistView(bytes, 16));
      if (!_isPlainImage(plain)) {
        throw const FormatException('Invalid encoded source image');
      }
      return plain;
    } on Object {
      throw const FormatException('Invalid encoded source image');
    }
  }
  final iv = Uint8List.fromList(utf8.encode(field('x-lume-image-iv')));
  if (iv.length != 16 || bytes.length % 16 != 0) {
    throw const FormatException('Invalid source image encoding parameters');
  }
  if (noPadding) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(bytes.length);
    for (var offset = 0; offset < bytes.length; offset += cipher.blockSize) {
      cipher.processBlock(bytes, offset, output, offset);
    }
    if (!_isPlainImage(output)) {
      throw const FormatException('Invalid encoded source image');
    }
    return output;
  }
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
  try {
    return cipher.process(bytes);
  } on Object {
    throw const FormatException('Invalid encoded source image');
  }
}

/// Some public readers encrypt only the data-URI prefix, then append the
/// remaining Base64 after @@@. Authenticate the Fernet part before rebuilding.
Uint8List _decodeFernetImage(Uint8List bytes, String encodedKey) {
  try {
    final text = utf8.decode(bytes).trim();
    final separator = text.indexOf('@@@');
    final token = separator < 0 ? text : text.substring(0, separator);
    final raw = base64Url.decode(base64Url.normalize(token));
    final key = base64Url.decode(base64Url.normalize(encodedKey));
    if (key.length != 32 || raw.length < 73 || raw[0] != 0x80) {
      throw const FormatException('Invalid Fernet image parameters');
    }
    final signedEnd = raw.length - 32;
    final signature = crypto.Hmac(
      crypto.sha256,
      key.sublist(0, 16),
    ).convert(raw.sublist(0, signedEnd)).bytes;
    var difference = 0;
    for (var i = 0; i < 32; i++) {
      difference |= signature[i] ^ raw[signedEnd + i];
    }
    if (difference != 0 || (signedEnd - 25) % 16 != 0) {
      throw const FormatException('Invalid Fernet image signature');
    }
    final cipher =
        PaddedBlockCipherImpl(
          PKCS7Padding(),
          CBCBlockCipher(AESEngine()),
        )..init(
          false,
          PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
            ParametersWithIV(KeyParameter(key.sublist(16)), raw.sublist(9, 25)),
            null,
          ),
        );
    final plain = cipher.process(raw.sublist(25, signedEnd));
    if (separator < 0 && _isPlainImage(plain)) return plain;
    final uri =
        utf8.decode(plain) +
        (separator < 0 ? '' : text.substring(separator + 3));
    final comma = uri.indexOf(',');
    if (!uri.startsWith('data:image/') ||
        comma < 0 ||
        !uri.substring(0, comma).endsWith(';base64')) {
      throw const FormatException('Invalid Fernet image payload');
    }
    final image = base64Decode(uri.substring(comma + 1));
    if (!_isPlainImage(image)) {
      throw const FormatException('Invalid Fernet image');
    }
    return image;
  } on Object {
    throw const FormatException('Invalid encoded Fernet image');
  }
}

/// 听友听书影视封面的 TVIMAGE1 信封解码。
///
/// 站点前端 `decodeImageEnvelope` 的等价实现：头是明文 JSON，正文是
/// AES-256-GCM（AAD = 头本身），密钥由 `wrapped_key` 与一段 SHA-256 掩码异或得到。
/// 全部输入都来自同一份报文体，脚本不需要（也没有）额外密钥。
Uint8List _decodeTvImageEnvelope(Uint8List bytes) {
  const magic = 'TVIMAGE1';
  const maskPrefix = 'tv.image-envelope/v3/wrapped-key';
  const invalid = FormatException('Invalid tvimage1 source image');
  final signature = utf8.encode(magic);
  if (bytes.length < 12 + 16 + signature.length) throw invalid;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) throw invalid;
  }
  final headerLength = ByteData.sublistView(
    bytes,
    signature.length,
    signature.length + 4,
  ).getUint32(0, Endian.big);
  final headerStart = signature.length + 4;
  final bodyStart = headerStart + headerLength;
  if (headerLength < 2 ||
      headerLength > 64 * 1024 ||
      bodyStart + 16 > bytes.length) {
    throw invalid;
  }
  final headerBytes = Uint8List.sublistView(bytes, headerStart, bodyStart);
  Object? parsed;
  try {
    parsed = jsonDecode(utf8.decode(headerBytes));
  } on Object {
    throw invalid;
  }
  if (parsed is! Map) throw invalid;
  final meta = parsed;
  if (meta['schema'] != 'tv.image-envelope' ||
      meta['version'] != 3 ||
      meta['algorithm'] != 'AES-256-GCM') {
    throw invalid;
  }
  final assetId = meta['asset_id'];
  final role = meta['role'];
  if (assetId is! String ||
      assetId.isEmpty ||
      role is! String ||
      role.isEmpty) {
    throw invalid;
  }
  final digestHex = '${meta['plaintext_sha256'] ?? ''}';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digestHex)) throw invalid;
  final nonce = Uint8List.fromList(_base64UrlBytes('${meta['nonce'] ?? ''}'));
  final wrapped = Uint8List.fromList(
    _base64UrlBytes('${meta['wrapped_key'] ?? ''}'),
  );
  if (nonce.length != 12 || wrapped.length != 32) throw invalid;
  final digest = Uint8List.fromList(_hexBytes(digestHex));

  final material = BytesBuilder(copy: false)
    ..add(utf8.encode(maskPrefix))
    ..addByte(0)
    ..add(nonce)
    ..add(digest)
    ..addByte(0)
    ..add(utf8.encode(assetId))
    ..addByte(0)
    ..add(utf8.encode(role));
  final mask = crypto.sha256.convert(material.takeBytes()).bytes;
  final key = Uint8List(32);
  for (var index = 0; index < 32; index++) {
    key[index] = wrapped[index] ^ mask[index];
  }

  Uint8List plain;
  try {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, nonce, headerBytes));
    plain = cipher.process(Uint8List.sublistView(bytes, bodyStart));
  } on Object {
    throw invalid;
  }
  final actual = crypto.sha256.convert(plain).bytes;
  for (var index = 0; index < 32; index++) {
    if (actual[index] != digest[index]) throw invalid;
  }
  if (!_isPlainImage(plain)) throw invalid;
  return plain;
}

List<int> _base64UrlBytes(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('=')) return const <int>[];
  try {
    return base64Url.decode(base64Url.normalize(trimmed));
  } on Object {
    return const <int>[];
  }
}

List<int> _hexBytes(String hex) {
  final out = <int>[];
  for (var index = 0; index + 1 < hex.length; index += 2) {
    out.add(int.parse(hex.substring(index, index + 2), radix: 16));
  }
  return out;
}

bool _isPlainImage(Uint8List bytes) {
  if (bytes.length < 12) return false;
  bool starts(List<int> signature, [int offset = 0]) {
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  return starts([0xff, 0xd8, 0xff]) ||
      starts([0x89, 0x50, 0x4e, 0x47]) ||
      starts([0x47, 0x49, 0x46, 0x38]) ||
      (starts([0x52, 0x49, 0x46, 0x46]) &&
          starts([0x57, 0x45, 0x42, 0x50], 8)) ||
      starts([0x00, 0x00, 0x01, 0x00]);
}
