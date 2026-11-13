import 'dart:async';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Each relay request owns its cancellation, while Apple requests share one
/// ephemeral system session for the lifetime of the app. Closing a request must
/// cancel its transfer without closing the session used by other audio tracks.
class AudioBookHttpClient extends http.BaseClient {
  AudioBookHttpClient({http.Client? client, bool? closeClient})
    : _client = client ?? _platformClient(),
      _ownsClient = closeClient ?? !(Platform.isIOS || Platform.isMacOS);

  static http.Client? _appleClient;
  static http.Client _platformClient() {
    if (Platform.isIOS || Platform.isMacOS) {
      return _appleClient ??= CupertinoClient.fromSessionConfiguration(
        URLSessionConfiguration.ephemeralSessionConfiguration()
          ..httpShouldSetCookies = false
          ..cache = null,
      );
    }
    return IOClient(HttpClient()..autoUncompress = false);
  }

  final http.Client _client;
  bool get decodesContentEncoding => _client is CupertinoClient;
  final bool _ownsClient;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('音频请求已取消', request.url);
    final abort = Completer<void>();
    _pending.add(abort);
    final outgoing =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..bodyBytes = await request.finalize().toBytes();
    if (_closed) throw http.ClientException('音频请求已取消', request.url);
    return _client.send(outgoing);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    _pending.clear();
    if (_ownsClient) _client.close();
  }
}
