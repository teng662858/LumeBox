import 'package:flutter/services.dart';

import 'ats_fallback.dart';
import 'network_queue.dart';
import 'ios_verified_webview.dart';
import 'waf.dart';
import 'network_activity.dart';
import 'network_cancellation.dart';
import 'ios_webkit_text_network.dart';
import 'secure_connection_failure.dart';
import '../js/source_web_runtime.dart';

class IosImageNetwork {
  static const channel = MethodChannel('lumebox/image_network');
  static bool _installed = false;
  static int _sequence = 0;
  static final _active = <String>{};
  static Future<NetworkResponse> send(NetworkRequest request) async {
    if (!_installed) {
      _installed = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'state' && call.arguments is Map) {
          final args = call.arguments as Map;
          final id = '${args['requestId']}';
          if (_active.contains(id)) {
            NetworkActivity.setWaiting(id, args['waiting'] == true);
          }
        }
      });
    }
    request.cancellation?.check();
    final id = 'http-${_sequence++}';
    _active.add(id);
    final local = NetworkCancellation();
    final remove = request.cancellation?.onCancel(local.cancel);
    final removeNative = local.onCancel(() {
      channel
          .invokeMethod<void>('cancel', {'requestId': id})
          .catchError((_) {});
    });
    NetworkActivity.register(
      id,
      WaitingNetworkRequest(
        label: request.source,
        host: Uri.tryParse(request.url)?.host ?? '',
        method: request.method,
        cancel: local.cancel,
      ),
    );
    try {
      final raw = await local.guard(
        channel.invokeMapMethod<String, dynamic>('get', {
          'requestId': id,
          'url': request.url,
          'headers': request.headers,
          'method': request.method,
          'followRedirects': request.followRedirects,
          if (request.maxBytes != null) 'maxBytes': request.maxBytes,
          if (request.bodyBytes != null)
            'bodyBytes': Uint8List.fromList(request.bodyBytes!),
          if (request.body != null) 'body': request.body,
          if (request.reuseVerifiedSession) 'reuseVerification': true,
          'timeoutSeconds':
              (request.timeout ?? const Duration(seconds: 15)).inMilliseconds /
              1000,
        }),
      );
      local.check();
      if (raw == null) throw StateError('图片网络未返回响应');
      final response = NetworkResponse(
        statusCode: raw['status'] as int,
        body: (raw['body'] as List).cast<int>(),
        headers: (raw['headers'] as Map).map(
          (key, value) => MapEntry('$key', '$value'),
        ),
      );
      if (request.reuseVerifiedSession &&
          (request.source.startsWith('封面:') ||
              request.source == '图片缓存' ||
              request.method == 'POST') &&
          WafDetector.isChallenge(
            statusCode: response.statusCode,
            headers: response.headers,
            body: String.fromCharCodes(response.body.take(16000)),
          )) {
        try {
          return await IosVerifiedWebView.readResource(request)
              .timeout(const Duration(seconds: 20));
        } catch (_) {
          request.cancellation?.check();
          // A still-blocked image remains a challenge; offer manual verification.
        }
      }
      return response;
    } on PlatformException catch (error, stack) {
      if (error.code == 'cancelled') throw const NetworkCancelled();
      // ATS 只约束 URLSession：明文 http 源站被拒发（NSURLErrorDomain -1022）。
      // 换 dart:io 通道重发同一请求，站点本身没问题时就能正常拿到数据。
      if (error.code == 'transport_security') {
        return await sendWithoutAts(request);
      }
      if (secureConnectionFailureOf(error) !=
              SecureConnectionFailure.handshake ||
          !IosWebKitTextNetwork.accepts(request)) {
        rethrow;
      }
      try {
        return await IosWebKitTextNetwork.read(request, id);
      } on SourceWebVerificationException {
        rethrow;
      } catch (_) {
        request.cancellation?.check();
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      remove?.call();
      removeNative();
      _active.remove(id);
      NetworkActivity.finish(id);
    }
  }
}
