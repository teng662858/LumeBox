import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Source-owned HTTP endpoint. AVPlayer/media_kit can request the returned URL
/// without passing through the Spider network callback again.
class PythonLocalProxy {
  PythonLocalProxy(this.invoke);
  final Future<Map<String, dynamic>> Function(Map<String, Object?> request)
  invoke;
  HttpServer? _server;
  Future<String>? _starting;
  bool _disposed = false;
  final _token = base64UrlEncode(
    List.generate(24, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');

  Future<String> start() => _starting ??= _start();
  Future<String> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_disposed) {
      await server.close(force: true);
      throw StateError('Python 源已释放');
    }
    _server = server;
    server.listen((request) {
      unawaited(_handle(request));
    });
    return 'http://127.0.0.1:${server.port}/$_token/proxy?do=py';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (_disposed || request.uri.path != '/$_token/proxy') {
        request.response.statusCode = 404;
        return;
      }
      if (!['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = 405;
        return;
      }
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });
      final value = await invoke({
        'action': 'proxy',
        'params': request.uri.queryParameters,
        'headers': headers,
        'method': request.method,
        'timeout': 30,
      });
      if (_disposed) {
        request.response.statusCode = 410;
        return;
      }
      final status = (value['status'] as num?)?.toInt() ?? 200;
      if (status < 200 || status > 599) {
        throw const FormatException('本地代理状态码无效');
      }
      request.response.statusCode = status;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        '${value['mime'] ?? 'application/octet-stream'}',
      );
      for (final row in (value['headers'] as Map? ?? {}).entries) {
        if (![
          'content-length',
          'connection',
          'transfer-encoding',
          'content-encoding',
        ].contains('${row.key}'.toLowerCase())) {
          request.response.headers.set('${row.key}', '${row.value}');
        }
      }
      final body = base64Decode('${value['body'] ?? ''}');
      if (body.length > 6 * 1024 * 1024) {
        throw const FormatException('本地代理响应过大');
      }
      final declaredLength = (value['headers'] as Map? ?? {}).entries
          .where((e) => '${e.key}'.toLowerCase() == 'content-length')
          .map((e) => int.tryParse('${e.value}'))
          .firstOrNull;
      request.response.contentLength =
          request.method == 'HEAD' &&
              declaredLength != null &&
              declaredLength >= 0
          ? declaredLength
          : body.length;
      if (request.method != 'HEAD') request.response.add(body);
    } catch (_) {
      // Scripts can return URLs/tokens in exceptions; keep the HTTP error plain.
      request.response.statusCode = 502;
    } finally {
      await request.response.close().catchError((Object _) {});
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_server?.close(force: true));
    _server = null;
  }
}
