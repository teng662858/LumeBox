import 'network_cancellation.dart';
import 'ios_verified_webview.dart';
import 'site_session_pool.dart';
import 'source_text_decoder.dart';

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
    this.decodedText,
    this.url,
  });

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;

  final String? decodedText;
  final String? url;
  String get text => decodedText ?? utf8.decode(body, allowMalformed: true);
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
    String? Function()? sessionUserAgent,
    String bridge = '',
    String Function(String)? rewriteUrl,
  }) : _client = client ?? http.Client(),
       _clientInjected = client != null,
       _settings = (settings ?? const NetworkSettings()).clamped(),
       _profile = profile ?? NetworkProfile.none,
       // ignore: prefer_initializing_formals —— 具名参数是公开契约，字段是私有的
       _sessionCookies = sessionCookies,
       // ignore: prefer_initializing_formals
       _sessionUserAgent = sessionUserAgent,
       _bridge = bridge.trim(),
       // ignore: prefer_initializing_formals
       _rewriteUrl = rewriteUrl;

  static const Duration defaultTimeout = NetworkSettings.defaultTimeout;

  /// Host services never inherit a source's Cookie, headers, session or URL rewrite.
  LumeHttp hostServiceClient() =>
      LumeHttp(client: _client, settings: _settings, source: '宿主服务');

  static const String defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  final String Function(String)? _rewriteUrl;
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

  /// 「网页视图里验证过的 UA」提供者（按图源；为空表示没有会话）。
  ///
  /// **必须优先于配置里的 UA**：Cloudflare 把 `cf_clearance` 绑在 IP + UA 上，
  /// 验证时用的是哪个 UA，后续请求就得用哪个——否则 Cookie 带上了照样 403
  /// （真机反馈的「验完还是被拦」）。没有会话时返回 null，按配置走。
  final String? Function()? _sessionUserAgent;

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
    final verified = _sessionUserAgent?.call()?.trim() ?? '';
    if (verified.isNotEmpty) return verified;
    final merged = _profile.mergedWith(_settings);
    return merged.userAgent.isEmpty ? defaultUserAgent : merged.userAgent;
  }

  /// **用户显式配过**的 UA（图源覆盖 → 全局设置）；没配过返回空串。
  ///
  /// 与 [effectiveUserAgent] 的区别：这里**不回落到内置默认值**。网页视图要用它
  /// 判断「用户是不是专门指定了 UA」——没指定时，验证窗应该用**设备自己的**
  /// Safari UA（见 `WafWebViewPage` 的 UA 派生），而不是内置的那串硬编码版本号。
  String get configuredUserAgent {
    final merged = _profile.mergedWith(_settings);
    return merged.userAgent.trim();
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
      return _injectedQueue ??= NetworkQueue(
        settings: _settings,
        sender: _sendWithClient,
      );
    }
    // 生产：全应用共享一份并发额度。
    return LumeNet.queue;
  }

  NetworkQueue? _injectedQueue;
  final _lifetime = NetworkCancellation();
  String? _legacySessionHost;

  /// 站点标识：取注册域近似值（`www.api.example.com` / `api.example.com` → `example.com`）。
  ///
  /// 不做完整公共后缀表，只对 `com.cn` / `co.uk` 这类常见的两段后缀多取一级，
  /// 避免把 `a.co.uk` 和 `b.co.uk` 当成同一站。
  static const Set<String> _twoPartSuffixes = {
    'co',
    'com',
    'net',
    'org',
    'gov',
    'edu',
    'ac',
  };

  static String _cookieSite(String host) {
    final labels = host.toLowerCase().split('.');
    if (labels.length <= 2) return labels.join('.');
    final take = _twoPartSuffixes.contains(labels[labels.length - 2]) ? 3 : 2;
    return labels.sublist(labels.length - take).join('.');
  }

  /// 两个 host 是否属于同一站点树（`www.example.com` 与 `api.example.com` 同站；
  /// 仿冒域 `evil-example.com` 不同站）。
  static bool _sameCookieSite(String host, String pinned) =>
      _cookieSite(host) == _cookieSite(pinned);

  /// 绑定共享队列：同一板块的图源共用一个队列，并发额度才真的互通。
  void useQueue(NetworkQueue queue) => _queue = queue;

  Future<LumeHttpResponse> send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
    int? maxBytes,
  }) => _send(
    url: url,
    method: method,
    headers: headers,
    body: body,
    timeout: timeout,
    maxBytes: maxBytes,
  );

  Future<LumeHttpResponse> sendWithoutRedirects({
    required String url,
    Map<String, String>? headers,
    Duration? timeout,
    int? maxBytes,
  }) => _send(
    url: url,
    headers: headers,
    timeout: timeout,
    maxBytes: maxBytes,
    followRedirects: false,
  );

  Future<LumeHttpResponse> _send({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    Duration? timeout,
    int? maxBytes,
    bool followRedirects = true,
  }) async {
    _lifetime.check();
    final rewritten = _rewriteUrl?.call(url) ?? url;
    var target = Uri.parse(rewritten);
    var verb = method.toUpperCase();
    var outgoing = _routedHeaders(
      url,
      rewritten,
      _headersFor(headers, url: url),
    );
    var payload = body;
    var binary = bodyBytes;
    final seen = <String>{};
    for (var hop = 0; hop <= 10; hop++) {
      if (!['http', 'https'].contains(target.scheme) ||
          target.userInfo.isNotEmpty) {
        throw const FormatException('请求仅支持无内嵌凭据的 HTTP(S) 地址');
      }
      if (!seen.add('$verb $target')) {
        throw const LumeHttpException('redirect_loop：重定向循环');
      }
      outgoing = await SiteSessionPool.shared.synchronize(
        target.toString(),
        outgoing,
        forceCookies:
            hop == 0 &&
            Uri.parse(url).origin == target.origin &&
            (headers?.keys.any((k) => k.toLowerCase() == 'cookie') ?? false),
      );
      final response = await _sendOne(
        url: target.toString(),
        method: verb,
        headers: outgoing,
        body: payload,
        bodyBytes: binary,
        timeout: timeout,
        maxBytes: maxBytes,
        followRedirects: false,
        preparedHeaders: true,
      );
      SiteSessionPool.shared.absorb(target.toString(), response.headers);
      final location = response.headers.entries
          .where((e) => e.key.toLowerCase() == 'location')
          .firstOrNull
          ?.value;
      if (!followRedirects ||
          ![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null) {
        if (response.statusCode < 400 &&
            response.headers.entries.any(
              (e) =>
                  e.key.toLowerCase() == 'content-type' &&
                  e.value.toLowerCase().contains('text/html'),
            )) {
          SiteSessionPool.shared.rememberSourcePage(_source, target.toString());
        }
        return LumeHttpResponse(
          statusCode: response.statusCode,
          body: response.body,
          headers: response.headers,
          decodedText: response.decodedText,
          url: target.toString(),
        );
      }
      if (hop == 10) throw const LumeHttpException('redirect_limit：重定向超过 10 次');
      final next = target.resolve(location);
      if (!['http', 'https'].contains(next.scheme) ||
          next.userInfo.isNotEmpty) {
        throw const LumeHttpException('redirect_scheme：不支持的跳转地址');
      }
      if (next.origin != target.origin) {
        outgoing.removeWhere(
          (k, _) => [
            'cookie',
            'authorization',
            'proxy-authorization',
            'host',
          ].contains(k.toLowerCase()),
        );
      }
      if (target.scheme == 'https' && next.scheme == 'http') {
        outgoing.removeWhere(
          (k, _) =>
              ['referer', 'cookie', 'authorization'].contains(k.toLowerCase()),
        );
      }
      if ((response.statusCode == 303 && verb != 'HEAD') ||
          ([301, 302].contains(response.statusCode) && verb == 'POST')) {
        verb = 'GET';
        payload = null;
        binary = null;
        outgoing.removeWhere(
          (k, _) => [
            'content-type',
            'content-length',
            'transfer-encoding',
          ].contains(k.toLowerCase()),
        );
      }
      target = next;
    }
    throw const LumeHttpException('redirect_limit');
  }

  Future<LumeHttpResponse> _sendOne({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    Duration? timeout,
    int? maxBytes,
    bool followRedirects = true,
    bool preparedHeaders = false,
  }) async {
    final target = _rewriteUrl?.call(url) ?? url;
    final outgoingHeaders = _routedHeaders(
      url,
      target,
      preparedHeaders
          ? Map<String, String>.of(headers ?? {})
          : _headersFor(headers, url: url),
    );
    final cancellation = NetworkCancellation();
    final stopLifetime = _lifetime.onCancel(cancellation.cancel);
    final stopOwner = NetworkCancellation.current?.onCancel(
      cancellation.cancel,
    );
    final request = NetworkRequest(
      url: target,
      cancellation: cancellation,
      reuseVerifiedSession:
          target != url || (_sessionUserAgent?.call()?.isNotEmpty ?? false),
      method: method.toUpperCase(),
      followRedirects: followRedirects,
      timeout: timeout ?? _settings.timeout,
      headers: outgoingHeaders,
      body: body,
      bodyBytes: bodyBytes,
      source: _source,
      textResponse: true,
      // 只有幂等方法参与重试：POST 重试可能造成重复提交。
      retryOn: _isIdempotent(method),
      proxy: Platform.isIOS ? '' : _profile.mergedWith(_settings).proxy,
      // 证书过期站点的唯一出路（按源显式开启，默认关）。
      allowBadCertificate: _profile.mergedWith(_settings).allowBadCertificate,
      // 读取上限：只有探测型请求会传（见 [readResponseBody]）。
      maxBytes: maxBytes,
    );

    // 单次请求的超时兜底：队列内部含重试等待，这里按「重试次数 + 1」放宽，
    // 避免把正常退避误判成超时。
    // 记住「这个源最近请求过的地址」：脚本抛 WAF 标记时用它兜底弹验证窗
    //（老脚本的报错文案里没有 URL，粘贴导入的源也没有订阅地址）。
    SourceRequestLog.record(_source, target);

    final budget = (timeout ?? _settings.timeout) * (_settings.maxRetries + 1);
    NetworkResponse response;
    try {
      response = await _effectiveQueue.send(request).timeout(budget);
      if (Platform.isIOS &&
          !_clientInjected &&
          request.method == 'GET' &&
          response.statusCode == 403 &&
          (_sessionCookies?.call()?.isNotEmpty ?? false) &&
          (_sessionUserAgent?.call()?.isNotEmpty ?? false) &&
          request.proxy.isEmpty) {
        try {
          response = await IosVerifiedWebView.read(request)
              .timeout(const Duration(seconds: 20));
        } catch (_) {
          cancellation.check();
          // Preserve the original challenge response; never claim a passed session.
        }
      }
    } on TimeoutException catch (error) {
      cancellation.cancel(error);
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
    } finally {
      stopLifetime();
      stopOwner?.call();
    }

    return LumeHttpResponse(
      statusCode: response.statusCode,
      body: Uint8List.fromList(response.body),
      headers: response.headers,
      decodedText: await SourceTextDecoder.decode(
        response.body,
        response.headers,
      ),
    );
  }

  /// 用注入客户端发送（队列的 sender）。
  ///
  /// 生产路径默认走 [LumeNet.queue]（共享队列 + [LumeNet.sendDirect]，代理在这里
  /// 生效）；只有显式注入了 `client` 的调用方（测试的失败替身）才用这条路径，
  /// 保证「注入即生效」的既有语义不变。
  Future<NetworkResponse> _sendWithClient(NetworkRequest request) async {
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
    final streamed = await _client
        .send(outgoing)
        .timeout(request.timeout ?? _settings.timeout);
    final bytes = await readResponseBody(
      streamed.stream,
      maxBytes: request.maxBytes,
    ).timeout(request.timeout ?? _settings.timeout);
    return NetworkResponse(
      statusCode: streamed.statusCode,
      body: bytes,
      headers: streamed.headers,
    );
  }

  /// Keep site routing and request identity consistent for every HTTP source.
  /// Only origin changes discard credentials; changing a directory on the same
  /// origin must retain its session. Destination cookies are added separately
  /// by SiteSessionPool, never copied from the old site.
  Map<String, String> _routedHeaders(
    String original,
    String target,
    Map<String, String> headers,
  ) {
    if (original == target) return headers;
    final from = Uri.parse(original), to = Uri.parse(target);
    if (from.origin != to.origin) {
      headers.removeWhere(
        (key, _) => const {
          'cookie',
          'authorization',
          'proxy-authorization',
          'host',
        }.contains(key.toLowerCase()),
      );
    }
    for (final key in headers.keys.toList()) {
      if (key.toLowerCase() == 'referer') {
        headers[key] = _rewriteUrl!(headers[key]!);
      } else if (key.toLowerCase() == 'origin' && headers[key] == from.origin) {
        headers[key] = to.origin;
      }
    }
    return headers;
  }

  /// 请求头：调用方给的优先，UA 与 Cookie 按「图源覆盖 → 全局」补齐。
  /// Browser sources use the exact same per-source session and UA as HTTP.
  Map<String, String> browserRequestHeaders(
    Map<String, String>? headers, {
    String? url,
  }) => url == null
      ? _headersFor(headers)
      : SiteSessionPool.shared.headersFor(url, _headersFor(headers, url: url));

  Map<String, String> _headersFor(Map<String, String>? headers, {String? url}) {
    final host = url == null ? null : Uri.tryParse(url)?.host;
    if (host != null) _legacySessionHost ??= host;
    // 会话 Cookie 按「同一站点树」放行：镜像站常用 www / api / img 等子域，
    // 死锁在第一个 host 上会让登录态只在某一个子域生效（真机：登录后阅读页无效）。
    final legacyAllowed =
        host == null || _sameCookieSite(host, _legacySessionHost!);
    // HTTP 头名不区分大小写；统一需合并的头名，避免覆盖脚本的小写头。
    final merged = <String, String>{};
    for (final entry in (headers ?? const <String, String>{}).entries) {
      final name = switch (entry.key.toLowerCase()) {
        'user-agent' => 'User-Agent',
        'cookie' => 'Cookie',
        _ => entry.key,
      };
      merged[name] = entry.value;
    }
    merged.putIfAbsent('User-Agent', () => effectiveUserAgent);
    final verifiedUserAgent = _sessionUserAgent?.call()?.trim() ?? '';
    if (verifiedUserAgent.isNotEmpty) merged['User-Agent'] = verifiedUserAgent;
    // 配置 → 脚本 → 最新验证会话，同名 Cookie 只保留优先级最高的一份。
    final existing = merged['Cookie'];
    final session = legacyAllowed ? _sessionCookies?.call() : null;
    final profile = legacyAllowed
        ? _profile.mergedWith(_settings).cookie.trim()
        : '';
    final mergedCookie = mergeCookieHeader(
      existing: mergeCookieHeader(existing: profile, wafCookies: existing),
      wafCookies: session,
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

  void dispose() {
    _lifetime.cancel();
    _client.close();
  }
}

extension LumeHttpBinary on LumeHttp {
  /// Binary uploads used by Python requests; preserves the existing send port.
  Future<LumeHttpResponse> sendBytes({
    required String url,
    String method = 'GET',
    Map<String, String>? headers,
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    int? maxBytes,
  }) => _send(
    url: url,
    method: method,
    headers: headers,
    bodyBytes: bodyBytes,
    followRedirects: followRedirects,
    timeout: timeout,
    maxBytes: maxBytes,
  );
}
