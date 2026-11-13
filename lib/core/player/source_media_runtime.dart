import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../net/lume_http.dart';
import '../net/http_header_scope.dart';
import '../net/site_session_pool.dart';
import '../js/source_tools.dart';

class SourceMediaRuntime {
  SourceMediaRuntime(this.http);
  final LumeHttp http;
  final Map<String, ({DateTime expires, Uint8List value})> _keys = {};
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _keys.clear();
  }

  static Uri address(String raw, Uri base) {
    final uri = base.resolve(raw);
    if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
      throw const FormatException('媒体资源仅支持 HTTP(S)');
    }
    return uri;
  }

  static Map<String, String> attributes(String line) => {
    for (final m in RegExp(
      r'([A-Z0-9-]+)=("[^" ]*(?: [^"]*)?"|[^,]*)',
    ).allMatches(line))
      m[1]!: m[2]!.replaceAll(RegExp(r'^"|"$'), ''),
  };
  static Map<String, Object?> parseM3u8(String text, Uri base) {
    if (text.length > 1024 * 1024 || !text.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('M3U8 清单无效或过大');
    }
    final segments = <Map<String, Object?>>[];
    final variants = <Map<String, Object?>>[];
    var sequence = 0;
    var duration = 0.0;
    var discontinuity = false;
    Map<String, Object?>? key;
    Map<String, Object?>? init;
    Map<String, String>? variant;
    String? range;
    var endList = false;
    final rangeEnds = <String, int>{};
    for (final line in text.split('\n').map((x) => x.trim())) {
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.parse(line.split(':').last);
        if (sequence < 0) throw const FormatException('媒体序号无效');
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final a = attributes(line);
        if (a['METHOD'] == 'NONE') {
          key = null;
          continue;
        }
        if (a['METHOD'] != 'AES-128' ||
            (a['KEYFORMAT'] ?? 'identity') != 'identity') {
          throw const FormatException(
            '仅支持标准 identity AES-128；不处理 DRM／SAMPLE-AES',
          );
        }
        if (a['URI'] == null) throw const FormatException('缺少 AES 密钥地址');
        key = {
          'url': address(a['URI']!, base).toString(),
          'keySequence': sequence + segments.length,
          if (a['IV'] != null) 'iv': a['IV'],
        };
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final a = attributes(line);
        if (a['URI'] == null) throw const FormatException('初始化片段缺少 URI');
        if (key != null && key['iv'] == null) {
          throw const FormatException('加密 EXT-X-MAP 必须声明 IV');
        }
        init = {
          'url': address(a['URI']!, base).toString(),
          if (a['BYTERANGE'] != null) 'byteRange': a['BYTERANGE'],
          if (key != null) 'key': Map.of(key),
        };
      } else if (line.startsWith('#EXTINF:')) {
        duration = double.parse(line.substring(8).split(',').first);
        if (!duration.isFinite || duration < 0) {
          throw const FormatException('分片时长无效');
        }
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        variant = attributes(line);
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        range = line.split(':').last;
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuity = true;
      } else if (line == '#EXT-X-ENDLIST') {
        endList = true;
      } else if (!line.startsWith('#')) {
        final url = address(line, base).toString();
        if (variant != null) {
          variants.add({'url': url, ...variant});
          variant = null;
          continue;
        }
        Map<String, int>? byteRange;
        if (range != null) {
          final parts = range.split('@');
          final length = int.parse(parts.first);
          final start = parts.length == 2
              ? int.parse(parts.last)
              : rangeEnds[url];
          if (length <= 0 || start == null || start < 0) {
            throw const FormatException('分片字节范围无效');
          }
          byteRange = {'start': start, 'length': length};
          rangeEnds[url] = start + length;
          range = null;
        }
        final number = sequence + segments.length;
        final rawIV = '${key?['iv'] ?? number.toRadixString(16)}'.replaceFirst(
          RegExp(r'^0[xX]'),
          '',
        );
        if (key != null && (!RegExp(r'^[0-9a-fA-F]{1,32}$').hasMatch(rawIV))) {
          throw const FormatException('AES IV 无效');
        }
        segments.add({
          'url': url,
          'sequence': number,
          'duration': duration,
          'discontinuity': discontinuity,
          'byteRange': ?byteRange,
          'init': ?init,
          if (key != null) 'key': {...key, 'iv': rawIV.padLeft(32, '0')},
        });
        duration = 0;
        discontinuity = false;
        if (segments.length > 10000) throw const FormatException('分片数量过大');
      }
    }
    return {
      'url': base.toString(),
      'variants': variants,
      'segments': segments,
      'endList': endList,
    };
  }

  static Map<String, Object?> inspectFlv(Uint8List bytes) {
    if (bytes.length < 13 ||
        ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'FLV' ||
        bytes[3] != 1) {
      throw const FormatException('FLV 文件头无效');
    }
    final data = ByteData.sublistView(bytes);
    var offset = data.getUint32(5) + 4;
    if (offset < 13 || offset > bytes.length) {
      throw const FormatException('FLV 数据偏移无效');
    }
    int u24(int i) => (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    final tags = <Map<String, Object?>>[];
    while (offset + 11 <= bytes.length && tags.length < 256) {
      final size = u24(offset + 1);
      if (offset + 11 + size + 4 > bytes.length) break;
      final type = bytes[offset] & 31;
      final timestamp = u24(offset + 4) | (bytes[offset + 7] << 24);
      if (data.getUint32(offset + 11 + size) != size + 11) {
        throw const FormatException('FLV tag 长度校验失败');
      }
      tags.add({
        'type': type,
        'timestampMs': timestamp,
        'size': size,
        if (size > 0 && type == 9) 'videoCodec': bytes[offset + 11] & 15,
        if (size > 0 && type == 8) 'audioCodec': bytes[offset + 11] >> 4,
      });
      offset += 11 + size + 4;
    }
    return {
      'hasAudio': bytes[4] & 4 != 0,
      'hasVideo': bytes[4] & 1 != 0,
      'tags': tags,
      'parsedBytes': offset,
    };
  }

  Future<Object?> invoke(Map<String, dynamic> p) async {
    if (_disposed) throw StateError('媒体会话已关闭');
    final uri = Uri.parse('${p['url']}');
    final headers = SiteSessionPool.shared.headersFor(
      uri.toString(),
      (p['headers'] as Map? ?? {}).map((k, v) => MapEntry('$k', '$v')),
      referer: p['referer'] as String?,
    );
    if (p['operation'] == 'parseM3u8') return parseM3u8('${p['text']}', uri);
    if (p['operation'] == 'inspectFlv') {
      return inspectFlv(base64Decode('${p['data']}'));
    }
    final response = await http.send(
      url: uri.toString(),
      headers: headers,
      maxBytes: 1024 * 1024 + 1,
    );
    if (response.statusCode != 200) {
      throw StateError('媒体清单 HTTP ${response.statusCode}');
    }
    final playlist = parseM3u8(
      response.text,
      Uri.parse(response.url ?? uri.toString()),
    );
    if (p['operation'] == 'playlist') return playlist;
    if (p['operation'] != 'segment') throw const FormatException('媒体操作无效');
    final segments = playlist['segments'] as List;
    final index = p['index'];
    if (index is! int || index < 0 || index >= segments.length) {
      throw const FormatException('分片序号无效，请使用媒体清单地址');
    }
    final segment = segments[index] as Map;
    var outgoing = Map<String, String>.of(headers);
    // Do not forward playlist cookies to a CDN. Its own scoped session is used.
    final segmentURL = Uri.parse(segment['url'] as String);
    if (segmentURL.origin != uri.origin) {
      outgoing.removeWhere((key, _) => isOriginBoundHttpHeader(key));
    }
    outgoing = SiteSessionPool.shared.headersFor(
      segmentURL.toString(),
      outgoing,
      referer: uri.toString(),
    );
    final range = segment['byteRange'] as Map?;
    if (range != null) {
      outgoing['Range'] =
          'bytes=${range['start']}-${(range['start'] as int) + (range['length'] as int) - 1}';
    }
    final data = await http.send(
      url: segmentURL.toString(),
      headers: outgoing,
      maxBytes: 16 * 1024 * 1024 + 1,
    );
    if (![200, 206].contains(data.statusCode) ||
        data.body.length > 16 * 1024 * 1024) {
      throw StateError('分片加载失败 HTTP ${data.statusCode}');
    }
    if (range != null &&
        (data.statusCode != 206 || data.body.length != range['length'])) {
      throw const FormatException('服务器未遵守分片 Range');
    }
    var output = data.body;
    if (segment['key'] is Map) {
      final encryption = segment['key'] as Map;
      final keyURL = Uri.parse(encryption['url'] as String);
      var keyHeaders = Map<String, String>.of(headers);
      if (keyURL.origin != uri.origin) {
        keyHeaders.removeWhere((key, _) => isOriginBoundHttpHeader(key));
      }
      keyHeaders = SiteSessionPool.shared.headersFor(
        keyURL.toString(),
        keyHeaders,
        referer: uri.toString(),
      );
      final fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                keyURL.toString(),
                encryption['keySequence'],
                keyHeaders,
              ]),
            ),
          )
          .toString();
      var cached = _keys[fingerprint];
      if (cached == null || cached.expires.isBefore(DateTime.now())) {
        final result = await http.send(
          url: keyURL.toString(),
          headers: keyHeaders,
          maxBytes: 17,
        );
        if (result.statusCode != 200 || result.body.length != 16) {
          throw const FormatException('AES-128 密钥必须为 16 字节');
        }
        if (_disposed) throw StateError('媒体会话已关闭');
        if (_keys.length >= 8) _keys.remove(_keys.keys.first);
        cached = (
          expires: DateTime.now().add(const Duration(minutes: 5)),
          value: result.body,
        );
        _keys[fingerprint] = cached;
      }
      final iv = '${encryption['iv']}';
      output = base64Decode(
        SourceTools.run({
          'operation': 'aes',
          'encrypt': false,
          'mode': 'CBC',
          'key': base64Encode(cached.value),
          'iv': base64Encode(
            List.generate(
              16,
              (i) => int.parse(iv.substring(i * 2, i * 2 + 2), radix: 16),
            ),
          ),
          'data': base64Encode(output),
        }) as String,
      );
    }
    if (_disposed) throw StateError('媒体会话已关闭');
    return {'data': base64Encode(output), 'segment': segment};
  }
}
