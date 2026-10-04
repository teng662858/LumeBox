import 'dart:convert';
import 'dart:typed_data';

/// 极简 protobuf **读取器**（只读、无 schema）。
///
/// 用途只有一个：读 Mihon / Tachiyomi 仓库的 `index.pb`。为一个索引文件引入
/// 完整的 protobuf 运行时并不划算，而这里需要的协议面很小（varint +
/// 长度前缀字段），实现固定、可测，字段号由解析器显式声明。
///
/// 只支持 wire type 0（varint）/ 1（64 位）/ 2（长度前缀）/ 5（32 位）；
/// 遇到分组（3 / 4）或越界一律抛 [FormatException]（可读原因，不做静默容错）。
class ProtobufReader {
  ProtobufReader(this._bytes, [this._offset = 0]);

  final Uint8List _bytes;
  int _offset;

  bool get isDone => _offset >= _bytes.length;

  int get remaining => _bytes.length - _offset;

  /// 读完整个缓冲区，返回按出现顺序排列的字段列表。
  static List<ProtobufField> fieldsOf(Uint8List bytes) =>
      ProtobufReader(bytes).readAll();

  List<ProtobufField> readAll() {
    final fields = <ProtobufField>[];
    while (!isDone) {
      fields.add(_readField());
    }
    return fields;
  }

  ProtobufField _readField() {
    final tag = _readVarint();
    final number = tag >> 3;
    final wireType = tag & 0x07;
    if (number <= 0) {
      throw FormatException('protobuf 字段号非法：$number');
    }
    switch (wireType) {
      case 0:
        return ProtobufField(
          number: number,
          wireType: wireType,
          varint: _readVarint(),
        );
      case 1:
        _skip(8);
        return ProtobufField(number: number, wireType: wireType);
      case 2:
        final length = _readVarint();
        if (length < 0 || length > remaining) {
          throw FormatException(
            'protobuf 长度越界（字段 $number 声明 $length 字节，剩余 $remaining）',
          );
        }
        final view = Uint8List.sublistView(_bytes, _offset, _offset + length);
        _offset += length;
        return ProtobufField(number: number, wireType: wireType, bytes: view);
      case 5:
        _skip(4);
        return ProtobufField(number: number, wireType: wireType);
      default:
        throw FormatException('不支持的 protobuf wire type：$wireType（字段 $number）');
    }
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (isDone) {
        throw const FormatException('protobuf 数据提前结束（varint 未闭合）');
      }
      final byte = _bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('protobuf varint 超过 64 位');
      }
    }
  }

  void _skip(int count) {
    if (count > remaining) {
      throw const FormatException('protobuf 数据提前结束（定长字段越界）');
    }
    _offset += count;
  }
}

/// 一个已读出的字段。`varint` / `bytes` 取决于 wire type。
class ProtobufField {
  const ProtobufField({
    required this.number,
    required this.wireType,
    this.varint,
    this.bytes,
  });

  final int number;
  final int wireType;

  /// wire type 0 的数值。
  final int? varint;

  /// wire type 2 的载荷（长度前缀字段：嵌套消息或字符串）。
  final Uint8List? bytes;

  /// 把载荷按 UTF-8 文本读；非文本载荷返回 null。
  String? get text {
    final payload = bytes;
    if (payload == null) return null;
    return const Utf8Decoder(allowMalformed: true).convert(payload);
  }
}
