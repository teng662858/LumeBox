import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/image_bytes_decoder.dart';

/// INS AV 的图床（yik.yanyunhome.com）把整张图包成
/// `data:image/jpeg;base64,…` 纯文本下发，响应头却写着 `image/jpeg`。
/// 直接按图片字节解会裂，源里用 `x-lume-image-encoding: data-uri` 交给这里解。
void main() {
  final jpeg = Uint8List.fromList(<int>[
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
    ...List<int>.filled(148, 0x20),
  ]);
  final payload = Uint8List.fromList(
    utf8.encode('data:image/jpeg;base64,${base64Encode(jpeg)}'),
  );

  test('data-uri 包裹的响应解回原始图片字节', () {
    final decoded = decodeSourceImage(payload, const {
      'x-lume-image-encoding': 'data-uri',
    });
    expect(decoded, jpeg);
  });

  test('没有包裹（真图直出）原样返回', () {
    final decoded = decodeSourceImage(jpeg, const {
      'x-lume-image-encoding': 'data-uri',
    });
    expect(decoded, jpeg);
  });

  test('不是 data URI 的正文抛可读错误，不当成图片交给解码器', () {
    expect(
      () => decodeSourceImage(
        Uint8List.fromList(utf8.encode('<html>404</html>')),
        const {'x-lume-image-encoding': 'data-uri'},
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('短写 data:png;base64 也认（同一套 data URI 解析）', () {
    final png = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...List<int>.filled(24, 1),
    ]);
    final decoded = decodeSourceImage(
      Uint8List.fromList(utf8.encode('data:png;base64,${base64Encode(png)}')),
      const {'x-lume-image-encoding': 'data-uri'},
    );
    expect(decoded, png);
  });
}
