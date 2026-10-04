import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// JS 图源的网络请求全部经由此 Dart 层发出，JS 侧不直接持有 socket。
class LumeHttp {
  LumeHttp({http.Client? client}) : _client = client ?? http.Client();

  static const Duration defaultTimeout = Duration(seconds: 20);

  static const String defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  final http.Client _client;

  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration timeout = defaultTimeout,
  }) async {
    final request = http.Request(method.toUpperCase(), Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    request.headers.putIfAbsent('User-Agent', () => defaultUserAgent);
    if (body != null) request.body = body;

    final streamed = await _client.send(request).timeout(timeout);
    final bytes = await streamed.stream.toBytes().timeout(timeout);
    return LumeHttpResponse(
      statusCode: streamed.statusCode,
      body: bytes,
      headers: streamed.headers,
    );
  }

  void dispose() => _client.close();
}

class LumeHttpResponse {
  const LumeHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;

  String get text => utf8.decode(body, allowMalformed: true);
}
