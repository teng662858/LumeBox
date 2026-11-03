import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../util/lume_log.dart';
import 'network_queue.dart';

/// iPhone 上「URLSession 那一层被 ATS 拦掉」之后的第二条通道。
///
/// iOS 的 App Transport Security 只约束 URLSession / WebKit：明文 `http://`
/// 请求会被直接拒发，Dart 侧收到 `PlatformException(code: 'transport_security')`
/// （原生细节 `NSURLErrorDomain -1022`）。真机表现就是「整站只有 http 的源
/// 一律打不开，别的源正常」（直播盒子、火力视频这类老站全是明文）。
///
/// `dart:io` 自己开 socket 建连，**完全不经过 ATS**，所以同一个请求换到这条
/// 通道就能通。只有 ATS 明确拒绝时才走这里：正常 https 站点继续用 URLSession
/// （它跟随系统代理 / VPN，与 WebKit 的线路一致）。
Future<NetworkResponse> sendWithoutAts(NetworkRequest request) async {
  final client = IOClient(HttpClient());
  final timeout = request.timeout ?? const Duration(seconds: 15);
  LumeLog.info('[net] ATS 拒绝明文请求，改走 dart:io 通道：${request.url}');
  try {
    final outgoing = http.AbortableRequest(
      request.method,
      Uri.parse(request.url),
      abortTrigger: request.cancellation?.signal,
    );
    outgoing.followRedirects = request.followRedirects;
    outgoing.headers.addAll(request.headers);
    if (request.bodyBytes != null) {
      outgoing.bodyBytes = request.bodyBytes!;
    } else if (request.body != null) {
      outgoing.body = request.body!;
    }
    final streamed = await client.send(outgoing).timeout(timeout);
    final bytes = await readResponseBody(
      streamed.stream,
      maxBytes: request.maxBytes,
    ).timeout(timeout);
    return NetworkResponse(
      statusCode: streamed.statusCode,
      body: bytes,
      headers: streamed.headers,
    );
  } finally {
    client.close();
  }
}
