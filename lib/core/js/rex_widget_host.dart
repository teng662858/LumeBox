import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cache/section_memory_cache.dart';
import '../net/lume_http.dart';
import '../net/waf.dart';
import '../reading/reading_library.dart';
import '../session/section.dart';
import '../tmdb/tmdb.dart';
import 'sandbox/sandbox_host.dart';

/// Persistent Widget data is separate from LumeSource.fs and excluded from backups.
class RexWidgetSettings {
  static const prefix = 'rex.widget.';
  static String _params(String id) => '${prefix}params.$id';
  static String _definitions(String id) => '${prefix}definitions.$id';

  static Map<String, Object?> parameters(Section section, String id) {
    final raw = ReadingLibrary.find(section)?.setting(_params(id));
    if (raw == null) return {};
    final value = jsonDecode(raw);
    return value is Map ? Map<String, Object?>.from(value) : {};
  }

  static List<Map<String, Object?>> definitions(Section section, String id) {
    final raw = ReadingLibrary.find(section)?.setting(_definitions(id));
    if (raw == null) return [];
    final value = jsonDecode(raw);
    return value is List
        ? value
              .whereType<Map>()
              .map((e) => Map<String, Object?>.from(e))
              .toList()
        : [];
  }

  static Future<void> saveParameters(
    Section section,
    String id,
    Map<String, Object?> values,
  ) async {
    final text = jsonEncode(values);
    if (utf8.encode(text).length > 128 * 1024) {
      throw const FormatException('Widget 参数合计不能超过 128KB');
    }
    final library = await ReadingLibrary.open(section);
    if (library.setting(_params(id)) == text) return;
    library.setSetting(_params(id), text);
    SectionMemoryCache.instance.removeSource(section, id);
  }

  static Future<void> saveDefinitions(
    Section section,
    String id,
    Object? definitions,
  ) async {
    if (definitions is! List) return;
    final text = jsonEncode(definitions);
    if (utf8.encode(text).length > 128 * 1024) {
      throw const FormatException('Widget 参数声明超过 128KB');
    }
    (await ReadingLibrary.open(section)).setSetting(_definitions(id), text);
  }
}

class RexWidgetHost {
  RexWidgetHost(this.http, this.section, this.sourceId, this.timeout);
  final LumeHttp http;
  final Section section;
  final String sourceId;
  final Duration timeout;
  static const maxBytes = 8 * 1024 * 1024;
  static const maxStorageBytes = 2 * 1024 * 1024;
  String get _privateKey => '${RexWidgetSettings.prefix}private.$sourceId';
  String get _sharedKey => '${RexWidgetSettings.prefix}shared';

  Future<Object?> invoke(String method, Object? payload) async =>
      switch (method) {
        'rex.state' => snapshot(),
        'rex.store' => _store(payload),
        'rex.request' => _request(payload),
        'rex.tmdb' => _tmdb(payload),
        _ => throw SandboxHostException('未实现的 Widget 宿主方法：$method'),
      };

  Map<String, Object?> _records(ReadingLibrary library, String key) {
    final raw = library.setting(key);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final now = DateTime.now().millisecondsSinceEpoch;
    final records = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.value is! Map) continue;
      final expires = entry.value['expires'];
      if (expires == null || expires == 0 || expires is num && expires > now) {
        records['${entry.key}'] = entry.value;
      }
    }
    return records;
  }

  Future<Map<String, Object?>> snapshot() async {
    final library = await ReadingLibrary.open(section);
    Map<String, Object?> values(String key) => _records(
      library,
      key,
    ).map((key, value) => MapEntry(key, (value as Map)['value']));
    return {
      'private': values(_privateKey),
      'shared': values(_sharedKey),
      'params': RexWidgetSettings.parameters(section, sourceId),
      'language': Platform.localeName.replaceAll('_', '-'),
    };
  }

  Future<Object?> _store(Object? payload) async {
    if (payload is! Map || payload['operations'] is! List) {
      throw const SandboxHostException('Widget 存储操作必须是数组');
    }
    final operations = payload['operations'] as List;
    if (operations.length > 512) {
      throw const SandboxHostException('Widget 单次写入超过 512 项');
    }
    final library = await ReadingLibrary.open(section);
    final local = _records(library, _privateKey),
        shared = _records(library, _sharedKey);
    for (final operation in operations) {
      if (operation is! Map ||
          !['private', 'shared'].contains(operation['area'])) {
        throw const SandboxHostException('Widget 存储空间无效');
      }
      final target = operation['area'] == 'shared' ? shared : local;
      final op = operation['op'];
      if (op == 'clear' && operation['area'] == 'private') {
        target.clear();
        continue;
      }
      final key = '${operation['key'] ?? ''}';
      if (key.isEmpty || key.length > 1024) {
        throw const SandboxHostException('Widget 存储键为空或超过 1024 字符');
      }
      if (op == 'remove') {
        target.remove(key);
        continue;
      }
      if (op != 'set') throw const SandboxHostException('Widget 存储操作无效');
      final ttl = operation['ttl'];
      final seconds = ttl is num && ttl.isFinite && ttl > 0
          ? ttl.clamp(1, 31536000).toInt()
          : 0;
      target[key] = {
        'value': operation['value'],
        'expires': seconds == 0
            ? 0
            : DateTime.now().millisecondsSinceEpoch + seconds * 1000,
      };
    }
    final privateJson = jsonEncode(local), sharedJson = jsonEncode(shared);
    if (local.length > 512 ||
        shared.length > 512 ||
        utf8.encode(privateJson).length > maxStorageBytes ||
        utf8.encode(sharedJson).length > maxStorageBytes) {
      throw const SandboxHostException('Widget 存储超出 512 项或 2MB 上限');
    }
    // Validate both areas before committing; apply only changed keys, so other
    // runtimes do not lose concurrent changes when their snapshots are older.
    library.setSetting(_privateKey, privateJson);
    library.setSetting(_sharedKey, sharedJson);
    return {'ok': true};
  }

  static Map<String, String> _strings(Object? value) =>
      value is Map ? value.map((k, v) => MapEntry('$k', '$v')) : {};

  Future<Map<String, Object?>> _request(Object? payload) async {
    if (payload is! Map) throw const SandboxHostException('Widget 请求入参必须是对象');
    var uri = Uri.tryParse('${payload['url'] ?? ''}');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const SandboxHostException('Widget 请求需要有效 HTTP(S) 地址');
    }
    final params = payload['params'];
    if (params is Map) {
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParametersAll,
          for (final e in params.entries)
            if (e.value != null)
              '${e.key}': e.value is List
                  ? (e.value as List).map((v) => '$v').toList()
                  : '${e.value}',
        },
      );
    }
    final headers = _strings(payload['headers']);
    final data = payload['data'] ?? payload['body'];
    final type =
        headers.entries
            .where((e) => e.key.toLowerCase() == 'content-type')
            .firstOrNull
            ?.value ??
        '';
    String? body;
    if (data != null) {
      if (data is String) {
        body = data;
      } else if (data is Map &&
          type.contains('application/x-www-form-urlencoded')) {
        body = Uri(queryParameters: _strings(data)).query;
      } else {
        body = jsonEncode(data);
        if (type.isEmpty) headers['Content-Type'] = 'application/json';
      }
    }
    final requestedTimeout = payload['timeout'];
    final budget = requestedTimeout is num && requestedTimeout.isFinite
        ? Duration(
            milliseconds: requestedTimeout.toInt().clamp(
              100,
              timeout.inMilliseconds,
            ),
          )
        : timeout;
    final response = await http.sendBytes(
      url: uri.toString(),
      method: '${payload['method'] ?? 'GET'}',
      headers: headers,
      bodyBytes: body == null ? null : utf8.encode(body),
      followRedirects: payload['allow_redirects'] != false,
      timeout: budget,
      maxBytes: maxBytes,
    );
    var bytes = response.body;
    if (WafDetector.isChallenge(
      statusCode: response.statusCode,
      headers: response.headers,
      body: utf8.decode(bytes.take(128 * 1024).toList(), allowMalformed: true),
    )) {
      throw SandboxHostException('NEED_WEBVIEW_VERIFY：${uri.origin} WAF 人机验证');
    }
    if (payload['zlibMode'] == true) {
      final sink = _BoundedWidgetBytes(maxBytes);
      final decoder = ZLibDecoder().startChunkedConversion(sink);
      decoder.add(bytes);
      decoder.close();
      bytes = sink.bytes;
    }
    Object? result;
    if (payload['base64Data'] == true) {
      result = base64Encode(bytes);
    } else {
      final text = utf8.decode(bytes, allowMalformed: true);
      result = text;
      if (payload['decodable'] != false) {
        try {
          result = jsonDecode(text);
        } on FormatException {
          /* Plain text responses stay text. */
        }
      }
    }
    return {
      'data': result,
      'statusCode': response.statusCode,
      'status': response.statusCode,
      'headers': response.headers,
    };
  }

  Future<Object?> _tmdb(Object? payload) async {
    if (payload is! Map) {
      throw const SandboxHostException('Widget TMDB 入参必须是对象');
    }
    final settings = TmdbSettings.instance;
    if (!settings.configured) {
      throw const SandboxHostException('请先启用 TMDB 并填写 API Key');
    }
    final endpoint = Uri.tryParse('${payload['api'] ?? ''}');
    if (endpoint == null ||
        endpoint.hasScheme ||
        endpoint.hasAuthority ||
        endpoint.path.split('/').contains('..')) {
      throw const SandboxHostException('Widget TMDB 仅接受相对 API 路径');
    }
    final path = endpoint.path
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceFirst(RegExp(r'^3/'), '');
    final uri = settings.apiUri(
      path,
      query: {...endpoint.queryParameters, ..._strings(payload['params'])},
    );
    final response = await http.send(
      url: uri.toString(),
      timeout: timeout,
      maxBytes: maxBytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SandboxHostException('TMDB HTTP ${response.statusCode}');
    }
    return jsonDecode(response.text);
  }
}

class _BoundedWidgetBytes extends ByteConversionSink {
  _BoundedWidgetBytes(this.limit);
  final int limit;
  final _builder = BytesBuilder(copy: false);
  Uint8List get bytes => _builder.takeBytes();
  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > limit) {
      throw const SandboxHostException('Widget 解压响应超过 8MB');
    }
    _builder.add(chunk);
  }

  @override
  void close() {}
}
