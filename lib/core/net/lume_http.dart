import 'dart:async';
import 'source_request_log.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'lume_net.dart';
import 'waf.dart';
import 'network_queue.dart';
import 'network_settings.dart';

/// 网络失败的稳定标记。请求没能完成时打在异常文本前面，上层据此把
/// 「网络异常」从「脚本报错」里分出来（见数据源层的沙箱失败归一）。
class LumeSourceNetworkMarker {
  LumeSourceNetworkMarker._();

  static const String failure = '网络请求失败';
}

/// 宿主网络层异常（连接失败、超时等）。
class LumeHttpException implements Exception {
  const LumeHttpException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
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

/// JS 图源的网络请求全部经由此 Dart 层发出，JS 侧不直接持有 socket。
///
/// 从本版起所有请求都经 [NetworkQueue] 排队后发出（文档第六条）：
/// 全局并发与单域名并发在这里生效，429 / 503 在这里退避重试，UA 与代理在这里
/// 按「图源覆盖 → 全局设置 → 内置默认」的顺序决定。调用方只管发请求，
/// 防封策略不需要在每个业务点各写一遍。
///
/// 隔离：`cookie` 只来自图源自身配置（[NetworkProfile]），不与其他图源共享。
class LumeHttp {
  LumeHttp({
    http.Client? client,
    NetworkSettings? settings,
    NetworkProfile? profile,
    this._source = '宿主',
    this._queue,
    String? Function()? sessionCookies,
    String bridge = '',
  })  : _client = client ?? http.Client(),
        _clientInjected = client != null,
        _settings = (settings ?? const NetworkSettings()).clamped(),
        _profile = profile ?? NetworkProfile.none,
        // ignore: prefer_initializing_formals —— 具名参数是公开契约，字段是私有的
        _sessionCookies = sessionCookies,
        _bridge = bridge.trim();

  static const Duration defaultTimeout = NetworkSettings.defaultTimeout;

  static const String defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  final http.Client _client;

  /// 调用方是否显式注入了客户端（决定发送路径，见 [_effectiveQueue]）。
  final bool _clientInjected;

  final NetworkSettings _settings;
  final NetworkProfile _profile;

  /// 「网页视图」会话 Cookie 的提供者（按图源；为空表示这个客户端不需要）。
  ///
  /// **每次请求现取**而不是构造时定死：用户在网页视图里刚过完校验、Cookie 才刚
  /// 写进库，下一次请求就该带上——定死会让「验证完还得重进页面」成为常态。
  final String? Function()? _sessionCookies;

  /// 桥接服务地址（用户口径 2.2）：非空时脚本会把 API 请求指到它。
  ///
  /// 宿主只负责**存与给**：转发逻辑在脚本里（不同站点的桥不一样），
  /// 引擎把它注入成全局 `LumeSource.bridge`。
  final String _bridge;

  /// 当前生效的桥接服务地址（给引擎注入用）。
  String get bridge => _bridge;

  /// 请求来源标记：日志里区分「哪个图源 / 哪个模块」在发请求。
  final String _source;

  NetworkQueue? _queue;

  /// 生效的 UA：图源覆盖 → 全局设置 → 内置默认。
  String get effectiveUserAgent {
    final merged = _profile.mergedWith(_settings);
    return merged.userAgent.isEmpty ? defaultUserAgent : merged.userAgent;
  }

  /// 生效的代理；为空表示直连。
  String get effectiveProxy => _profile.mergedWith(_settings).proxy;

  /// 生效的单次请求超时。
  Duration get effectiveTimeout => _settings.timeout;

  /// 队列：优先用注入的（测试替身）；否则用**应用级共享队列**——文档要求的
  /// 「全局总并发 6~12」只有全应用共用一份额度时才成立，各建各的等于没有限制。
  NetworkQueue get _effectiveQueue {
    if (_queue != null) return _queue!;
    // 显式注入了客户端（测试替身）：额度仍按本实例算，发送走注入的客户端。
    if (_clientInjected) {
      return _injectedQueue ??=
          NetworkQueue(settings: _settings, sender: _sendWithClient);
    }
    // 生产：全应用共享一份并发额度。
    return LumeNet.queue;
  }

  NetworkQueue? _injectedQueue;

  /// 绑定共享队列：同一板块的图源共用一个队列，并发额度才真的互通。
  void useQueue(NetworkQueue queue) => _queue = queue;

  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    final request = NetworkRequest(
      url: url,
      method: method.toUpperCase(),
      headers: _headersFor(headers),
      body: body,
      source: _source,
      // 只有幂等方法参与重试：POST 重试可能造成重复提交。
      retryOn: _isIdempotent(method),
      proxy: _profile.mergedWith(_settings).proxy,
      // 证书过期站点的唯一出路（按源显式开启，默认关）。
      allowBadCertificate: _profile.mergedWith(_settings).allowBadCertificate,
    );

    // 单次请求的超时兜底：队列内部含重试等待，这里按「重试次数 + 1」放宽，
    // 避免把正常退避误判成超时。
    // 记住「这个源最近请求过的地址」：脚本抛 WAF 标记时用它兜底弹验证窗
    //（老脚本的报错文案里没有 URL，粘贴导入的源也没有订阅地址）。
    SourceRequestLog.record(_source, url);

    final budget = (timeout ?? _settings.timeout) * (_settings.maxRetries + 1);
    final NetworkResponse response;
    try {
      response = await _effectiveQueue.send(request).timeout(budget);
    } on TimeoutException catch (error) {
      throw LumeHttpException(
        '${LumeSourceNetworkMarker.failure}：请求超时（${budget.inSeconds}s）',
        cause: error,
      );
    } on LumeHttpException {
      rethrow;
    } catch (error) {
      if (!_isNetworkFailure(error)) rethrow;
      throw LumeHttpException(
        '${LumeSourceNetworkMarker.failure}：$error',
        cause: error,
      );
    }

    return LumeHttpResponse(
      statusCode: response.statusCode,
      body: Uint8List.fromList(response.body),
      headers: response.headers,
    );
  }

  /// 用注入客户端发送（队列的 sender）。
  ///
  /// 生产路径默认走 [LumeNet.queue]（共享队列 + [LumeNet.sendDirect]，代理在这里
  /// 生效）；只有显式注入了 `client` 的调用方（测试的失败替身）才用这条路径，
  /// 保证「注入即生效」的既有语义不变。
  Future<NetworkResponse> _sendWithClient(NetworkRequest request) async {
    final outgoing = http.Request(request.method, Uri.parse(request.url));
    outgoing.headers.addAll(request.headers);
    if (request.body != null) outgoing.body = request.body!;
    final streamed = await _client.send(outgoing).timeout(_settings.timeout);
    final bytes = await streamed.stream.toBytes().timeout(_settings.timeout);
    return NetworkResponse(
      statusCode: streamed.statusCode,
      body: bytes,
      headers: streamed.headers,
    );
  }

  /// 请求头：调用方给的优先，UA 与 Cookie 按「图源覆盖 → 全局」补齐。
  Map<String, String> _headersFor(Map<String, String>? headers) {
    final merged = <String, String>{...?headers};
    merged.putIfAbsent('User-Agent', () => effectiveUserAgent);
    // Cookie 三段合并：脚本自己给的（最高优先，原样保留）→ 网页视图会话 →
    // 图源 / 全局配置里的 Cookie。会话里那枚 cf_clearance 必须带上，否则永远 403。
    final existing = merged['Cookie'];
    final session = _sessionCookies?.call();
    final profile = _profile.mergedWith(_settings).cookie.trim();
    final mergedCookie = mergeCookieHeader(
      existing: existing,
      wafCookies: <String>[session ?? '', profile].where((v) => v.isNotEmpty).join('; '),
    );
    if (mergedCookie != null && mergedCookie.isNotEmpty) {
      merged['Cookie'] = mergedCookie;
    }
    return merged;
  }

  /// 幂等方法：可安全重试。
  static bool _isIdempotent(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
      case 'TRACE':
        return true;
      default:
        return false;
    }
  }

  static bool _isNetworkFailure(Object error) =>
      error is SocketException ||
      error is HttpException ||
      error is http.ClientException ||
      error is TimeoutException;

  void dispose() => _client.close();
}
