import 'dart:io';

import 'package:flutter/foundation.dart';

import '../util/lume_log.dart';

/// 域名解析缓存（TTL 制）**与**连接工厂的粘合层。
///
/// ## 为什么需要它
///
/// `dart:io` 的 `HttpClient` 每次建立新连接都会重新解析域名：连接池能省掉
/// **同一个连接**上的握手，但换域名、并发多连接、连接池回收之后都要再解析一遍。
/// 真机上的表现就是「同一个站点的图片列表，前几张一直慢半拍」——每次解析在
/// 弱网 / 异地 DNS 上要几十到几百毫秒。
///
/// 这里给 `HttpClient.connectionFactory` 套一层：**自己解析、按 TTL 缓存**，
/// 再用 `Socket.startConnect` 直连解析出来的地址。
///
/// ## 两条硬约束
///
/// 1. **失败即失效**：连接失败立刻丢掉该域名的缓存并**重新解析一次**。
///    CDN 换 IP 是常态，缓存住一个已经不可达的地址会把「偶尔慢」变成「一直连不上」。
/// 2. **失败不影响功能**：解析或连接出错时把错误原样抛回给 HttpClient（它按既有
///    逻辑重试/报错），这一层不做任何「吞掉错误返回空连接」的事。
class DnsCache {
  DnsCache({Duration? ttl, Future<List<InternetAddress>> Function(String host)? lookup})
      : ttl = ttl ?? const Duration(minutes: 5),
        _lookup = lookup ?? InternetAddress.lookup;

  /// 解析结果的有效期。
  ///
  /// 5 分钟是刻意的折中：太短（如 30 秒）等于没缓存，太长会在 CDN 切地址后
  /// 长时间连不上（虽然有失败重解析兜底，但每次都要先失败一次）。
  final Duration ttl;

  final Future<List<InternetAddress>> Function(String host) _lookup;

  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// 命中次数 / 未命中次数（调试面板与测试用）。
  int hits = 0;
  int misses = 0;

  /// 解析 [host]：命中且未过期则直接用缓存，否则重新解析并记入。
  Future<InternetAddress> resolve(String host, DateTime now) async {
    final cached = _entries[host];
    if (cached != null && now.difference(cached.at) < ttl) {
      hits++;
      return cached.address;
    }
    misses++;
    final address = await _lookupOne(host);
    _entries[host] = _Entry(address: address, at: now);
    return address;
  }

  /// 丢掉某个域名的缓存（连接失败时调用，下一次会重新解析）。
  void invalidate(String host) => _entries.remove(host);

  /// 清空全部缓存。
  void clear() => _entries.clear();

  int get size => _entries.length;

  Future<InternetAddress> _lookupOne(String host) async {
    final addresses = await _lookup(host);
    if (addresses.isEmpty) {
      throw SocketException('域名解析失败：$host');
    }
    // 多条记录时取第一条：iOS 侧没有 Happy Eyeballs 之外的选择余地，
    // 而「失败重解析」会把坏掉的那条换掉。
    return addresses.first;
  }

  /// 给一个 `HttpClient` 装上「带缓存的解析 + 直连」连接工厂。
  ///
  /// [inner] 为原来的工厂（默认未设置）；为空时用 [Socket.startConnect]。
  /// 返回的工厂行为：
  /// 1. 解析 host（走缓存）；
  /// 2. 直连该地址；
  /// 3. 连接失败 → 失效缓存 + 重新解析 + 再试一次（只重试一次，避免打转）。
  static void attach(
    HttpClient client, {
    DnsCache? cache,
    Duration? ttl,
  }) {
    final dnsCache = cache ?? DnsCache(ttl: ttl);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? uri.port;
      try {
        final address = await dnsCache.resolve(host, DateTime.now());
        return await Socket.startConnect(address, port);
      } catch (error) {
        // 失败即失效 + 重解析一次：CDN 换 IP / 解析结果过期都在这里兜住。
        LumeLog.info('[dns] $host 连接失败（$error），重新解析后重试一次');
        dnsCache.invalidate(host);
        final address = await dnsCache.resolve(host, DateTime.now());
        return await Socket.startConnect(address, port);
      }
    };
  }

  /// 仅测试用：观察当前缓存内容。
  @visibleForTesting
  Map<String, InternetAddress> get snapshot => <String, InternetAddress>{
        for (final entry in _entries.entries) entry.key: entry.value.address,
      };
}

class _Entry {
  _Entry({required this.address, required this.at});

  final InternetAddress address;
  final DateTime at;
}
