import '../net/network_cancellation.dart';
import '../net/secure_connection_failure.dart';
import 'source_tools.dart';
import '../player/source_media_runtime.dart';
import '../net/site_session_pool.dart';
import '../net/source_request_log.dart';
import '../session/section.dart';
import 'source_web_runtime.dart';
import 'source_script_storage.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

import '../net/lume_http.dart';
import 'sandbox/sandbox_result.dart';
import 'source_engine.dart';
import 'source_script.dart';
import 'python_local_proxy.dart';

/// Lazy channel: CPython is initialized on its native worker only on first import.
class PythonSourceEngine implements SourceEngine, ScriptConfigCapable {
  PythonSourceEngine({
    required this.sourceId,
    required this.http,
    this.section = Section.video,
  }) {
    _install();
    _clients[_runtimeId] = http;
    _engines[_runtimeId] = this;
  }

  final String sourceId;
  final LumeHttp http;
  final Section section;
  String get _runtimeId =>
      section == Section.video ? sourceId : '${section.id}:$sourceId';
  late final _web = SourceWebRuntime("python:${section.id}:$sourceId");
  late final _storage = SourceScriptStorage(section, sourceId);
  late final _mediaRuntime = SourceMediaRuntime(http);
  static const channel = MethodChannel('lumebox/python_sources');
  static final _clients = <String, LumeHttp>{};
  static final _engines = <String, PythonSourceEngine>{};
  late final _proxy = PythonLocalProxy((request) async {
    final result = await _request(request);
    if (!result.isOk || result.value is! Map) throw StateError('本地代理执行失败');
    return Map<String, dynamic>.from(result.value as Map);
  });
  static bool _installed = false;
  bool _disposed = false;
  bool isPoisoned = false;
  String? _appliedConfig;
  Set<String> _methods = {};
  List<String> _warnings = [];
  SourceMetadata? _metadata;

  @override
  String get id => 'python';
  @override
  String? loadFailure;

  static void _install() {
    if (_installed) return;
    _installed = true;
    channel.setMethodCallHandler((call) {
      final source = call.arguments is Map
          ? (call.arguments as Map)['sourceId']
          : null;
      return NetworkCancellation.runWith(
        _engines[source]?._requestToken,
        () => _handleHost(call),
      );
    });
  }

  static Future<dynamic> _handleHost(MethodCall call) async {
    if (call.method != 'host') throw MissingPluginException();
    try {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final client = _clients[args['sourceId']];
      if (client == null) throw StateError('Python 源已释放');
      final request = jsonDecode(args['request'] as String) as Map;
      final payload = Map<String, dynamic>.from(request['payload'] as Map);
      Object? value;
      if (request['method'] == 'http') {
        final uri = Uri.tryParse('${payload['url']}');
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw const FormatException('Python 源只允许 http(s) 网络请求');
        }
        final response = await client.sendBytes(
          url: uri.toString(),
          method: '${payload['method'] ?? 'GET'}',
          headers: (payload['headers'] as Map?)?.map(
            (k, v) => MapEntry('$k', '$v'),
          ),
          bodyBytes: base64Decode('${payload['body'] ?? ''}'),
          followRedirects: false,
          timeout: Duration(
            milliseconds: ((request['timeout'] as num? ?? 20) * 1000)
                .round()
                .clamp(1, 30000),
          ),
          maxBytes: 8 * 1024 * 1024,
        );
        value = {
          'status': response.statusCode,
          'headers': response.headers,
          'body': base64Encode(response.body),
        };
      } else if (request['method'] == 'tools') {
        value = SourceTools.run(payload);
      } else if (request['method'] == 'media') {
        value = await _engines[args['sourceId']]!._mediaRuntime.invoke(payload);
      } else if (request['method'] == 'session.configure') {
        SiteSessionPool.shared.setUserAgent(
          '${payload['url']}',
          '${payload['userAgent'] ?? ''}',
        );
        await SiteSessionPool.shared.save();
        value = true;
      } else if ('${request['method']}'.startsWith('web.bridge.')) {
        value = await _engines[args['sourceId']]!._web.bridge(
          '${request['method']}'.substring('web.bridge.'.length),
          payload,
        );
      } else if (request['method'] == 'web.render' ||
          request['method'] == 'html.extract') {
        final engine = _engines[args['sourceId']]!;
        if (request['method'] == 'web.render') {
          SourceRequestLog.record(engine.sourceId, '${payload['url']}');
          payload['forceCookies'] =
              (payload['headers'] as Map?)?.keys.any(
                (k) => '$k'.toLowerCase() == 'cookie',
              ) ??
              false;
          final headers = engine.http.browserRequestHeaders(
            (payload['headers'] as Map?)?.map((k, v) => MapEntry('$k', '$v')),
            url: '${payload['url']}',
          );
          payload['headers'] = headers;
          payload.putIfAbsent('userAgent', () => headers['User-Agent']);
          final budget = ((request['timeout'] as num? ?? 8) * 1000 - 250)
              .round()
              .clamp(100, 8000);
          payload['timeoutMs'] =
              ((payload['timeoutMs'] as num?)?.round() ?? 6000).clamp(
                100,
                budget,
              );
        }
        value = await engine._web.invoke(
          request['method'] == 'web.render' ? 'render' : 'extract',
          payload,
        );
        if (request['method'] == 'web.render' && value is Map) {
          SiteSessionPool.shared.rememberSourcePage(
            engine.sourceId,
            '${value['url'] ?? payload['url']}',
          );
        }
      } else if (request['method'] == 'storage') {
        value = await _engines[args['sourceId']]!._storage.invoke(payload);
      } else if (request['method'] == 'proxy') {
        value = await _engines[args['sourceId']]!._proxy.start();
      } else if (request['method'] == 'crypto') {
        value = PythonCrypto.run(payload);
      } else {
        throw const FormatException('不支持的 Python 宿主接口');
      }
      return jsonEncode({'ok': true, 'value': value});
    } catch (error) {
      // Never return request URLs, headers or native exception payloads.
      return jsonEncode({
        'ok': false,
        'error': error is SourceWebVerificationException
            ? error.toString()
            : error is SourceWebFailure
            ? error.toString()
            : error is LumeHttpException
            ? error.message
            : error is FormatException
            ? error.message
            : error is UnsupportedError
            ? error.message
            : error is TimeoutException
            ? '网页操作超时'
            : error is PlatformException
            ? pythonHostPlatformFailure(error)
            : 'Python 宿主请求失败，请检查网络或参数',
      });
    }
  }

  Future<void> _requests = Future<void>.value();
  NetworkCancellation? _requestToken;
  Future<SandboxResult> _request(Map<String, Object?> args) {
    final scope = NetworkCancellation.current;
    final done = Completer<SandboxResult>();
    _requests = _requests.then((_) async {
      if (scope?.isCancelled ?? false) {
        done.complete(const SandboxFailure(SandboxErrorKind.disposed, '请求已取消'));
        return;
      }
      _requestToken = scope;
      try {
        done.complete(await _executeRequest(args));
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _requestToken = null;
      }
    });
    return done.future;
  }

  Future<SandboxResult> _executeRequest(Map<String, Object?> args) async {
    if (_disposed) {
      return const SandboxFailure(SandboxErrorKind.disposed, 'Python 源已释放');
    }
    final config = args['action'] == 'config'
        ? jsonEncode(args['config'])
        : null;
    if (!isPoisoned && config != null && config == _appliedConfig) {
      return const SandboxSuccess(null);
    }
    if (args['action'] == 'load') _appliedConfig = null;
    try {
      final reply = await channel
          .invokeMethod<String>('execute', {...args, 'sourceId': _runtimeId})
          .timeout(const Duration(seconds: 65));
      final result = SandboxResult.fromJson(reply ?? '');
      if (result.isOk && config != null) _appliedConfig = config;
      if (result.error?.kind.poisonsContext ?? false) isPoisoned = true;
      return result;
    } on MissingPluginException {
      return const SandboxFailure(
        SandboxErrorKind.unsupported,
        '此安装包未包含 Python 运行环境',
      );
    } on TimeoutException {
      isPoisoned = true;
      return const SandboxFailure(
        SandboxErrorKind.timeout,
        'Python 源执行超时，请重新选择',
      );
    } on PlatformException catch (error) {
      return SandboxFailure(
        SandboxErrorKind.engine,
        error.message ?? 'Python 运行环境不可用',
      );
    }
  }

  @override
  Future<bool> loadScript(String script) async {
    _metadata = SourceMetadata.parseHeader(script);
    final result = await _request({
      'action': 'load',
      'script': script,
      'section': section.id,
      'timeout': 15,
    });
    if (!result.isOk) {
      loadFailure = result.error?.message;
      return false;
    }
    final value = result.value;
    _methods = value is Map && value['methods'] is List
        ? (value['methods'] as List).cast<String>().toSet()
        : {};
    _warnings = value is Map && value['warnings'] is List
        ? (value['warnings'] as List).map((e) => '$e').toList()
        : [];
    loadFailure = null;
    return true;
  }

  @override
  Future<Set<String>?> contractMethods() async => Set.of(_methods);
  @override
  Future<Map<String, Object?>?> metadata() async => _metadata == null
      ? null
      : {
          'id': _metadata!.id,
          'name': _metadata!.name,
          'version': _metadata!.version,
          'category': _metadata!.category.isEmpty
              ? section.id
              : _metadata!.category,
          'compatibilityWarnings': _warnings,
        };
  @override
  Future<void> applyScriptConfig(Map<String, Object?> config) async {
    final result = await _request({'action': 'config', 'config': config});
    if (!result.isOk) throw StateError(result.error!.message);
  }

  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) =>
      _request({
        'action': 'call',
        'method': method,
        'argument': argument,
        'timeout': 30,
      });
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _web.dispose();
    _mediaRuntime.dispose();
    _storage.dispose();
    _proxy.dispose();
    _clients.remove(_runtimeId);
    _engines.remove(_runtimeId);
    unawaited(
      channel
          .invokeMethod<String>('execute', {
            'action': 'dispose',
            'sourceId': _runtimeId,
          })
          .catchError((Object _) => null),
    );
  }
}

/// AES without padding, authenticated AES-GCM and (X)ChaCha20-Poly1305.
class PythonCrypto {
  static String run(Map<String, dynamic> payload) {
    Uint8List bytes(String key) => base64Decode('${payload[key] ?? ''}');
    var key = bytes('key');
    final data = bytes('data');
    final encrypt = payload['encrypt'] == true;
    final algorithm = payload['algorithm'];
    final mode = payload['mode'];
    if (data.length > 8 * 1024 * 1024) throw const FormatException('加密数据过大');
    if (algorithm == 'aes' && [3, 5, 6].contains(mode)) {
      final iv = bytes('iv');
      if (![16, 24, 32].contains(key.length) || iv.length != 16) {
        throw const FormatException('AES 密钥或 IV 长度不正确');
      }
      if (mode == 6) {
        final cipher = SICStreamCipher(AESEngine())
          ..init(encrypt, ParametersWithIV(KeyParameter(key), iv));
        return base64Encode(cipher.process(data));
      }
      final bits = mode == 3 ? (payload['segmentSize'] as int? ?? 8) : 128;
      if (bits < 8 || bits > 128 || bits % 8 != 0) {
        throw const FormatException('AES CFB segment_size 应为 8 的倍数且不超过 128');
      }
      final size = bits ~/ 8;
      final cipher = mode == 3
          ? CFBBlockCipher(AESEngine(), size)
          : OFBBlockCipher(AESEngine(), size);
      cipher.init(encrypt, ParametersWithIV(KeyParameter(key), iv));
      final padded = Uint8List(((data.length + size - 1) ~/ size) * size)
        ..setRange(0, data.length, data);
      final result = Uint8List(padded.length);
      for (var offset = 0; offset < padded.length; offset += size) {
        cipher.processBlock(padded, offset, result, offset);
      }
      return base64Encode(Uint8List.sublistView(result, 0, data.length));
    }
    if (algorithm == 'aes' && (mode == 1 || mode == 2)) {
      if (![16, 24, 32].contains(key.length) || data.length % 16 != 0) {
        throw const FormatException('AES 密钥或数据长度不正确');
      }
      final cipher = mode == 1
          ? ECBBlockCipher(AESEngine())
          : CBCBlockCipher(AESEngine());
      final iv = bytes('iv');
      if (mode == 2 && iv.length != 16) {
        throw const FormatException('AES IV 长度不正确');
      }
      cipher.init(
        encrypt,
        mode == 1 ? KeyParameter(key) : ParametersWithIV(KeyParameter(key), iv),
      );
      final result = Uint8List(data.length);
      for (var i = 0; i < data.length; i += 16) {
        cipher.processBlock(data, i, result, i);
      }
      return base64Encode(result);
    }
    var nonce = bytes('nonce');
    final aad = bytes('aad');
    if (algorithm == 'aes' && mode == 11) {
      if (![16, 24, 32].contains(key.length)) {
        throw const FormatException('AES 密钥长度不正确');
      }
      final cipher = GCMBlockCipher(AESEngine())
        ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
      return base64Encode(cipher.process(data));
    } else if (algorithm == 'chacha') {
      if (key.length != 32 || ![12, 24].contains(nonce.length)) {
        throw const FormatException('ChaCha 密钥或 nonce 长度不正确');
      }
      if (nonce.length == 24) {
        key = _hChaCha(key, Uint8List.sublistView(nonce, 0, 16));
        nonce = Uint8List.fromList([0, 0, 0, 0, ...nonce.sublist(16)]);
      }
      final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
        ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
      final output = Uint8List(cipher.getOutputSize(data.length));
      final written = cipher.processBytes(data, 0, data.length, output, 0);
      final tail = cipher.doFinal(output, written);
      return base64Encode(Uint8List.sublistView(output, 0, written + tail));
    } else {
      throw const FormatException(
        'Python 加密接口支持 AES ECB/CBC/CFB/OFB/CTR/GCM 与 ChaCha20-Poly1305',
      );
    }
  }

  static Uint8List _hChaCha(Uint8List key, Uint8List nonce) {
    final input = ByteData.sublistView(
      Uint8List.fromList([
        ...ascii.encode('expand 32-byte k'),
        ...key,
        ...nonce,
      ]),
    );
    final x = List.generate(16, (i) => input.getUint32(i * 4, Endian.little));
    int rot(int n, int bits) => ((n << bits) | (n >> (32 - bits))) & 0xffffffff;
    void quarter(int a, int b, int c, int d) {
      x[a] = (x[a] + x[b]) & 0xffffffff;
      x[d] = rot(x[d] ^ x[a], 16);
      x[c] = (x[c] + x[d]) & 0xffffffff;
      x[b] = rot(x[b] ^ x[c], 12);
      x[a] = (x[a] + x[b]) & 0xffffffff;
      x[d] = rot(x[d] ^ x[a], 8);
      x[c] = (x[c] + x[d]) & 0xffffffff;
      x[b] = rot(x[b] ^ x[c], 7);
    }

    for (var i = 0; i < 10; i++) {
      quarter(0, 4, 8, 12);
      quarter(1, 5, 9, 13);
      quarter(2, 6, 10, 14);
      quarter(3, 7, 11, 15);
      quarter(0, 5, 10, 15);
      quarter(1, 6, 11, 12);
      quarter(2, 7, 8, 13);
      quarter(3, 4, 9, 14);
    }
    final out = ByteData(32);
    final words = [0, 1, 2, 3, 12, 13, 14, 15];
    for (var i = 0; i < words.length; i++) {
      out.setUint32(i * 4, x[words[i]], Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
