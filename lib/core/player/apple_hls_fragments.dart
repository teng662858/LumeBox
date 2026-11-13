import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/services.dart';

import '../net/http_byte_range.dart';

const transportStreamProbeLength = 65536 + 188 * 3 + 4;
const _pngHeader = [137, 80, 78, 71, 13, 10, 26, 10];

/// A PNG prefix is removed only after four aligned, plaintext MPEG-TS packets
/// have been confirmed. Encrypted segments and real images stay unchanged.
int transportStreamImagePrefix(List<int> bytes) {
  if (bytes.length < 8) return 0;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngHeader[i]) return 0;
  }
  final limit = (bytes.length - 188 * 3 - 4).clamp(0, 65536);
  for (var offset = 8; offset <= limit; offset++) {
    var valid = true;
    for (var packet = 0; packet < 4; packet++) {
      final at = offset + packet * 188;
      if (bytes[at] != 0x47 || bytes[at + 3] & 0x30 == 0) {
        valid = false;
        break;
      }
    }
    if (valid) return offset;
  }
  return 0;
}

Stream<List<int>> unwrapTransportStream(Stream<List<int>> input) async* {
  final prefix = BytesBuilder(copy: false);
  var probing = true;
  await for (final chunk in input) {
    if (!probing) {
      yield chunk;
      continue;
    }
    final count = (transportStreamProbeLength - prefix.length).clamp(0, chunk.length);
    final start = prefix.length;
    prefix.add(count == chunk.length ? chunk : chunk.sublist(0, count));
    for (var i = start; i < _pngHeader.length && i < prefix.length; i++) {
      if (chunk[i - start] != _pngHeader[i]) {
        probing = false;
        break;
      }
    }
    if (probing && prefix.length < transportStreamProbeLength) continue;
    final bytes = prefix.takeBytes();
    yield Uint8List.sublistView(bytes, probing ? transportStreamImagePrefix(bytes) : 0);
    probing = false;
    if (count < chunk.length) yield chunk.sublist(count);
  }
  if (prefix.isNotEmpty) {
    final bytes = prefix.takeBytes();
    yield Uint8List.sublistView(bytes, transportStreamImagePrefix(bytes));
  }
}

/// MPEG-TS program map stream type 0x24 identifies HEVC without guessing from
/// the URL or mistaking H.264, encrypted samples or fMP4 for transport streams.
bool transportStreamHasHevc(Uint8List bytes) {
  for (var packet = 0; packet + 188 <= bytes.length; packet += 188) {
    if (bytes[packet] != 0x47) return false;
    if (bytes[packet + 1] & 0x40 == 0 || bytes[packet + 3] & 0x10 == 0) {
      continue;
    }
    final end = packet + 188;
    var pos = packet + 4;
    if (bytes[packet + 3] & 0x20 != 0) pos += 1 + bytes[pos];
    if (pos >= end) continue;
    pos += 1 + bytes[pos];
    if (pos + 12 > end || bytes[pos] != 2 || bytes[pos + 1] & 0xf0 != 0xb0) {
      continue;
    }
    final crc = pos + 3 + ((bytes[pos + 1] & 15) << 8 | bytes[pos + 2]) - 4;
    var stream = pos + 12 + ((bytes[pos + 10] & 15) << 8 | bytes[pos + 11]);
    while (stream + 5 <= crc && stream + 5 <= end) {
      if (bytes[stream] == 0x24) return true;
      stream += 5 + ((bytes[stream + 3] & 15) << 8 | bytes[stream + 4]);
    }
  }
  return false;
}

/// Serial conversion bounds transient native/Dart buffers during seeks. The
/// init and media URLs for a segment share a single stream copy.
class AppleHlsFragments {
  static const maxSegmentBytes = 32 * 1024 * 1024;
  final _pending = <String, Future<Uint8List>>{};
  Future<void> _queue = Future.value();
  String? _lastKey;
  Uint8List? _last;

  Future<Uint8List> get(
    String key,
    int sequence,
    bool init,
    Future<Uint8List> Function() read,
  ) async {
    final cached = _lastKey == key ? _last : null;
    final bytes =
        cached ??
        await _pending.putIfAbsent(key, () {
          final job = _queue
              .then((_) async {
                final input = await read();
                final output = await const MethodChannel('lumebox/video_remux')
                    .invokeMethod<Uint8List>('fragment', {
                      'input': input,
                      'sequence': sequence,
                    });
                if (output == null) throw const FormatException('无法封装 HEVC 分片');
                _lastKey = key;
                _last = output;
                return output;
              })
              .whenComplete(() {
                _pending.remove(key);
              });
          _queue = job.then<void>((_) {}, onError: (Object _) {});
          return job;
        });
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 8 <= bytes.length) {
      final size = data.getUint32(offset);
      if (size < 8 || offset + size > bytes.length) break;
      if (data.getUint32(offset + 4) == 0x6d6f6f66 && offset > 0) {
        return init
            ? Uint8List.sublistView(bytes, 0, offset)
            : Uint8List.sublistView(bytes, offset);
      }
      offset += size;
    }
    throw const FormatException('缺少 MP4 媒体片段');
  }

  static void serve(HttpRequest request, Uint8List bytes) =>
      serveHttpBytes(request, bytes, 'video/mp4');
}
