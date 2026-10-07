/// 图源引擎端口与提供方登记表（Phase3 附加扩展点）。
///
/// 设计意图：把「按引擎种类造引擎」从图源注册表里解耦出来。注册表（Phase1）
/// 只认 [SourceEngine] 端口与 [SourceEngineRegistry] 登记表，不再直接 new
/// 具体引擎；新增引擎（如 Android 的 Node-Mobile）只需登记一个工厂，既有
/// QuickJS 路径逐字节不变。
///
/// 平台边界（任务书第 1 条）：
/// - iOS：只登记 QuickJS-NG（Node-Mobile 不注册、原生也不进构建）；
/// - Android：登记 QuickJS-NG 与 Node-Mobile，二选一；
/// - 其他平台：没有引擎 → 猫源板块维持骨架。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/lume_http.dart';
import '../session/section.dart';
import '../util/lume_log.dart';
import 'lume_js_engine.dart';
import 'node_mobile_engine.dart';
import 'sandbox/sandbox_result.dart';

/// 图源引擎种类。
enum CatEngineKind {
  quickjs('quickjs', 'QuickJS-NG'),
  nodeMobile('nodeMobile', 'Node-Mobile');

  const CatEngineKind(this.id, this.label);

  /// 稳定标识：落库与登记表键名用。
  final String id;

  /// 显示名。
  final String label;

  /// 读取落库值；无法识别时回退 QuickJS（默认引擎）。
  static CatEngineKind fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return CatEngineKind.quickjs;
  }
}

/// 图源引擎端口：四套能力与既有 QuickJS 引擎一一对应，注册表只依赖它。
abstract interface class SourceEngine {
  /// 引擎种类标识。
  String get id;

  /// 脚本载入。失败返回 false。
  Future<bool> loadScript(String script);

  /// 脚本实际提供的契约方法（按别名表判定）；**null 表示该引擎无法判定**。
  ///
  /// 导入路径用它回答「这份脚本到底是不是本 App 的图源」：返回空集合即判定为
  /// 非源脚本（例如别的客户端的扩展程序包）。无法判定的引擎（返回 null）
  /// 不参与该判定，避免把「探不了」当成「没有」。
  Future<Set<String>?> contractMethods();

  /// 最近一次 [loadScript] 失败的原因（可读文本）；成功时为 null。
  ///
  /// 引擎侧给出的具体原因（哪个模块沙箱不支持、语法错在哪儿、加载超时）经这里
  /// 一路带到导入失败的提示里——用户要看到的是「沙箱不支持 dns」这种能行动的
  /// 原因，而不是一句笼统的「脚本载入失败」。
  String? get loadFailure;

  /// 读取脚本声明的元信息（id / name / version）。
  Future<Map<String, Object?>?> metadata();

  /// 调用图源方法，返回与沙箱同一套结果信封。
  Future<SandboxResult> callResult(String method, [Object? argument]);

  /// 释放引擎持有的全部资源。
  void dispose();
}

/// 引擎提供方：按标识造引擎。
typedef SourceEngineFactory = Future<SourceEngine?> Function({
  required String sourceId,
  required LumeHttp http,
  required Section section,
});

/// 引擎提供方登记表（Phase3 扩展点）。
///
/// 内置登记 QuickJS-NG；Android 构建额外登记 Node-Mobile（原生探测失败时
/// 工厂返回 null，引擎如实不可用）。测试可以覆盖登记项来驱动分支。
class SourceEngineRegistry {
  SourceEngineRegistry._();

  static final Map<String, SourceEngineFactory> _builtIn =
      <String, SourceEngineFactory>{
    CatEngineKind.quickjs.id: _createQuickJs,
    if (Platform.isAndroid) CatEngineKind.nodeMobile.id: _createNodeMobile,
  };

  static final Map<String, SourceEngineFactory> _factories =
      Map<String, SourceEngineFactory>.of(_builtIn);

  /// 引擎标识是否已登记（本平台有对应工厂）。
  static bool isRegistered(CatEngineKind kind) =>
      _factories.containsKey(kind.id);

  /// 该引擎在本平台是否可用（同步近似：只看登记与平台能力；
  /// Node-Mobile 的原生就绪由 [probe] 异步确认）。
  static bool isAvailable(CatEngineKind kind) => switch (kind) {
        CatEngineKind.quickjs => LumeJsEngine.isSupported,
        CatEngineKind.nodeMobile => Platform.isAndroid && isRegistered(kind),
      };

  /// 本平台可用的引擎列表（顺序即展示顺序）。
  static List<CatEngineKind> availableKinds() => CatEngineKind.values
      .where(isAvailable)
      .toList(growable: false);

  /// 造引擎。未登记、平台不支持或原生不可用时返回 null。
  static Future<SourceEngine?> create({
    required CatEngineKind kind,
    required String sourceId,
    required LumeHttp http,
    required Section section,
  }) {
    final factory = _factories[kind.id];
    if (factory == null) return Future<SourceEngine?>.value();
    return factory(sourceId: sourceId, http: http, section: section);
  }

  /// 异步探测各引擎就绪情况（Node-Mobile 需要问原生）。
  static Future<Map<CatEngineKind, bool>> probe(
    Iterable<CatEngineKind> kinds,
  ) async {
    final result = <CatEngineKind, bool>{};
    for (final kind in kinds) {
      switch (kind) {
        case CatEngineKind.quickjs:
          result[kind] = LumeJsEngine.isSupported;
        case CatEngineKind.nodeMobile:
          if (!Platform.isAndroid) {
            result[kind] = false;
          } else {
            result[kind] = await NodeMobileEngine(
              sourceId: '__probe__',
            ).isSupported();
          }
      }
    }
    return result;
  }

  /// 覆盖 / 新增登记项（测试与将来接入新引擎用）。
  static void register(CatEngineKind kind, SourceEngineFactory factory) {
    _factories[kind.id] = factory;
  }

  /// 还原到内置登记表。
  @visibleForTesting
  static void reset() {
    _factories
      ..clear()
      ..addAll(_builtIn);
  }

  // ------------------------------------------------------------------ 内置工厂

  static Future<SourceEngine?> _createQuickJs({
    required String sourceId,
    required LumeHttp http,
    required Section section,
  }) async {
    if (!LumeJsEngine.isSupported) return null;
    return QuickJsSourceEngine(
      await LumeJsEngine.create(
        sourceId: sourceId,
        http: http,
        section: section,
        // 桥接服务地址随图源交给脚本（`LumeSource.bridge`，用户口径 2.2）。
        bridge: http.bridge,
      ),
    );
  }

  static Future<SourceEngine?> _createNodeMobile({
    required String sourceId,
    required LumeHttp http,
    required Section section,
  }) async {
    if (!Platform.isAndroid) return null;
    final engine = NodeMobileEngine(sourceId: sourceId);
    if (!await engine.isSupported()) {
      // 原生模块未集成：如实不可用，不假装能跑。
      LumeLog.warn('[$sourceId] Node-Mobile 原生模块不可用');
      return null;
    }
    return NodeMobileSourceEngine(engine);
  }
}

/// QuickJS-NG 引擎的端口适配：调用全部直通既有引擎，无行为改动。
class QuickJsSourceEngine implements SourceEngine {
  QuickJsSourceEngine(this.engine);

  final LumeJsEngine engine;

  @override
  String get id => CatEngineKind.quickjs.id;

  @override
  Future<Set<String>?> contractMethods() => engine.contractMethods();

  @override
  Future<bool> loadScript(String script) => engine.loadScript(script);

  @override
  String? get loadFailure => engine.lastLoadFailure?.message;

  @override
  Future<Map<String, Object?>?> metadata() => engine.metadata();

  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) =>
      engine.callResult(method, argument);

  @override
  void dispose() => engine.dispose();
}

/// Node-Mobile 引擎的端口适配。释放是异步的（要通知原生杀实例），
/// 端口侧按既有语义保持同步：这里发出销毁并记录失败，不阻塞调用方。
class NodeMobileSourceEngine implements SourceEngine {
  NodeMobileSourceEngine(this.engine);

  final NodeMobileEngine engine;

  @override
  String get id => CatEngineKind.nodeMobile.id;

  @override
  Future<bool> loadScript(String script) => engine.loadScript(script);

  @override
  String? get loadFailure => engine.loadFailure;

  /// Node-Mobile 侧还没有等价的契约探测：返回 null 表示「无法判定」，
  /// 导入路径据此跳过「是不是源脚本」这道门禁（保持该引擎既有行为不变）。
  @override
  Future<Set<String>?> contractMethods() async => null;

  @override
  Future<Map<String, Object?>?> metadata() => engine.metadata();

  @override
  Future<SandboxResult> callResult(String method, [Object? argument]) =>
      engine.callResult(method, argument);

  @override
  void dispose() {
    engine.dispose().catchError((Object error, StackTrace stackTrace) {
      LumeLog.error(error, stackTrace);
    });
  }
}
