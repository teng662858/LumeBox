import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../util/lume_log.dart';
import 'network_queue.dart';
import 'network_settings.dart';

/// 全局网络层入口：**一个队列、一份设置**，四个板块共用。
///
/// 为什么必须是应用级单例：文档要求「全局总并发 6~12」——若每个板块各建一个
/// 队列，四个板块同时跑就是四倍并发，防封就失效了。因此队列在这里唯一持有，
/// 所有 [LumeHttp] 都经 [queue] 取用同一份额度。
///
/// 设置来源：[NetworkSettingsStore] 落盘的全局设置；启动时 [boot] 读一次，
/// 用户在设置页改动后经 [apply] 立即生效（队列连同新设置重建，在飞请求自然结束）。
class LumeNet {
  LumeNet._();

  static NetworkSettings _settings = const NetworkSettings();
  static NetworkQueue? _queue;

  /// 当前生效的全局网络设置。
  static NetworkSettings get settings => _settings;

  /// 全局唯一队列（惰性创建）。
  static NetworkQueue get queue =>
      _queue ??= NetworkQueue(settings: _settings, sender: sendDirect);

  /// 启动时读一次落盘设置。失败不阻断启动（回退默认值）。
  static Future<void> boot() async {
    try {
      final store = await NetworkSettingsStore.open();
      apply(store.load());
    } catch (error, stackTrace) {
      LumeLog.warn('全局网络设置加载失败，使用默认值: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 应用新设置：立即生效（队列重建，额度按新值计算）。
  static void apply(NetworkSettings settings) {
    _settings = settings.clamped();
    _queue = NetworkQueue(settings: _settings, sender: sendDirect);
  }

  /// 保存并应用（设置页用）。
  static Future<void> save(NetworkSettings settings) async {
    apply(settings);
    final store = await NetworkSettingsStore.open();
    store.save(_settings);
  }

  /// 仅测试用：复位到默认（换目录或换替身队列后调用）。
  static void resetForTesting() {
    _settings = const NetworkSettings();
    _queue = null;
  }

  /// 共享队列的发送实现：按请求自带的代理配置建客户端。
  ///
  /// 与 `LumeHttp._rawSend` 的区别只在于「客户端从哪来」——这里没有注入的
  /// 客户端，因此每请求按代理配置决定：直连用默认客户端，配了代理就套一层。
  static Future<NetworkResponse> sendDirect(NetworkRequest request) async {
    final proxy = request.proxy.trim();
    final client = proxy.isEmpty ? _sharedClient() : _proxyClient(proxy);
    try {
      final outgoing = http.Request(request.method, Uri.parse(request.url));
      outgoing.headers.addAll(request.headers);
      if (request.body != null) outgoing.body = request.body!;
      final streamed = await client.send(outgoing).timeout(_settings.timeout);
      final bytes = await streamed.stream.toBytes().timeout(_settings.timeout);
      return NetworkResponse(
        statusCode: streamed.statusCode,
        body: bytes,
        headers: streamed.headers,
      );
    } finally {
      if (!identical(client, _shared)) client.close();
    }
  }

  static http.Client? _shared;

  static http.Client _sharedClient() => _shared ??= http.Client();

  /// http / https 代理；SOCKS 如实降级为直连并记一条告警。
  static http.Client _proxyClient(String proxy) {
    final uri = Uri.tryParse(proxy);
    if (uri == null || uri.host.isEmpty) {
      LumeLog.warn('代理地址无效（$proxy），本次直连');
      return _sharedClient();
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme.startsWith('socks')) {
      LumeLog.warn('暂不支持 SOCKS 代理（$proxy），本次直连');
      return _sharedClient();
    }
    if (scheme != 'http' && scheme != 'https') {
      LumeLog.warn('不认识的代理协议（$proxy），本次直连');
      return _sharedClient();
    }
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return IOClient(
      HttpClient()..findProxy = (target) => 'PROXY ${uri.host}:$port',
    );
  }
}
