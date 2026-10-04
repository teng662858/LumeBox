import 'dart:typed_data';

/// 纯 Dart 的 MD5（RFC 1321）。
///
/// 用途只有一个：猫源订阅的 `.js.md5` 约定——清单文件里是脚本的 MD5 校验值，
/// 脚本实体在去掉 `.md5` 的同名地址上，导入前先核对校验值。
///
/// 为什么自己写而不引依赖：算法固定且短（本文件），校验值在测试里对着标准
/// 向量验证；为这一个函数引入一个包不划算。沙箱里图源脚本用的是 JS 侧 crypto
/// 垫片，与这里互不相干。
class Md5 {
  Md5._();

  /// 取 MD5 摘要（16 字节）。入参是原始字节，不做任何编码猜测。
  static Uint8List digest(List<int> message) {
    final bytes = List<int>.of(message);
    final bitLength = bytes.length * 8;
    bytes.add(0x80);
    while (bytes.length % 64 != 56) {
      bytes.add(0);
    }
    // 长度按小端 64 位追加（8 × 8 位）。
    for (var i = 0; i < 8; i++) {
      bytes.add((bitLength ~/ (1 << (8 * i))) & 0xff);
    }

    var h0 = 0x67452301;
    var h1 = 0xefcdab89;
    var h2 = 0x98badcfe;
    var h3 = 0x10325476;

    for (var chunk = 0; chunk < bytes.length; chunk += 64) {
      final words = List<int>.generate(
        16,
        (w) =>
            bytes[chunk + w * 4] |
            (bytes[chunk + w * 4 + 1] << 8) |
            (bytes[chunk + w * 4 + 2] << 16) |
            (bytes[chunk + w * 4 + 3] << 24),
      );

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;

      for (var step = 0; step < 64; step++) {
        int f;
        int g;
        if (step < 16) {
          f = (b & c) | (~b & d);
          g = step;
        } else if (step < 32) {
          f = (d & b) | (~d & c);
          g = (5 * step + 1) % 16;
        } else if (step < 48) {
          f = b ^ c ^ d;
          g = (3 * step + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = (7 * step) % 16;
        }
        final temp = d;
        d = c;
        c = b;
        b = (b + _rotl((a + f + _k[step] + words[g]) & 0xFFFFFFFF, _s[step])) &
            0xFFFFFFFF;
        a = temp;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
    }

    final out = Uint8List(16);
    final state = <int>[h0, h1, h2, h3];
    for (var word = 0; word < 4; word++) {
      for (var i = 0; i < 4; i++) {
        out[word * 4 + i] = (state[word] >> (8 * i)) & 0xff;
      }
    }
    return out;
  }

  /// 取小写十六进制摘要（32 位），与 `.js.md5` 清单里的写法一致。
  static String hex(List<int> message) => toHex(digest(message));

  /// 字节 → 小写十六进制。
  static String toHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// 文本是不是一个 MD5 校验值（32 位十六进制，允许首尾空白）。
  static String? parseHex(String text) {
    final value = text.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) return null;
    return value;
  }

  static int _rotl(int value, int count) =>
      (((value << count) & 0xFFFFFFFF) | ((value & 0xFFFFFFFF) >> (32 - count))) &
      0xFFFFFFFF;

  static const List<int> _k = <int>[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  static const List<int> _s = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
}
