import '../db/source_record.dart';
import '../js/cat_engines.dart';
import '../js/lume_js_engine.dart';
import '../js/sandbox/sandbox.dart';
import '../js/source_registry.dart';
import '../util/lume_log.dart';
import '../session/section.dart';
import 'data_source.dart';
import 'js_data_source.dart';
import '../net/source_subscription.dart';
import 'source_manager.dart';

/// 数据源门面：UI 侧访问图源的唯一入口，也是全项目唯一选择实现的地方。
///
/// UI 通过它做三件事：管理图源（列出 / 导入 / 启停 / 删除）、打开统一的
/// [DataSource]、在页面退出时释放板块资源。沙箱、脚本、数据库都封在内部。
///
/// 平台边界：Phase1 只有 iOS 提供图源运行时；其余平台上本门面一律降级——
/// 列表为空、打开返回 null，不触碰数据库与沙箱。
class LumeSources {
  LumeSources._();

  /// 当前平台是否提供图源运行时（Phase1 只在 iOS 成立）。
  ///
  /// 这是「小说 / 漫画 / 视频」的口径；猫源可能更宽（Android 上也有引擎），
  /// 按板块判断请用 [runtimeAvailableFor]。
  static bool get runtimeAvailable => LumeJsEngine.isSupported;

  /// 某板块在当前平台是否有图源运行时。
  ///
  /// 猫源：Android（QuickJS / Node-Mobile 二选一）+ iOS；
  /// 其余板块：仅 iOS（宪法第 1 条，Android / Windows 只保留骨架）。
  static bool runtimeAvailableFor(Section section) =>
      section == Section.cat ? CatEngines.available : runtimeAvailable;

  /// 板块内的图源列表，供管理界面展示。
  static Future<List<SourceDescriptor>> list(Section section) async {
    if (!runtimeAvailableFor(section)) return const <SourceDescriptor>[];
    final registry = await SourceRegistry.open(section);
    return registry.sources.map(_describe).toList(growable: false);
  }

  /// 导入图源脚本：先校验脚本，再把元信息与源码写入本板块数据库。
  /// 脚本不合法或平台不支持时返回带原因的失败结果。
  static Future<SourceImportResult> importScript(
    Section section,
    String script, {
    String originUrl = '',
  }) async {
    if (!runtimeAvailableFor(section)) {
      return const SourceImportResult.failure(
        '当前平台不提供图源运行时',
      );
    }
    final registry = await SourceRegistry.open(section);
    final outcome = await registry.import(script, originUrl: originUrl);
    final record = outcome.record;
    if (record == null) {
      return SourceImportResult.failure(outcome.message ?? '图源导入失败');
    }
    return SourceImportResult.success(_describe(record));
  }

  /// 板块内当前图源：没有显式选择时回退到第一个启用的图源；
  /// 板块内没有启用图源时返回 null。
  static Future<SourceDescriptor?> currentSource(Section section) async {
    if (!runtimeAvailableFor(section)) return null;
    final registry = await SourceRegistry.open(section);
    final record = registry.currentSource();
    return record == null ? null : _describe(record);
  }

  /// 设定当前图源。图源不存在、跨板块或已停用时返回 null。
  static Future<SourceDescriptor?> selectSource(
    Section section,
    String sourceId,
  ) async {
    if (!runtimeAvailableFor(section)) return null;
    final registry = await SourceRegistry.open(section);
    final record = registry.selectSource(sourceId);
    return record == null ? null : _describe(record);
  }

  /// 启用 / 停用图源。停用即释放它的运行时。
  static Future<void> setEnabled(
    Section section,
    String sourceId,
    bool enabled,
  ) async {
    if (!runtimeAvailableFor(section)) return;
    final registry = await SourceRegistry.open(section);
    registry.setEnabled(sourceId, enabled);
  }

  /// 设置单图源网络覆盖（UA / Cookie / 代理）；空串表示继承全局设置。
  static Future<void> setNetwork(
    Section section,
    String sourceId, {
    required String userAgent,
    required String cookie,
    required String proxy,
  }) async {
    if (!runtimeAvailableFor(section)) return;
    final registry = await SourceRegistry.open(section);
    registry.setSourceNetwork(
      sourceId,
      userAgent: userAgent,
      cookie: cookie,
      proxy: proxy,
    );
  }

  /// 重命名图源：只改本板块库里的展示名（脚本与运行时保持原样）。
  static Future<void> rename(
    Section section,
    String sourceId,
    String name,
  ) async {
    if (!runtimeAvailableFor(section)) return;
    final registry = await SourceRegistry.open(section);
    registry.rename(sourceId, name);
  }

  /// 导出图源脚本原文（备份用）；图源不存在或跨板块时返回 null。
  static Future<String?> exportScript(
    Section section,
    String sourceId,
  ) async {
    if (!runtimeAvailableFor(section)) return null;
    final registry = await SourceRegistry.open(section);
    return registry.scriptOf(sourceId);
  }

  /// 删除图源（含其运行时与脚本）。
  static Future<void> remove(Section section, String sourceId) async {
    if (!runtimeAvailableFor(section)) return;
    final registry = await SourceRegistry.open(section);
    registry.remove(sourceId);
  }

  /// 打开统一数据源。图源不存在、已禁用或脚本载入失败时返回 null。
  static Future<DataSource?> open(Section section, String sourceId) async {
    if (!runtimeAvailableFor(section)) return null;
    final registry = await SourceRegistry.open(section);
    SourceRecord? record;
    for (final item in registry.sources) {
      if (item.id == sourceId && item.enabled) {
        record = item;
        break;
      }
    }
    if (record == null) return null;
    if (await registry.engineFor(sourceId) == null) return null;
    return JsDataSource(
      id: record.id,
      name: record.name,
      section: section,
      runtime: _EngineRuntime(registry, sourceId),
    );
  }

  /// 更新订阅源：从记录里的订阅地址重新拉取脚本并覆盖导入。
  ///
  /// 覆盖走的是与导入完全相同的校验路径（脚本载入 → 元信息 → 落库），因此
  /// 更新后拿到的必然是一份能跑、且 id 合法的脚本；新脚本的 id 与旧的不同则
  /// 视为「换了图源」，如实报失败（避免用户以为更新成功、实际多出一个源）。
  static Future<SourceUpdateResult> updateFromSubscription(
    Section section,
    String sourceId, {
    SourceSubscription? subscription,
  }) async {
    if (!runtimeAvailableFor(section)) {
      return const SourceUpdateResult.skipped('当前平台不提供图源运行时');
    }
    final registry = await SourceRegistry.open(section);
    final record = registry.source(sourceId);
    if (record == null) {
      return const SourceUpdateResult.failed('图源不存在或不属于本板块');
    }
    if (!record.isSubscribed) {
      return const SourceUpdateResult.skipped(
        '本地导入的图源没有订阅地址，无法更新（可重新导入新脚本）',
      );
    }

    final resolver = subscription ??
        SourceSubscription.viaHttp();
    final List<String> scripts;
    try {
      scripts = await resolver.resolve(<String>[record.originUrl]);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return SourceUpdateResult.failed('订阅拉取失败：$error');
    }
    if (scripts.isEmpty) {
      return const SourceUpdateResult.failed('订阅里没有可用的图源脚本');
    }

    final script = scripts.first;
    if (script.trim() == record.script.trim()) {
      return SourceUpdateResult.unchanged(_describe(record));
    }

    final outcome = await registry.import(script, originUrl: record.originUrl);
    final updated = outcome.record;
    if (updated == null) {
      return SourceUpdateResult.failed(outcome.message ?? '更新失败');
    }
    if (updated.id != record.id) {
      return SourceUpdateResult.failed(
        '订阅里的脚本换了图源 id（原「${record.id}」→ 新「${updated.id}」），'
        '已按新脚本导入但未覆盖原图源；请检查订阅内容',
      );
    }
    // 覆盖导入不会动网络覆盖与来源地址（它们属于用户配置，不属于脚本）。
    return SourceUpdateResult.updated(_describe(updated));
  }

  /// 测试单个图源的连通性：载入脚本 → 取分类 → 取首屏列表。
  ///
  /// 只读操作：不动当前图源、不进页面、不改库。走的是与浏览完全相同的数据源
  /// 接口，因此「测试通过」等价于「浏览能出内容」。
  static Future<SourceTestResult> testConnectivity(
    Section section,
    String sourceId,
  ) async {
    if (!runtimeAvailableFor(section)) {
      return const SourceTestResult.failed('当前平台不提供图源运行时');
    }
    final registry = await SourceRegistry.open(section);
    final record = registry.source(sourceId);
    if (record == null) {
      return const SourceTestResult.failed('图源不存在或不属于本板块');
    }
    if (!record.enabled) {
      return const SourceTestResult.failed('图源已停用，先在列表里启用再测试');
    }

    final watch = Stopwatch()..start();
    try {
      final source = await open(section, sourceId);
      if (source == null) {
        return const SourceTestResult.failed('图源打不开（脚本载入失败或引擎不可用）');
      }

      // 分类失败不算致命：拿不到分类就当图源没有分类（与浏览面同一口径）。
      var categoryCount = 0;
      try {
        categoryCount = (await source.categories()).length;
      } on SourceException catch (error) {
        LumeLog.warn('[$sourceId] 测试：分类获取失败（不影响结论）: ${error.message}');
      }

      final list = await source.list(page: 1);
      watch.stop();
      if (list.items.isEmpty) {
        return SourceTestResult.empty(
          elapsed: watch.elapsed,
          message: '脚本能运行，但首屏没有返回任何条目（图源可能已改版）',
        );
      }
      return SourceTestResult.ok(
        itemCount: list.items.length,
        categoryCount: categoryCount,
        elapsed: watch.elapsed,
      );
    } on SourceException catch (error) {
      watch.stop();
      return SourceTestResult.failed(error.message);
    } catch (error, stackTrace) {
      watch.stop();
      LumeLog.error(error, stackTrace);
      return SourceTestResult.failed('测试异常：$error');
    }
  }

  /// 释放板块的全部图源运行时与数据库连接（页面退出时调用）。
  static void close(Section section) => SourceRegistry.close(section);

  /// 取板块的图源管理端口（一个实例只服务一个板块）。
  ///
  /// 管理界面默认用它；注入替身的场景（测试）不经过本方法。
  static SourceManager manager(Section section) => _LumeSourceManager(section);

  static SourceDescriptor _describe(SourceRecord record) => SourceDescriptor(
        id: record.id,
        name: record.name,
        version: record.version,
        enabled: record.enabled,
        network: record.network,
        originUrl: record.originUrl,
      );
}

/// [SourceManager] 的正式实现：把端口方法逐个委托给 [LumeSources] 的静态入口。
///
/// 它不新增任何能力，也不缓存状态——运行时、数据库与沙箱仍在注册表层，
/// 因此停用、删除、导入之后的行为与直接调用门面完全一致。
class _LumeSourceManager implements SourceManager {
  _LumeSourceManager(this._section);

  final Section _section;

  @override
  bool get runtimeAvailable => LumeSources.runtimeAvailableFor(_section);

  @override
  Future<List<SourceDescriptor>> list() => LumeSources.list(_section);

  @override
  Future<SourceDescriptor?> current() => LumeSources.currentSource(_section);

  @override
  Future<SourceDescriptor?> select(String sourceId) =>
      LumeSources.selectSource(_section, sourceId);

  @override
  Future<SourceImportResult> importScript(String script, {String originUrl = ''}) =>
      LumeSources.importScript(_section, script, originUrl: originUrl);

  @override
  Future<void> setEnabled(String sourceId, bool enabled) =>
      LumeSources.setEnabled(_section, sourceId, enabled);

  @override
  Future<void> setNetwork(
    String sourceId, {
    required String userAgent,
    required String cookie,
    required String proxy,
  }) =>
      LumeSources.setNetwork(
        _section,
        sourceId,
        userAgent: userAgent,
        cookie: cookie,
        proxy: proxy,
      );

  @override
  Future<void> rename(String sourceId, String name) =>
      LumeSources.rename(_section, sourceId, name);

  @override
  Future<String?> exportScript(String sourceId) =>
      LumeSources.exportScript(_section, sourceId);

  @override
  Future<void> remove(String sourceId) => LumeSources.remove(_section, sourceId);

  @override
  Future<DataSource?> open(String sourceId) =>
      LumeSources.open(_section, sourceId);

  @override
  Future<SourceTestResult> testConnectivity(String sourceId) =>
      LumeSources.testConnectivity(_section, sourceId);

  @override
  Future<SourceUpdateResult> updateFromSubscription(String sourceId) =>
      LumeSources.updateFromSubscription(_section, sourceId);

  @override
  void close() => LumeSources.close(_section);
}

/// 沙箱失败 → 数据源异常：把底层失败归一成展示层认识的三类。
///
/// 判定依据只有两处，都不靠猜文案：
/// - 沙箱给出的类型：已释放 / 平台不支持 → [SourceErrorKind.notFound]；
/// - 宿主代理在 HTTP 边界打出的网络标记 → [SourceErrorKind.network]；
/// - 其余（脚本 bug、超时、契约不符）→ [SourceErrorKind.callFailed]。
SourceException mapSandboxFailure(SandboxError error) {
  final kind = switch (error.kind) {
    SandboxErrorKind.disposed => SourceErrorKind.notFound,
    SandboxErrorKind.unsupported => SourceErrorKind.notFound,
    _ => error.message.contains(LumeSourceHost.networkFailureMarker)
        ? SourceErrorKind.network
        : SourceErrorKind.callFailed,
  };
  return SourceException(kind, error.toString());
}

/// 把图源引擎包装成 [JsSourceRuntime]。
///
/// 这是唯一知道「沙箱」与「数据源接口」如何对接的位置：引擎的失败结果在这里
/// 归一成 [SourceException]，沙箱类型不再向上层泄漏。运行时按需从注册表取，
/// 因此图源被停用后重建也能立刻生效，不会持有过期引擎。
class _EngineRuntime implements JsSourceRuntime {
  _EngineRuntime(this._registry, this._sourceId);

  final SourceRegistry _registry;
  final String _sourceId;

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    final engine = await _registry.engineFor(_sourceId);
    if (engine == null) {
      throw const SourceException(
        SourceErrorKind.notFound,
        '图源不可用（未启用或脚本载入失败）',
      );
    }
    final result = await engine.callResult(method, argument);
    if (result.isOk) return result.value;
    throw mapSandboxFailure(result.error!);
  }
}
