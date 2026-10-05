import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../net/lume_http.dart';
import '../session/section.dart';
import 'cat_polyfills.dart';
import 'sandbox/sandbox.dart';
import 'source_bridge.dart';
import 'source_store.dart';

/// 图源脚本的 JS 运行时。
///
/// 本层只负责「图源业务」：脚本载入、`LumeSource` 元信息、方法调用，以及把
/// `fetch` 桥接到所属板块的 [LumeHttp]。所有沙箱细节（上下文生命周期、
/// 超时与预算、污染销毁重建、原生句柄）都下沉到 `sandbox/`，
/// 本文件不再直接触碰 QuickJS 句柄。
///
/// 隔离模型：一个图源独占一个 [LumeSandbox]，即独占一个 JSRuntime + JSContext，
/// 图源之间不共享任何运行时状态；沙盒存储（`LumeSource.fs`）同样一图源一份，
/// 随引擎释放。
///
/// 启动顺序（严格，用户口径 1→4；实现落在 [SandboxContext] 与本文件）：
/// 1. 建虚拟机（JSRuntime + JSContext）；
/// 2. 注入环境垫片：console / 定时器（沙箱 prelude）、process / Buffer /
///    简易 require（猫源 Node 垫片）、`fetch`（网络垫片）；
/// 3. 注入桥接全局 `LumeSource`（见 [LumeSourceBridgePolyfill]：宿主 HTTP 与
///    沙盒文件 IO 的语法糖 + 五个契约方法的派发器）；
/// 4. 载入并执行用户图源脚本。
/// 垫片登记表的顺序就是注入顺序（见 [LumeSourcePolyfills]）。
class LumeJsEngine {
  LumeJsEngine._(this.sourceId, this._sandbox, this._host);

  /// 图源标识。
  final String sourceId;

  final LumeSandbox _sandbox;

  /// 宿主代理：持有沙盒存储（`LumeSource.fs` 的后端），随引擎释放。
  final LumeSourceHost _host;

  /// 单次图源调用的墙钟预算：与沙箱策略一致，收敛在 3–5 秒。
  static const Duration callTimeout = SandboxPolicy.defaultTimeout;

  /// 图源脚本允许访问的唯一外部能力：网络请求，且必须经 [LumeSourceHost] 发出。
  /// 其余宿主方法一律拒绝。
  static const SandboxPolicy policy = SandboxPolicy.standard;

  /// Phase1 的图源引擎只随 iOS 提供：插件的原生库仅通过 iOS 的
  /// `DynamicLibrary.process()` 可加载，Android / Windows 按宪法仅保留空页面骨架。
  ///
  /// [debugSupportedOverride] 是测试注入点（与 `CatEngines.debugPlatformOverride`
  /// 同一套做法）：测试在原生桥可用的机器上（Windows 需先 `flutter build windows`）
  /// 把它置 true，就能在非 iOS 平台驱动真实引擎与整条导入链路。
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported =>
      (debugSupportedOverride ?? Platform.isIOS) && LumeSandbox.isSupported;

  /// 创建引擎。一个引擎对应一个隔离沙箱；垫片按板块选择
  /// （猫源专属垫片只进猫源的上下文，见 [LumeSourcePolyfills.forSection]）。
  static Future<LumeJsEngine> create({
    required String sourceId,
    required LumeHttp http,
    required Section section,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Phase1 图源引擎仅随 iOS 提供');
    }
    final host = LumeSourceHost(http, timeout: callTimeout);
    final sandbox = LumeSandbox.create(
      id: sourceId,
      policy: policy.copyWith(allowHostAccess: true),
      host: host,
      polyfills: LumeSourcePolyfills.forSection(section),
    );
    return LumeJsEngine._(sourceId, sandbox, host);
  }

  /// 当前上下文代数。污染重建后递增。
  int get generation => _sandbox.generation;

  /// 上下文是否已被判定污染（超时、引擎级异常等）。
  bool get isPoisoned => _sandbox.isPoisoned;

  /// 最近一次 [loadScript] 失败的原因；成功或尚未载入时为 null。
  ///
  /// 沙箱把失败分类与原因都收在 [SandboxError] 里，这里留一份给导入口径用：
  /// 用户看到的应当是「沙箱不支持 dns」这种能行动的原因，而不是一句笼统的
  /// 「脚本载入失败」。
  SandboxError? _loadFailure;

  SandboxError? get lastLoadFailure => _loadFailure;

  /// 载入图源脚本。脚本通过全局 `LumeSource` 暴露能力。
  Future<bool> loadScript(String script) async {
    final result = await _sandbox.load(script);
    _loadFailure = result.isOk ? null : result.error;
    return result.isOk;
  }

  /// 读取脚本声明的元信息（id / name / version / category），失败返回 null。
  ///
  /// `category` 是脚本自报的归属板块（可选）：导入路径据此拒绝跨板块图源。
  /// 脚本没声明时该字段为空串，归属仍由导入入口决定。
  Future<Map<String, Object?>?> metadata() async {
    final result = await _sandbox.eval(
      'JSON.stringify({id: LumeSource.id, name: LumeSource.name, '
      'version: LumeSource.version, category: LumeSource.category})',
      fileName: 'metadata.js',
    );
    if (!result.isOk) return null;
    final value = result.value;
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  /// 调用图源方法并解析其 JSON 结果。失败返回 null。
  Future<Object?> call(String method, [Object? argument]) async {
    final result = await _sandbox.call('LumeSource.$method', argument);
    return result.isOk ? result.value : null;
  }

  /// 与 [call] 同语义，但保留失败细节：成功时返回 [SandboxResult]（其值可能
  /// 是 JSON null，表示脚本显式返回空），失败时携带具体错误分类。
  ///
  /// 供数据源适配层区分「脚本返回 null」与「调用失败」——[call] 做不到这一点。
  Future<SandboxResult> callResult(String method, [Object? argument]) =>
      _sandbox.call('LumeSource.$method', argument);

  /// 释放沙箱。上下文被同步销毁，内存随之回收；
  /// 沙盒存储（`LumeSource.fs` 的进程内表）也在这一步清空。
  void dispose() {
    _sandbox.dispose();
    _host.dispose();
  }
}

/// 图源宿主代理：JS 侧唯一的外部能力通道。
///
/// JS 里没有 socket、没有文件、没有 require；`fetch` 与桥接对象 `LumeSource` 的
/// `http.*` 都只是 [SandboxHostMethods.httpFetch] 的语法糖，`LumeSource.fs.*`
/// 则落在 [SandboxStore]（按图源隔离的进程内存储，不落盘、有上限），
/// 最终由本类的 [invoke] 经 [LumeHttp] 与存储表落地。
class LumeSourceHost implements SandboxHost {
  LumeSourceHost(this._http, {required this.timeout, SandboxStore? store})
      : _store = store ?? SandboxStore();

  /// 网络失败的稳定标记。请求没能完成时打在异常文本前面，上层据此把
  /// 「网络异常」从「脚本报错」里分出来（见数据源层的沙箱失败归一）。
  static const String networkFailureMarker = '网络请求失败';

  final LumeHttp _http;

  /// 单次请求超时。
  final Duration timeout;

  /// 沙盒文件 IO 的后端（`LumeSource.fs`）。
  final SandboxStore _store;

  /// 沙盒存储的访问口（测试与诊断用；与 [invoke] 操作的是同一张表）。
  SandboxStore get store => _store;

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    switch (request.method) {
      case SandboxHostMethods.httpFetch:
        return _fetch(request.payload);
      case SandboxHostMethods.storeRead:
        return _storeRead(request.payload);
      case SandboxHostMethods.storeWrite:
        return _storeWrite(request.payload);
      case SandboxHostMethods.storeHas:
        return <String, Object?>{'exists': _store.containsKey(_key(request.payload))};
      case SandboxHostMethods.storeRemove:
        return <String, Object?>{'removed': _store.remove(_key(request.payload))};
      case SandboxHostMethods.storeKeys:
        return <String, Object?>{'keys': _store.keys()};
      default:
        throw SandboxHostException('图源未授权的宿主方法: ${request.method}');
    }
  }

  /// 释放宿主侧资源：清空沙盒存储（引擎释放时调用）。
  void dispose() => _store.clear();

  Object? _storeRead(Object? payload) {
    return <String, Object?>{'value': _store.read(_key(payload))};
  }

  Object? _storeWrite(Object? payload) {
    if (payload is! Map) {
      throw const SandboxHostException('store.write 入参必须是对象');
    }
    final key = _key(payload);
    final value = payload['value'];
    if (value != null && value is! String) {
      throw const SandboxHostException('store.write 的 value 必须是字符串');
    }
    _store.write(key, value == null ? '' : value as String);
    return const <String, Object?>{'ok': true};
  }

  /// 取存储键。路径归一在 [SandboxStore] 里做，这里只保证「有 key」。
  String _key(Object? payload) {
    if (payload is! Map) {
      throw const SandboxHostException('存储调用入参必须是对象');
    }
    final key = '${payload['key'] ?? ''}'.trim();
    if (key.isEmpty) {
      throw const SandboxHostException('存储调用缺少 key');
    }
    return key;
  }

  Future<Map<String, Object?>> _fetch(Object? payload) async {
    if (payload is! Map) {
      throw const SandboxHostException('http.fetch 入参必须是对象');
    }
    final url = '${payload['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      throw const SandboxHostException('http.fetch 缺少 url');
    }
    final LumeHttpResponse response;
    try {
      response = await _http.send(
        url: url,
        method: '${payload['method'] ?? 'GET'}',
        headers: _stringMap(payload['headers']),
        body: payload['body'] == null ? null : '${payload['body']}',
        timeout: timeout,
      );
    } on Object catch (error) {
      if (!_isNetworkFailure(error)) rethrow;
      throw SandboxHostException('$networkFailureMarker：$error');
    }
    return <String, Object?>{
      'status': response.statusCode,
      'headers': response.headers,
      'body': response.text,
    };
  }

  /// 请求没能完成的情形：超时、连接/协议中断、客户端异常。
  /// 其余异常（例如脚本给了非法入参）不算网络问题，原样上抛。
  static bool _isNetworkFailure(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is http.ClientException;

  static Map<String, String>? _stringMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry('$key', '$item'));
  }
}

/// 图源层的注入垫片：把 `fetch` 接到宿主代理上，并注入桥接全局 `LumeSource`。
///
/// 这是沙箱垫片机制的接入示例——沙箱本身不提供任何网络能力，
/// 图源需要的 `fetch` 与 `LumeSource` 由本层按需注册。
///
/// 登记顺序 = 注入顺序（`PolyfillRegistry.ordered` 按依赖与登记序排）：
/// 环境垫片在前，`LumeSource` 桥接在最后——脚本执行前，桥接一定已经就位。
class LumeSourcePolyfills {
  LumeSourcePolyfills._();

  /// 通用图源沙箱使用的垫片登记表（网络代理 + 桥接对象）。
  static final PolyfillRegistry registry = PolyfillRegistry(
    <SandboxPolyfill>[
      const _FetchPolyfill(),
      const LumeSourceBridgePolyfill(),
    ],
  );

  /// 猫源沙箱的垫片登记表：通用垫片之上叠加猫源环境垫片
  /// （process / Buffer / 基础 require / console 补全 / 定时器补全），
  /// 桥接对象同样在最后注入。
  static final PolyfillRegistry catRegistry = PolyfillRegistry(
    <SandboxPolyfill>[
      const _FetchPolyfill(),
      ...CatPolyfills.all,
      const LumeSourceBridgePolyfill(),
    ],
  );

  /// 按板块选登记表：**垫片补全只对猫源开放**，其他板块拿到的仍是通用表——
  /// 猫源的沙箱环境不与其他板块共用（宪法第 3 条）。
  static PolyfillRegistry forSection(Section section) =>
      section == Section.cat ? catRegistry : registry;
}

class _FetchPolyfill implements SandboxPolyfill {
  const _FetchPolyfill();

  @override
  String get id => 'lume.source.fetch';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.LumeBridge !== 'object') return;
  globalThis.fetch = function (url, options) {
    options = options || {};
    return globalThis.LumeBridge.invoke('http.fetch', {
      url: String(url),
      method: options.method || 'GET',
      headers: options.headers || {},
      body: options.body == null ? null : String(options.body)
    }).then(function (reply) {
      reply = reply || {};
      var body = reply.body == null ? '' : String(reply.body);
      return {
        status: reply.status == null ? 0 : reply.status,
        headers: reply.headers || {},
        body: body,
        text: function () { return Promise.resolve(body); },
        json: function () { return Promise.resolve(JSON.parse(body || 'null')); }
      };
    });
  };
})();
''';
}
