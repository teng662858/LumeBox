import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../util/lume_log.dart';
import 'network_settings.dart';

/// 一次待发请求。队列只认这些字段，不认识 http 包的类型。
class NetworkRequest {
  const NetworkRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.source = '宿主',
    this.retryOn = true,
    this.proxy = '',
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// 请求来源标记（图源 id / 「订阅拉取」/「图片缓存」…）：日志里区分谁在发请求。
  final String source;

  /// 是否参与退避重试（幂等的 GET 默认参与；上传类请求可关掉）。
  final bool retryOn;

  /// 本次请求的代理（图源覆盖或全局设置解析后的结果）；空串表示直连。
  final String proxy;
}

/// 一次请求的应答（与 `LumeHttpResponse` 同形，避免队列依赖上层模型）。
class NetworkResponse {
  const NetworkResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

/// 真正的发送动作。队列只负责「何时发、发几次」，发送实现由调用方给。
typedef NetworkSender = Future<NetworkResponse> Function(NetworkRequest request);

/// 网络队列：**所有 HTTP 请求的唯一出口**（文档第六条）。
///
/// 三层约束：
/// 1. **全局并发**：同时在跑的请求不超过 `globalConcurrency`（默认 8，区间 6~12）；
/// 2. **单域名并发**：同一 host 同时在跑的请求不超过 `perHostConcurrency`
///    （默认 2，区间 2~3）——这是防封的核心，多图源批量搜索不会把同一个站打爆；
/// 3. **指数退避重试**：429 / 503 与网络波动按 `base * 2^n` 退避重试，
///    服务器给了 `Retry-After` 就听它的（上限见 [maxRetryAfter]）。
///
/// 并发控制按「域名」而不是「图源」：同一图源的不同请求、不同图源的同一域名
/// 请求都算在同一个域名额度里，这正是防封需要的口径。
///
/// 额度获取用「条件变量」模式：拿不到就登记一个等待者、让出执行权，任何一次
/// 释放都会唤醒全部等待者重新检查。这样不会出现「先占全局额度再等域名额度」
/// 导致的额度囤积（那会让某个大站把全局额度全占住，饿死其他域名）。
class NetworkQueue {
  NetworkQueue({
    required this.settings,
    required this.sender,
    Random? random,
  }) : _random = random ?? Random();

  /// 生效的网络设置（并发、重试、UA、代理都在这里）。
  final NetworkSettings settings;

  /// 实际发送动作。
  final NetworkSender sender;

  final Random _random;

  /// 单次重试的最大等待：即使服务器给了更长的 Retry-After 也不无限等。
  static const Duration maxRetryAfter = Duration(seconds: 30);

  int _activeGlobal = 0;
  final Map<String, int> _activePerHost = <String, int>{};

  /// 等额度的请求（条件变量语义：释放时全部唤醒，各自重新检查）。
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 诊断计数（测试与日志用）。
  int get activeGlobal => _activeGlobal;

  int get waitingCount => _waiters.length;

  int activeForHost(String host) => _activePerHost[host] ?? 0;

  /// 发一次请求：排队 → 发送 → 失败按需退避重试。
  Future<NetworkResponse> send(NetworkRequest request) async {
    final host = hostOf(request.url);
    var attempt = 0;
    while (true) {
      await _acquire(host);
      NetworkResponse response;
      try {
        response = await sender(request);
      } catch (error) {
        _release(host);
        if (!request.retryOn || attempt >= settings.maxRetries) rethrow;
        final delay = _backoff(attempt);
        _logRetry(request, host, '网络异常（$error）', delay, attempt + 1);
        await Future<void>.delayed(delay);
        attempt++;
        continue;
      }
      _release(host);

      if (!request.retryOn ||
          !isRetryable(response.statusCode) ||
          attempt >= settings.maxRetries) {
        return response;
      }
      final delay = retryAfterOf(response) ?? _backoff(attempt);
      _logRetry(request, host, 'HTTP ${response.statusCode}', delay, attempt + 1);
      await Future<void>.delayed(delay);
      attempt++;
    }
  }

  /// 取 URL 的 host；解析不出来时用整个 URL 当键（仍受全局并发约束）。
  static String hostOf(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    return host.isEmpty ? url : host;
  }

  /// 状态码是否需要退避重试：429（限流）与 503（服务暂不可用）。
  ///
  /// 刻意不重试其余 4xx：地址错了、要鉴权，重试只是徒劳地多打几次目标站。
  static bool isRetryable(int statusCode) => statusCode == 429 || statusCode == 503;

  /// 服务器给的 `Retry-After`（秒或 HTTP 日期），上限 [maxRetryAfter]。
  static Duration? retryAfterOf(NetworkResponse response) {
    final raw = response.headers['retry-after'] ??
        response.headers['Retry-After'];
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;

    final seconds = int.tryParse(value);
    if (seconds != null) {
      final delay = Duration(seconds: seconds);
      return delay > maxRetryAfter ? maxRetryAfter : delay;
    }
    final date = _tryParseHttpDate(value);
    if (date == null) return null;
    final delay = date.difference(DateTime.now());
    if (delay.isNegative) return Duration.zero;
    return delay > maxRetryAfter ? maxRetryAfter : delay;
  }

  /// 解析 HTTP 日期（`Retry-After` 的日期写法）。解析失败返回 null。
  static DateTime? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// 指数退避：base * 2^n，叠加 0~25% 抖动（避免多个图源同时重试形成共振）。
  Duration _backoff(int attempt) {
    final base = settings.retryBaseDelay.inMilliseconds;
    final raw = base * pow(2, attempt).toInt();
    final jitter = (raw * 0.25 * _random.nextDouble()).round();
    final total = raw + jitter;
    return Duration(
      milliseconds: total > maxRetryAfter.inMilliseconds
          ? maxRetryAfter.inMilliseconds
          : total,
    );
  }

  void _logRetry(
    NetworkRequest request,
    String host,
    String reason,
    Duration delay,
    int nextAttempt,
  ) {
    LumeLog.warn(
      '[${request.source}] $host $reason，'
      '${delay.inMilliseconds}ms 后重试（第 ${nextAttempt + 1} 次尝试）',
    );
  }

  // -------------------------------------------------------------- 额度闸门

  /// 拿到「全局 + 该域名」两个额度；拿不到就等，被唤醒后重新检查。
  Future<void> _acquire(String host) async {
    while (true) {
      final globalOk = _activeGlobal < settings.globalConcurrency;
      final hostOk =
          (_activePerHost[host] ?? 0) < settings.perHostConcurrency;
      if (globalOk && hostOk) {
        _activeGlobal++;
        _activePerHost[host] = (_activePerHost[host] ?? 0) + 1;
        return;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void _release(String host) {
    final remaining = (_activePerHost[host] ?? 1) - 1;
    if (remaining <= 0) {
      _activePerHost.remove(host);
    } else {
      _activePerHost[host] = remaining;
    }
    if (_activeGlobal > 0) _activeGlobal--;

    // 条件变量语义：唤醒全部等待者，各自重新检查额度。
    if (_waiters.isEmpty) return;
    final pending = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in pending) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}
