import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/comic/repo/comic_repo_mihon_pb_parser.dart';
import 'package:lume_box/features/comic/repo/comic_repo_models.dart';
import 'package:lume_box/features/comic/repo/comic_repo_protobuf.dart';

/// Mihon `index.pb` 解析的验证：结构、gzip、多来源、宽松口径与损坏数据。
///
/// 字段号对着真实索引（keiyoushi 的 index.pb）核对过，这里用手写字节把它固化成
/// 用例——真实文件是第三方产物、不适合进仓库，但结构必须长期锁定。
void main() {
  final baseUri = Uri.parse('https://repo.example/mihon/index.pb');

  test('裸 protobuf：读出名字 / 包名 / 版本 / APK 地址 / 来源名', () {
    final index = ComicRepoMihonPbParser.parse(
      _sampleIndex(compressed: false),
      baseUri: baseUri,
    );

    expect(index.kind, RepoKind.mihon);
    expect(index.extensions.length, 2);

    final first = index.extensions.first;
    expect(first.name, '示例扩展');
    expect(first.id, 'eu.example.one');
    expect(first.version, '1.2.3');
    expect(first.artifact, ExtensionArtifact.apk, reason: 'pb 里的载体仍是 APK');
    expect(first.url.toString(), 'https://repo.example/apk/one-v1.2.3.apk');
    expect(first.language, 'all');
    expect(first.sourceNames, <String>['示例扩展']);
    expect(first.isRunnable, isFalse, reason: 'APK 在本平台不能运行');
  });

  test('gzip 过的索引同样能解析（真实索引就是 gzip）', () {
    final index = ComicRepoMihonPbParser.parse(
      _sampleIndex(compressed: true),
      baseUri: baseUri,
    );

    expect(index.extensions.length, 2);
    expect(index.extensions.first.name, '示例扩展');
  });

  test('多来源扩展：来源名全部收集，语言取第一个来源', () {
    final index = ComicRepoMihonPbParser.parse(
      _sampleIndex(compressed: false),
      baseUri: baseUri,
    );

    final multi = index.extensions[1];
    expect(multi.name, '多来源扩展');
    expect(multi.sourceNames, <String>['来源甲', '来源乙', '来源丙']);
    expect(multi.language, 'zh');
  });

  test('相对 APK 地址按索引地址解析', () {
    final list = _Pb()
      ..message(
        1,
        _Pb()
          ..string(1, '相对地址源')
          ..string(2, 'eu.example.relative')
          ..message(3, _Pb()..string(1, '../apk/relative-v1.0.0.apk'))
          ..string(6, '1.0.0'),
      );
    final bytes = (_Pb()
          ..string(1, '示例仓库')
          ..message(101, list))
        .toBytes();

    final index = ComicRepoMihonPbParser.parse(bytes, baseUri: baseUri);
    expect(
      index.extensions.single.url.toString(),
      'https://repo.example/apk/relative-v1.0.0.apk',
    );
  });

  test('宽松口径：缺 pkg / 缺 APK 地址 / 缺名字的条目只跳过该条', () {
    final list = _Pb()
      ..message(1, _Pb()..string(1, '没有包名')..string(6, '1.0.0'))
      ..message(
        1,
        _Pb()
          ..string(1, '没有载体')
          ..string(2, 'eu.example.noapk')
          ..string(6, '1.0.0'),
      )
      ..message(
        1,
        _Pb()
          ..string(2, 'eu.example.noname')
          ..message(3, _Pb()..string(1, 'https://repo.example/apk/x.apk'))
          ..string(6, '1.0.0'),
      )
      ..message(
        1,
        _Pb()
          ..string(1, '完整条目')
          ..string(2, 'eu.example.ok')
          ..message(3, _Pb()..string(1, 'https://repo.example/apk/ok.apk'))
          ..string(6, '2.0.0'),
      );
    final bytes = (_Pb()
          ..string(1, '示例仓库')
          ..message(101, list))
        .toBytes();

    final index = ComicRepoMihonPbParser.parse(bytes, baseUri: baseUri);
    expect(index.extensions.map((item) => item.name), <String>['完整条目']);
  });

  test('结构不符与损坏数据都给出可读错误', () {
    // 没有扩展列表字段（101）。
    final missing = (_Pb()..string(1, '示例仓库')).toBytes();
    expect(
      () => ComicRepoMihonPbParser.parse(missing, baseUri: baseUri),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('找不到扩展列表'),
        ),
      ),
    );

    // 截断的 varint / 长度越界。
    expect(
      () => ProtobufReader.fieldsOf(Uint8List.fromList(<int>[0x0a, 0xff])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ProtobufReader.fieldsOf(
        Uint8List.fromList(<int>[0x0a, 0x7f, 0x01, 0x02]),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('长度越界'),
        ),
      ),
    );

    // 不支持的分组 wire type（3）——明确报错而不是静默跳过。
    expect(
      () => ProtobufReader.fieldsOf(Uint8List.fromList(<int>[0x0b])),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('wire type'),
        ),
      ),
    );

    // gzip 头但内容损坏：解压失败也要是可读错误。
    expect(
      () => ComicRepoMihonPbParser.parse(
        Uint8List.fromList(<int>[0x1f, 0x8b, 0x00, 0x01, 0x02]),
        baseUri: baseUri,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('gzip'),
        ),
      ),
    );
  });

  test('reader：varint 边界（大数值字段）与字段顺序', () {
    // 来源 id 在真实索引里是 int64（6289731484943316000 量级）。
    final source = _Pb()
      ..intField(1, 6289731484943316000)
      ..string(2, '示例来源')
      ..string(3, 'all');
    final fields = ProtobufReader.fieldsOf(source.toBytes());

    expect(fields[0].number, 1);
    expect(fields[0].varint, 6289731484943316000);
    expect(fields[1].text, '示例来源');
    expect(fields[2].text, 'all');
  });
}

/// 与真实索引同构的样例：Index{1:name, 101:{1:Extension…}}。
Uint8List _sampleIndex({required bool compressed}) {
  final list = _Pb()
    ..message(
      1,
      _Pb()
        ..string(1, '示例扩展')
        ..string(2, 'eu.example.one')
        ..message(
          3,
          _Pb()
            ..string(1, 'https://repo.example/apk/one-v1.2.3.apk')
            ..string(2, 'https://repo.example/icon/one.png'),
        )
        ..string(4, '1.6')
        ..intField(5, 106004)
        ..string(6, '1.2.3')
        ..intField(7, 3)
        ..message(
          8,
          _Pb()
            ..intField(1, 6289731484943316000)
            ..string(2, '示例扩展')
            ..string(3, 'all')
            ..string(4, 'https://one.example'),
        ),
    )
    ..message(
      1,
      _Pb()
        ..string(1, '多来源扩展')
        ..string(2, 'eu.example.multi')
        ..message(3, _Pb()..string(1, 'https://repo.example/apk/multi-v2.0.0.apk'))
        ..string(6, '2.0.0')
        ..intField(7, 3)
        ..message(8, _Pb()..string(2, '来源甲')..string(3, 'zh'))
        ..message(8, _Pb()..string(2, '来源乙')..string(3, 'zh'))
        ..message(8, _Pb()..string(2, '来源丙')..string(3, 'zh'))
        
    );
  final root = _Pb()
    ..string(1, '示例仓库')
    ..string(2, 'DEMO')
    ..string(3, '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2')
    ..message(4, _Pb()..string(1, 'https://repo.example'))
    ..message(101, list);
  final bytes = root.toBytes();
  return compressed ? Uint8List.fromList(gzip.encode(bytes)) : bytes;
}

/// 测试用的极简 protobuf 编码器（只覆盖本用例需要的类型）。
class _Pb {
  final List<int> _bytes = <int>[];

  void _varint(int value) {
    var remaining = value;
    while (remaining > 0x7f) {
      _bytes.add((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.add(remaining & 0x7f);
  }

  void string(int field, String value) {
    final payload = utf8.encode(value);
    _varint((field << 3) | 2);
    _varint(payload.length);
    _bytes.addAll(payload);
  }

  void intField(int field, int value) {
    _varint(field << 3);
    _varint(value);
  }

  void message(int field, _Pb child) {
    final payload = child.toBytes();
    _varint((field << 3) | 2);
    _varint(payload.length);
    _bytes.addAll(payload);
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}
