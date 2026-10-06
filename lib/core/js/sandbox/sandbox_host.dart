/// 宿主代理调用请求。
///
/// JS 侧只能通过 `LumeBridge.invoke(method, payload)` 发起调用，Dart 侧收到后
/// 组装成该请求交给 [SandboxHost]。沙箱本身不认识任何具体方法名。
class SandboxHostRequest {
  const SandboxHostRequest({
    required this.sandboxId,
    required this.method,
    required this.payload,
  });

  /// 发起调用的沙箱标识，便于宿主做隔离（例如按板块拒绝跨区访问）。
  final String sandboxId;

  /// 方法名，命名形如 `http.fetch` / `store.read`。
  final String method;

  /// 已经过 JSON 解码的入参。
  final Object? payload;

  @override
  String toString() => 'SandboxHostRequest($sandboxId, $method)';
}

/// 宿主调用被拒绝或失败。
class SandboxHostException implements Exception {
  const SandboxHostException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// JS 侧全部 IO / 网络能力的抽象代理入口。
///
/// 实现方是唯一持有系统能力的一侧；JS 里不存在任何绕过它的通路。
/// 默认实现是 [DenyAllSandboxHost]，即一行代码都不写时沙箱不开放任何外部能力。
abstract interface class SandboxHost {
  /// 处理一次代理调用。返回必须是 JSON 可序列化的值；
  /// 拒绝或失败时抛出 [SandboxHostException]。
  Future<Object?> invoke(SandboxHostRequest request);
}

/// 默认宿主：拒绝一切外部能力访问。
class DenyAllSandboxHost implements SandboxHost {
  const DenyAllSandboxHost();

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    throw SandboxHostException('沙箱未开放外部能力: ${request.method}');
  }
}

/// 代理方法名常量。图源层按这些名字实现（见 `LumeSourceHost`）。
class SandboxHostMethods {
  SandboxHostMethods._();

  /// 网络请求。入参 `{url, method, headers, body}`，
  /// 返回 `{status, headers, body}`。
  static const String httpFetch = 'http.fetch';

  /// 沙箱内的键值存储（按图源隔离）。入参 `{key}`，
  /// 返回 `{value: string|null}`。
  static const String storeRead = 'store.read';

  /// 沙箱内的键值写入。入参 `{key, value}`。
  static const String storeWrite = 'store.write';

  /// 键是否存在。入参 `{key}`，返回 `{exists: bool}`。
  static const String storeHas = 'store.has';

  /// 删除键。入参 `{key}`，返回 `{removed: bool}`。
  static const String storeRemove = 'store.remove';

  /// 列出全部键（沙盒文件 IO 的「目录」口径）。返回 `{keys: [string]}`。
  static const String storeKeys = 'store.keys';

  /// 摘要（哈希）。入参 `{algorithm, data}`，返回 `{digest: string}`。
  ///
  /// 为什么由宿主算：Venera 源的 `Convert.md5` 需要一个 MD5 实现，而项目里已经有
  /// 一份经过标准向量验证的纯 Dart 实现（`core/util/md5.dart`）。让 JS 再写一份
  /// 等于把同一算法维护两遍——这里把计算收口到宿主，JS 侧只做调用。
  /// 未接入的算法（sha1 / sha256 / …）**明确报错**，不返回空值假装成功。
  static const String utilDigest = 'util.digest';
}
