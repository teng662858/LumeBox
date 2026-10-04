import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../net/lume_http.dart';
import '../session/section.dart';
import 'cat_polyfills.dart';
import 'sandbox/sandbox.dart';

/// 图源脚本的 JS 运行时。
///
/// 本层只负责「图源业务」：脚本载入、`LumeSource` 元信息、方法调用，以及把
/// `fetch` 桥接到所属板块的 [LumeHttp]。所有沙箱细节（上下文生命周期、
/// 超时与预算、污染销毁重建、原生句柄）都下沉到 `sandbox/`，
/// 本文件不再直接触碰 QuickJS 句柄。
///
/// 隔离模型：一个图源独占一个 [LumeSandbox]，即独占一个 JSRuntime + JSContext，
/// 图源之间不共享任何运行时状态。
class LumeJsEngine {
  LumeJsEngine._(this.sourceId, this._sandbox);

  /// 图源标识。
  final String sourceId;

  final LumeSandbox _sandbox;

  /// 单次图源调用的墙钟预算：与沙箱策略一致，收敛在 3–5 秒。
  static const Duration callTimeout = SandboxPolicy.defaultTimeout;

  /// 图源脚本允许访问的唯一外部能力：网络请求，且必须经 [LumeSourceHost] 发出。
  /// 其余宿主方法一律拒绝。
  static const SandboxPolicy policy = SandboxPolicy.standard;

  /// Phase1 的图源引擎只随 iOS 提供：插件的原生库仅通过 iOS 的
  /// `DynamicLibrary.process()` 可加载，Android / Windows 按宪法仅保留空页面骨架。
  static bool get isSupported => Platform.isIOS && LumeSandbox.isSupported;

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
    return LumeJsEngine._(sourceId, sandbox);
  }

  /// 当前上下文代数。污染重建后递增。
  int get generation => _sandbox.generation;

  /// 上下文是否已被判定污染（超时、引擎级异常等）。
  bool get isPoisoned => _sandbox.isPoisoned;

  /// 载入图源脚本。脚本通过全局 `LumeSource` 暴露能力。
  Future<bool> loadScript(String script) async =>
      (await _sandbox.load(script)).isOk;

  /// 读取脚本声明的元信息（id / name / version），失败返回 null。
  Future<Map<String, Object?>?> metadata() async {
    final result = await _sandbox.eval(
      'JSON.stringify({id: LumeSource.id, name: LumeSource.name, '
      'version: LumeSource.version})',
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

  /// 释放沙箱。上下文被同步销毁，内存随之回收。
  void dispose() => _sandbox.dispose();
}

/// 图源宿主代理：JS 侧唯一的外部能力通道。
///
/// JS 里没有 socket、没有文件、没有 require；`fetch` 只是 [SandboxHostMethods.httpFetch]
/// 的语法糖，最终由本类的 [invoke] 经 [LumeHttp] 发出真实请求。
class LumeSourceHost implements SandboxHost {
  LumeSourceHost(this._http, {required this.timeout});

  /// 网络失败的稳定标记。请求没能完成时打在异常文本前面，上层据此把
  /// 「网络异常」从「脚本报错」里分出来（见数据源层的沙箱失败归一）。
  static const String networkFailureMarker = '网络请求失败';

  final LumeHttp _http;

  /// 单次请求超时。
  final Duration timeout;

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    switch (request.method) {
      case SandboxHostMethods.httpFetch:
        return _fetch(request.payload);
      case SandboxHostMethods.storeRead:
      case SandboxHostMethods.storeWrite:
        throw const SandboxHostException('图源存储能力尚未开放');
      default:
        throw SandboxHostException('图源未授权的宿主方法: ${request.method}');
    }
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

/// 图源层的注入垫片：把 `fetch` 接到宿主代理上。
///
/// 这是沙箱垫片机制的接入示例——沙箱本身不提供任何网络能力，
/// 图源需要的 `fetch` 由本层按需注册。
class LumeSourcePolyfills {
  LumeSourcePolyfills._();

  /// 通用图源沙箱使用的垫片登记表（只有网络代理这一项）。
  static final PolyfillRegistry registry = PolyfillRegistry(
    <SandboxPolyfill>[const _FetchPolyfill()],
  );

  /// 猫源沙箱的垫片登记表：通用垫片之上叠加猫源环境垫片
  /// （process / Buffer / 基础 require / console 补全 / 定时器补全）。
  static final PolyfillRegistry catRegistry = PolyfillRegistry(
    <SandboxPolyfill>[const _FetchPolyfill(), ...CatPolyfills.all],
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
