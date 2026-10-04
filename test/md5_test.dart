import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/util/md5.dart';

/// 宿主侧 MD5 的验证：对着标准向量逐个核对（`.js.md5` 导入依赖它做完整性校验）。
void main() {
  test('标准向量：空串 / abc / 中文 UTF-8', () {
    expect(Md5.hex(const <int>[]), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(Md5.hex(utf8.encode('abc')), '900150983cd24fb0d6963f7d28e17f72');
    expect(Md5.hex(utf8.encode('猫源')), '33c539d76eca2e5ca7d7dd7cfe5366f3');
    expect(
      Md5.hex(utf8.encode('The quick brown fox jumps over the lazy dog')),
      '9e107d9d372bb6826bd81d3542a419d6',
    );
  });

  test('跨块与边界长度（55 / 56 / 64 / 65 字节）', () {
    // 55 字节：仍在单块内；56 字节：需要补一整块；64/65：跨到第二块。
    expect(
      Md5.hex(utf8.encode('a' * 55)),
      'ef1772b6dff9a122358552954ad0df65',
    );
    expect(
      Md5.hex(utf8.encode('a' * 56)),
      '3b0c8ac703f828b04c6c197006d17218',
    );
    expect(
      Md5.hex(utf8.encode('a' * 64)),
      '014842d480b571495a4a0363793f7367',
    );
    expect(
      Md5.hex(utf8.encode('a' * 65)),
      'c743a45e0d2e6a95cb859adae0248435',
    );
  });

  test('真实猫源脚本的校验值可核对', () {
    // 用户提供的猫源：`index.js.md5` 里就是下面这串，脚本实体 6.48MB。
    const checksum = '6c7379bc24a23ec5b923ecf6f9c9d331';
    expect(Md5.parseHex(checksum), checksum);
    expect(Md5.parseHex('  $checksum\n'), checksum, reason: '允许首尾空白');
    expect(Md5.parseHex('$checksum extra'), isNull);
    expect(Md5.parseHex('not-a-hash'), isNull);
    expect(Md5.parseHex('6C7379BC24A23EC5B923ECF6F9C9D331'), checksum,
        reason: '大小写归一');
    expect(Md5.parseHex('6c7379bc24a23ec5b923ecf6f9c9d33'), isNull, reason: '长度不足');
  });

  test('digest 返回 16 字节，toHex 与 hex 一致', () {
    final digest = Md5.digest(utf8.encode('abc'));
    expect(digest.length, 16);
    expect(Md5.toHex(digest), Md5.hex(utf8.encode('abc')));
    expect(
      digest.take(4).toList(),
      <int>[0x90, 0x01, 0x50, 0x98],
      reason: '摘要字节序与标准一致',
    );
  });
}
