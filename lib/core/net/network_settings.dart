import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// 全局网络设置：四个板块的图源请求、订阅拉取、图片下载共用这一份。
///
/// 对应文档第六条（防封禁与并发控制）：
/// - **双层并发**：全局总并发 6~12、单域名并发 2~3（防封核心）；
/// - **智能退避重试**：429 / 503 与网络波动自动延时重试；
/// - **统一出口**：全局 UA 与代理在这里配置，所有请求强制走同一队列。
///
/// 单图源的 UA / Cookie / 代理可以覆盖这里的全局值（见 [NetworkProfile]），
/// 覆盖优先于全局——文档明确「单图源配置优先级高于全局设置」。
class NetworkSettings {
  const NetworkSettings({
    this.globalConcurrency = defaultGlobalConcurrency,
    this.perHostConcurrency = defaultPerHostConcurrency,
    this.userAgent = '',
    this.proxy = '',
    this.timeout = defaultTimeout,
    this.maxRetries = defaultMaxRetries,
    this.retryBaseDelay = defaultRetryBaseDelay,
  });

  /// 全局并发下限 / 上限 / 默认。
  ///
  /// 上限 12 → 16、默认 8 → 12（真机反馈：沙箱里的脚本一次要发很多请求，
  /// 并发太低时整体加载明显慢于同类阅读器）。**单域名并发保持 2~3 不动**：
  /// 那是防封核心，提速不该拿被目标站限流来换（本机实测：短时间内连续打
  /// 同一个站会开始返回 503）。
  static const int minGlobalConcurrency = 6;
  static const int maxGlobalConcurrency = 16;
  static const int defaultGlobalConcurrency = 12;

  /// 单域名并发下限 / 上限 / 默认（文档给的区间是 2~3）。
  static const int minPerHostConcurrency = 2;
  static const int maxPerHostConcurrency = 3;
  /// 单域名并发默认值。原为 2，用户反馈「封面加载还是慢」——封面基本集中在
  /// 同一个图床上，2 条并发是瓶颈；提到上限 3（仍在 2–3 的可调区间内，
  /// 用户可以在网络设置里改回去）。
  static const int defaultPerHostConcurrency = 3;

  /// 默认单次请求超时。
  static const Duration defaultTimeout = Duration(seconds: 20);

  /// 默认重试次数（不含首次请求）。
  static const int defaultMaxRetries = 2;

  /// 退避基数：第 n 次重试等待 base * 2^n（另有抖动与 Retry-After 上限约束）。
  static const Duration defaultRetryBaseDelay = Duration(milliseconds: 500);

  /// 全局总并发。
  final int globalConcurrency;

  /// 单域名并发。
  final int perHostConcurrency;

  /// 全局 User-Agent；为空表示用内置默认 UA。
  final String userAgent;

  /// 全局代理；为空表示直连。支持 `http://host:port` 与 `socks5://host:port`。
  final String proxy;

  /// 单次请求超时。
  final Duration timeout;

  /// 429 / 503 / 网络波动时的最大重试次数。
  final int maxRetries;

  /// 退避基数。
  final Duration retryBaseDelay;

  /// 收敛到文档允许的区间。越界配置不会生效（与 `SandboxPolicy.clamped` 同一口径）。
  NetworkSettings clamped() {
    return copyWith(
      globalConcurrency: globalConcurrency.clamp(
        minGlobalConcurrency,
        maxGlobalConcurrency,
      ),
      perHostConcurrency: perHostConcurrency.clamp(
        minPerHostConcurrency,
        maxPerHostConcurrency,
      ),
      maxRetries: maxRetries.clamp(0, 5),
      timeout: timeout < const Duration(seconds: 3)
          ? const Duration(seconds: 3)
          : (timeout > const Duration(seconds: 120)
              ? const Duration(seconds: 120)
              : timeout),
      retryBaseDelay: retryBaseDelay < const Duration(milliseconds: 100)
          ? const Duration(milliseconds: 100)
          : (retryBaseDelay > const Duration(seconds: 10)
              ? const Duration(seconds: 10)
              : retryBaseDelay),
    );
  }

  NetworkSettings copyWith({
    int? globalConcurrency,
    int? perHostConcurrency,
    String? userAgent,
    String? proxy,
    Duration? timeout,
    int? maxRetries,
    Duration? retryBaseDelay,
  }) {
    return NetworkSettings(
      globalConcurrency: globalConcurrency ?? this.globalConcurrency,
      perHostConcurrency: perHostConcurrency ?? this.perHostConcurrency,
      userAgent: userAgent ?? this.userAgent,
      proxy: proxy ?? this.proxy,
      timeout: timeout ?? this.timeout,
      maxRetries: maxRetries ?? this.maxRetries,
      retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'globalConcurrency': globalConcurrency,
        'perHostConcurrency': perHostConcurrency,
        'userAgent': userAgent,
        'proxy': proxy,
        'timeoutMs': timeout.inMilliseconds,
        'maxRetries': maxRetries,
        'retryBaseDelayMs': retryBaseDelay.inMilliseconds,
      };

  /// 从落盘 JSON 还原。缺项与非法值一律回退默认（旧配置不会让网络层起不来）。
  static NetworkSettings fromJson(Object? json) {
    if (json is! Map) return const NetworkSettings();
    const fallback = NetworkSettings();
    final timeoutMs = _int(json['timeoutMs']);
    final retryMs = _int(json['retryBaseDelayMs']);
    return NetworkSettings(
      globalConcurrency: _int(json['globalConcurrency']) ??
          fallback.globalConcurrency,
      perHostConcurrency:
          _int(json['perHostConcurrency']) ?? fallback.perHostConcurrency,
      userAgent: '${json['userAgent'] ?? ''}',
      proxy: '${json['proxy'] ?? ''}',
      timeout: timeoutMs == null
          ? fallback.timeout
          : Duration(milliseconds: timeoutMs),
      maxRetries: _int(json['maxRetries']) ?? fallback.maxRetries,
      retryBaseDelay: retryMs == null
          ? fallback.retryBaseDelay
          : Duration(milliseconds: retryMs),
    ).clamped();
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  String toString() => 'NetworkSettings(全局并发 $globalConcurrency, '
      '单域名 $perHostConcurrency, 超时 ${timeout.inSeconds}s, '
      '重试 $maxRetries, UA ${userAgent.isEmpty ? '默认' : '自定义'}, '
      '代理 ${proxy.isEmpty ? '直连' : proxy})';
}

/// 单次请求生效的网络参数：全局设置 + 单图源覆盖。
///
/// 覆盖优先于全局（文档要求）；Cookie 只来自图源自身配置，避免跨图源串用。
class NetworkProfile {
  const NetworkProfile({
    this.userAgent = '',
    this.cookie = '',
    this.proxy = '',
    this.bridge = '',
  });

  /// 图源级 UA；为空时用全局 UA。
  final String userAgent;

  /// 图源级 Cookie；为空时不附带。
  final String cookie;

  /// 图源级代理；为空时用全局代理。
  final String proxy;

  /// **桥接服务地址**（用户口径 2.2）：个别站点（如 OKooK-CDN + reCAPTCHA v3）
  /// 的放行绑定浏览器会话与 IP 信誉，既导不出 Cookie、普通 HTTP 代理也没用——
  /// 只能把请求转发给一个「已经过验证的无头浏览器桥」（Playwright/Puppeteer）。
  /// 留空 = 不用桥接；不为空时由**脚本**把所有 API 请求指到它（宿主只负责把它
  /// 交给脚本，见 `LumeSource.bridge`）。
  final String bridge;

  bool get isEmpty =>
      userAgent.trim().isEmpty &&
      cookie.trim().isEmpty &&
      proxy.trim().isEmpty &&
      bridge.trim().isEmpty;

  static const NetworkProfile none = NetworkProfile();

  /// 合并：覆盖项优先，缺项取全局。
  NetworkProfile mergedWith(NetworkSettings settings) => NetworkProfile(
        userAgent:
            userAgent.trim().isEmpty ? settings.userAgent : userAgent.trim(),
        cookie: cookie.trim(),
        proxy: proxy.trim().isEmpty ? settings.proxy : proxy.trim(),
      );

  NetworkProfile copyWith({
    String? userAgent,
    String? cookie,
    String? proxy,
    String? bridge,
  }) =>
      NetworkProfile(
        userAgent: userAgent ?? this.userAgent,
        cookie: cookie ?? this.cookie,
        proxy: proxy ?? this.proxy,
        bridge: bridge ?? this.bridge,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'userAgent': userAgent,
        'cookie': cookie,
        'proxy': proxy,
        'bridge': bridge,
      };

  static NetworkProfile fromJson(Object? json) {
    if (json is! Map) return none;
    return NetworkProfile(
      userAgent: '${json['userAgent'] ?? ''}',
      cookie: '${json['cookie'] ?? ''}',
      proxy: '${json['proxy'] ?? ''}',
      bridge: '${json['bridge'] ?? ''}',
    );
  }

  @override
  String toString() => 'NetworkProfile(UA ${userAgent.isEmpty ? '继承' : '自定义'}, '
      'Cookie ${cookie.isEmpty ? '无' : '有'}, '
      '代理 ${proxy.isEmpty ? '继承' : proxy})';
}

/// 全局网络设置的持久化：`<应用支持目录>/network_settings.json`。
///
/// 刻意不放进任何板块目录：这份配置对四个板块同时生效（文档要求「全局互通
/// 生效」），放板块内会与隔离口径矛盾。写入用「先写临时文件再改名」，
/// 中途崩溃不会留下半个 JSON。
class NetworkSettingsStore {
  NetworkSettingsStore._(this._file);

  static const String fileName = 'network_settings.json';

  final File _file;

  static NetworkSettingsStore? _current;

  /// 打开（必要时创建目录）。重复调用返回同一实例。
  static Future<NetworkSettingsStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = NetworkSettingsStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  /// 仅测试用：清掉实例缓存（换目录后重新打开）。
  static void resetForTesting() => _current = null;

  /// 读取设置。文件缺失或损坏时回退默认值，不让网络层起不来。
  NetworkSettings load() {
    try {
      if (!_file.existsSync()) return const NetworkSettings();
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return const NetworkSettings();
      return NetworkSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('网络设置读取失败，回退默认值: $error');
      LumeLog.error(error, stackTrace);
      return const NetworkSettings();
    }
  }

  /// 写回设置（自动收敛到合法区间）。
  void save(NetworkSettings settings) {
    final clamped = settings.clamped();
    try {
      _file.parent.createSync(recursive: true);
      final temp = File('${_file.path}.tmp');
      temp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(clamped.toJson()),
        flush: true,
      );
      temp.renameSync(_file.path);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      throw StateError('网络设置写入失败：$error');
    }
  }

  String get path => _file.path;
}
