import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../net/lume_http.dart';
import '../session/section.dart';
import '../util/md5.dart';
import '../util/lume_log.dart';
import 'cat_polyfills.dart';
import 'sandbox/sandbox.dart';
import 'sandbox_settings.dart';
import 'source_bridge.dart';
import 'venera_bridge.dart';
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
  LumeJsEngine._(this.sourceId, this.section, this._sandbox, this._host);

  /// 图源标识。
  final String sourceId;

  /// 所属板块。Venera 风格脚本只在漫画板块认领（见 [loadScript]）。
  final Section section;

  final LumeSandbox _sandbox;

  /// 宿主代理：持有沙盒存储（`LumeSource.fs` 的后端），随引擎释放。
  final LumeSourceHost _host;

  /// 单次图源调用的墙钟预算：**取自全局沙箱设置**（设置页可配，文档要求 3–5 秒）。
  ///
  /// 此前是写死的 `SandboxPolicy.defaultTimeout`；现在每次创建引擎时从
  /// [LumeSandboxSettings] 读，因此用户改了设置后**新建的引擎立即生效**。
  /// 已经在跑的引擎在下次被重建时（覆盖导入 / 停用重启用 / 超时销毁后重建）
  /// 自然跟随——不需要为了改超时去逐个销毁现有引擎。
  static Duration get callTimeout => LumeSandboxSettings.current.timeout;

  /// 图源脚本允许访问的唯一外部能力：网络请求，且必须经 [LumeSourceHost] 发出。
  /// 其余宿主方法一律拒绝。
  ///
  /// 策略在标准预设上**只改超时**（见 [SandboxSettings.policy]）：内存 / 栈 /
  /// 指令计数等安全上限不开放给设置页，调大它们等于关掉防死循环的保护。
  static SandboxPolicy get policy => LumeSandboxSettings.policy;

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
    String bridge = '',
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Phase1 源引擎仅随 iOS 提供');
    }
    // 沙箱身份自带板块前缀（`<板块>:<来源>`），宿主按同一口径校验请求身份，
    // 因此跨板块串线会在第一跳被拒（见 [LumeSourceHost.invoke]）。
    final sandboxId = LumeSourceHost.sandboxIdFor(section, sourceId);
    final host = LumeSourceHost(
      http,
      timeout: callTimeout,
      section: section,
      sourceId: sourceId,
    );
    final sandbox = LumeSandbox.create(
      id: sandboxId,
      policy: policy.copyWith(allowHostAccess: true),
      host: host,
      polyfills: LumeSourcePolyfills.forSection(section, bridge: bridge),
    );
    return LumeJsEngine._(sourceId, section, sandbox, host);
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
  ///
  /// 漫画板块额外做一件事：**认领 Venera 风格脚本**。Venera 的源只写
  /// `class X extends ComicSource { … }`，没有任何注册语句，类名也不挂在
  /// globalThis 上；这里从文本里读出类名，让沙箱里的 Venera 垫片按名字实例化它
  /// （见 `venera_bridge.dart`）。认领成功后，元信息与五个契约方法都由垫片挂到
  /// `LumeSource` 上，**后续链路（元信息读取、板块校验、数据源适配、页面）
  /// 一行都不用改**。
  ///
  /// 认领失败（例如脚本里没有子类、或 `init()` 抛错）时如实失败：导入阶段就把
  /// 原因说清楚，好过导入成功、用的时候才炸。
  Future<bool> loadScript(String script) async {
    final result = await _sandbox.load(script);
    if (!result.isOk) {
      _loadFailure = result.error;
      return false;
    }
    _loadFailure = null;
    if (section != Section.cat) {
      final adopted = await _adoptVenera(script);
      if (!adopted) return false;
    }
    return true;
  }

  /// 认领 Venera 子类；非 Venera 脚本（不含 `extends ComicSource`）直接放行。
  Future<bool> _adoptVenera(String script) async {
    if (!VeneraScriptSource.looksVenera(script)) return true;
    final className = VeneraScriptSource.classNameOf(script);
    if (className == null) {
      _loadFailure = const SandboxError(
        SandboxErrorKind.script,
        'Venera 脚本里没有找到 `class X extends ComicSource` 子类',
      );
      return false;
    }
    final result = await _sandbox.eval(
      '__lumeVeneraAdopt(${jsonEncode(className)})',
      fileName: '$sourceId.venera.js',
    );
    if (result.isOk) return true;
    _loadFailure = SandboxError(
      SandboxErrorKind.script,
      'Venera 源认领失败（$className）：${result.error?.message ?? '未知原因'}',
    );
    LumeLog.warn('[$sourceId] $_loadFailure');
    return false;
  }

  /// 脚本实际提供的契约方法（按别名表判定：`getList` 与 `list` 都算 list）。
  ///
  /// 导入路径用它回答一个基本问题：**这份脚本到底是不是本 App 的图源**。
  /// 一份什么都不提供的脚本（例如别的客户端的扩展程序包：自带本地服务端、
  /// 靠自有宿主桥通信）载入会成功，但用起来是空的——在导入阶段拦下，
  /// 比导入后点开一片空白好。
  Future<Set<String>> contractMethods() async {
    final result = await _sandbox.eval(
      'JSON.stringify(typeof __lumeContractMethods === "function" '
      '? __lumeContractMethods() : [])',
    );
    final value = result.value;
    // 沙箱的 eval 已经按 JSON 解码：数组直接就是 List；文本形态留作兜底
    // （将来若有引擎只回原始文本）。
    if (value is List) return value.map((item) => '$item').toSet();
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) return decoded.map((item) => '$item').toSet();
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
      }
    }
    if (!result.isOk) {
      LumeLog.warn('[$sourceId] 契约方法探测失败: ${result.error?.message ?? '未知原因'}');
    }
    return const <String>{};
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
///
/// 身份校验：宿主只服务**一个板块的一个图源**，并在入口核对请求声明的沙箱身份
/// （[expectedSandboxId]）。沙箱身份自带板块前缀，因此「A 板块的脚本打到 B 板块
/// 的宿主」这类串线会在第一跳被拒绝，而不是靠「每个板块各自建宿主」这个约定
/// 默默兜住——约定会被重构改掉，校验不会。
class LumeSourceHost implements SandboxHost {
  LumeSourceHost(
    this._http, {
    required this.timeout,
    required this.section,
    required this.sourceId,
    SandboxStore? store,
  })  : _store = store ?? SandboxStore(),
        expectedSandboxId = sandboxIdFor(section, sourceId);

  /// 网络失败的稳定标记。请求没能完成时打在异常文本前面，上层据此把
  /// 「网络异常」从「脚本报错」里分出来（见数据源层的沙箱失败归一）。
  static const String networkFailureMarker = '网络请求失败';

  /// 本宿主服务的板块。与 [sourceId] 一起构成它接受的身份。
  final Section section;

  /// 本宿主服务的图源。
  final String sourceId;

  /// 本宿主接受的沙箱身份（`<板块>:<来源>`）。
  final String expectedSandboxId;

  /// 沙箱身份的唯一构造口径：`<板块 id>:<图源 id>`。
  ///
  /// 板块前缀让隔离**可被机器校验**，也让日志与内存内存储命名空间自带板块信息
  /// （排查时不必反查某个来源属于哪个板块）。
  static String sandboxIdFor(Section section, String sourceId) =>
      '${section.id}:$sourceId';

  final LumeHttp _http;

  /// 单次请求超时。
  final Duration timeout;

  /// 沙盒文件 IO 的后端（`LumeSource.fs`）。
  final SandboxStore _store;

  /// 沙盒存储的访问口（测试与诊断用；与 [invoke] 操作的是同一张表）。
  SandboxStore get store => _store;

  @override
  Future<Object?> invoke(SandboxHostRequest request) async {
    // 身份先于能力：声明与宿主不符即拒绝，且不触达 http 与 store。
    if (request.sandboxId != expectedSandboxId) {
      final message = '拒绝跨沙箱宿主调用：请求声明「${request.sandboxId}」，'
          '本宿主服务「$expectedSandboxId」（${section.label}板块）。';
      LumeLog.warn('[${section.id}] $message');
      throw SandboxHostException(message);
    }
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
      case SandboxHostMethods.utilDigest:
        return _digest(request.payload);
      default:
        throw SandboxHostException('源未授权的宿主方法: ${request.method}');
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

  /// 摘要计算：当前只接入 md5（Venera 源的 `Convert.md5` 用它）。
  ///
  /// 未接入的算法直接抛可读错误：让脚本作者立刻知道「这个能力没有」，
  /// 而不是拿到一个空串继续往下跑、最后在别处炸。
  Object? _digest(Object? payload) {
    if (payload is! Map) {
      throw const SandboxHostException('util.digest 入参必须是对象');
    }
    final algorithm = '${payload['algorithm'] ?? ''}'.trim().toLowerCase();
    final data = '${payload['data'] ?? ''}';
    switch (algorithm) {
      case 'md5':
        final bytes = Md5.digest(utf8.encode(data));
        final buffer = StringBuffer();
        for (final byte in bytes) {
          buffer.write(byte.toRadixString(16).padLeft(2, '0'));
        }
        return <String, Object?>{'digest': buffer.toString()};
      default:
        throw SandboxHostException(
          '暂不支持的摘要算法：$algorithm（当前支持：md5）',
        );
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

/// 图源层的注入垫片：把 `fetch` 接到宿主代理上，并注入桥接全局 `LumeSource`。
///
/// 这是沙箱垫片机制的接入示例——沙箱本身不提供任何网络能力，
/// 图源需要的 `fetch` 与 `LumeSource` 由本层按需注册。
///
/// 登记顺序 = 注入顺序（`PolyfillRegistry.ordered` 按依赖与登记序排）：
/// 环境垫片在前，`LumeSource` 桥接在最后——脚本执行前，桥接一定已经就位。
class LumeSourcePolyfills {
  LumeSourcePolyfills._();

  /// 通用图源沙箱使用的垫片登记表（网络代理 + 桥接对象 + Venera 兼容层）。
  ///
  /// Venera 兼容层（`ComicSource` / `Network` / `HtmlDocument` 等）放在**通用表**
  /// 里，是为了让「Venera 源被导入错板块」给出人话：脚本载入后自报 comic，
  /// 于是小说 / 视频板块的导入会走既有的跨板块校验被拦下；
  /// 若只在漫画板块注入，误导入的报错会是「ComicSource is not defined」——
  /// 用户看不出这是板块问题。猫源有自己的登记表，拿不到这一层。
  static final PolyfillRegistry registry = PolyfillRegistry(
    <SandboxPolyfill>[
      const _FetchPolyfill(),
      const LumeSourceBridgePolyfill(),
      const VeneraComicSourcePolyfill(),
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

  /// 按板块选登记表：**猫源的 Node 环境不外借**（宪法第 3 条），
  /// 其余三个板块共用通用表（含 Venera 兼容层）。
  static PolyfillRegistry forSection(Section section, {String bridge = ''}) {
    // 有桥接地址时按图源单独组装一份（桥接是图源级配置，不能污染共享登记表）。
    if (bridge.trim().isNotEmpty) {
      return PolyfillRegistry(<SandboxPolyfill>[
        const _FetchPolyfill(),
        if (section == Section.cat) ...CatPolyfills.all,
        LumeSourceBridgePolyfill(null, bridge.trim()),
        if (section != Section.cat) const VeneraComicSourcePolyfill(),
      ]);
    }
    return section == Section.cat ? catRegistry : registry;
  }
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
