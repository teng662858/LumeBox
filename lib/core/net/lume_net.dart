import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// 关闭共享客户端并丢弃缓存（测试用）。
  ///
  /// 为什么需要它：`testWidgets` 跑在假时钟里，而真实 HTTP 的连接池会在响应回来
  /// 之后挂一个 keep-alive 空转定时器（默认 15 秒）——那个定时器落在假时钟上，
  /// 测试收尾时会按「还有定时器没停」报错。关掉客户端会连同连接与定时器一起收掉。
  /// 生产路径不需要这个动作：进程退出即回收，也没有人在假时钟里跑它。
  @visibleForTesting
  static void closeSharedClientForTesting() {
    try {
      _shared?.close();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
    _shared = null;
  }

  /// 共享队列的发送实现：按请求自带的代理配置建客户端。
  ///
  /// 与 `LumeHttp._rawSend` 的区别只在于「客户端从哪来」——这里没有注入的
  /// 客户端，因此每请求按代理配置决定：直连用默认客户端，配了代理就套一层。
  static Future<NetworkResponse> sendDirect(NetworkRequest request) async {
    final proxy = request.proxy.trim();
    // 客户端**复用**（见 [_proxyClient]）：这里不再「用完就关」——每次新建再关闭
    // 等于每个请求都重新做一次 TCP + TLS 握手，开了代理之后尤其明显
    // （真机反馈「即使开启代理速度依然不理想」，根因之一就是它）。
    final client = request.allowBadCertificate
        ? _relaxedClient(proxy)
        : (proxy.isEmpty ? _sharedClient() : _proxyClient(proxy));
    if (request.allowBadCertificate) {
      // 显式放宽的请求逐条留痕：这类请求的安全性由用户自己承担，日志要能查到。
      LumeLog.warn('本次请求已放宽证书校验（按源开启）：${request.url}');
    }
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
  }

  static http.Client? _shared;

  /// 按代理地址缓存的客户端：同一个代理最多一个（连接池才有效）。
  static final Map<String, http.Client> _proxyClients = <String, http.Client>{};

  /// 「容忍证书错误」的客户端（按代理去重）。
  ///
  /// 与普通客户端分开缓存：**绝不**污染共享客户端——那是全 App 都在用的通道，
  /// 只因为某一个源证书过期就全局放宽校验，等于把所有源都摊开给中间人。
  static final Map<String, http.Client> _relaxedClients = <String, http.Client>{};

  static http.Client _sharedClient() => _shared ??= _newClient();

  /// 「容忍证书错误」的客户端：与普通客户端同一套建法，只是放行证书校验失败。
  ///
  /// 只给**按源显式开启**「忽略证书错误」的请求用（见 [NetworkRequest]）：
  /// 站点证书过期时这是唯一的出路（真机案例：北觅影视 v.luttt.com 的 Let's
  /// Encrypt 证书已过期，dart:io 直接 `CERTIFICATE_VERIFY_FAILED`）。
  static http.Client _relaxedClient(String proxy) {
    final key = proxy.trim().isEmpty ? 'direct' : proxy.trim();
    return _relaxedClients.putIfAbsent(key, () {
      final inner = HttpClient();
      inner.badCertificateCallback = (cert, host, port) {
        LumeLog.warn('放行证书校验失败：$host:$port（该源已开启「忽略证书错误」）');
        return true;
      };
      final uri = Uri.tryParse(proxy);
      if (uri != null && uri.host.isNotEmpty && !uri.scheme.toLowerCase().startsWith('socks')) {
        final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
        inner.findProxy = (target) => 'PROXY ${uri.host}:$port';
      }
      return IOClient(inner);
    });
  }

  /// 建一个**标准**客户端：解析、连接池、TLS 全部交给 `dart:io`。
  ///
  /// **这里绝不要装 `connectionFactory`**：dart:io 的约定是——一旦设置了连接工厂，
  /// 它返回的 socket 会被**原样**使用，TLS 握手不会发生（`SecureSocket` 只在没有
  /// 工厂的那条路径上建）。我们曾经为了「DNS 解析缓存」装过一个自己解析 + 直连的
  /// 工厂，结果**所有 https 请求都变成明文打到 443 端口**：nginx 回
  /// `400 The plain HTTP request was sent to HTTPS port`（真机上的「拉取失败：HTTP 400」），
  /// 或者回一个「重定向到自己」的 302（真机上的「Redirect loop detected」）。
  /// 教训：想看 DNS 解析，用系统缓存；想加速，用连接复用（见 [_proxyClients]），
  /// 不要动 TLS 建连路径。
  static http.Client _newClient() => IOClient(HttpClient());

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
    final key = '${uri.host}:$port';
    return _proxyClients.putIfAbsent(key, () {
      final inner = HttpClient()
        ..findProxy = (target) => 'PROXY ${uri.host}:$port';
      // 同样不装连接工厂：HTTPS 走 CONNECT + TLS，由 dart:io 负责（见 [_newClient]）。
      return IOClient(inner);
    });
  }
}
