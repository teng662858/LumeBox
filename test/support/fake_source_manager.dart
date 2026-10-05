import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/source/source.dart';

/// 图源管理端口替身：只保留界面依赖的语义，不碰沙箱、数据库与网络。
///
/// 管理页与业务页的 widget 测试共用它。它同时是「Mock 仅限单元测试」这条
/// 约束的落点——生产代码里没有任何替身、也没有 Debug 专用入口。
///
/// 行为刻意与正式实现保持同一套语义：`current()` 未显式选择时回退到第一个
/// 启用图源，`select()` 只接受已启用的图源，停用/删除会即刻反映到列表上。
class FakeSourceManager implements SourceManager {
  FakeSourceManager({
    this.runtimeAvailable = true,
    List<SourceDescriptor> sources = const <SourceDescriptor>[],
    Map<String, DataSource>? opened,
  })  : sources = List<SourceDescriptor>.of(sources),
        opened = Map<String, DataSource>.of(
          opened ?? const <String, DataSource>{},
        );

  @override
  bool runtimeAvailable;

  /// 当前列表状态；导入、启停、删除都会更新它。
  final List<SourceDescriptor> sources;

  /// sourceId → 数据源。未登记时 open() 返回 null，用于验证「打不开」的路径。
  final Map<String, DataSource> opened;

  /// 当前图源。为空时按「第一个启用图源」回退。
  String? selected;

  final List<String> imported = <String>[];
  final List<(String, bool)> toggled = <(String, bool)>[];
  final List<(String, String)> renamed = <(String, String)>[];
  final List<String> exportedIds = <String>[];

  /// sourceId → 脚本原文（导出用；未登记时导出返回 null）。
  final Map<String, String> scripts = <String, String>{};

  final List<String> removed = <String>[];
  final List<String> openedIds = <String>[];
  final List<String> selectedIds = <String>[];
  bool closed = false;

  /// 非空时导入按失败返回该原因。
  String? importFailure;

  /// 非空时 `list()` 抛出它，用于验证管理页的存储故障分支。
  Object? listFailure;

  @override
  Future<List<SourceDescriptor>> list() async {
    final failure = listFailure;
    if (failure != null) throw failure;
    return List<SourceDescriptor>.of(sources);
  }

  @override
  Future<SourceDescriptor?> current() async {
    final enabled =
        sources.where((source) => source.enabled).toList(growable: false);
    if (enabled.isEmpty) return null;
    for (final source in enabled) {
      if (source.id == selected) return source;
    }
    return enabled.first;
  }

  @override
  Future<SourceDescriptor?> select(String sourceId) async {
    selectedIds.add(sourceId);
    final descriptor = _enabled(sourceId);
    if (descriptor == null) return null;
    selected = sourceId;
    return descriptor;
  }

  @override
  Future<DataSource?> open(String sourceId) async {
    openedIds.add(sourceId);
    return opened[sourceId];
  }

  /// 导入时记录的订阅来源（与 imported 一一对应）。
  final List<String> importedOrigins = <String>[];

  @override
  Future<SourceImportResult> importScript(
    String script, {
    String originUrl = '',
  }) async {
    imported.add(script);
    importedOrigins.add(originUrl);
    final failure = importFailure;
    if (failure != null) return SourceImportResult.failure(failure);
    const descriptor = SourceDescriptor(
      id: 'lume.new',
      name: '新图源',
      version: '1.0.0',
      enabled: true,
    );
    sources
      ..removeWhere((source) => source.id == descriptor.id)
      ..add(descriptor);
    return const SourceImportResult.success(descriptor);
  }

  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {
    toggled.add((sourceId, enabled));
    _replace(
      sourceId,
      (source) => SourceDescriptor(
        id: source.id,
        name: source.name,
        version: source.version,
        enabled: enabled,
      ),
    );
  }

  @override
  Future<void> rename(String sourceId, String name) async {
    renamed.add((sourceId, name));
    _replace(
      sourceId,
      (source) => SourceDescriptor(
        id: source.id,
        name: name,
        version: source.version,
        enabled: source.enabled,
      ),
    );
  }

  /// 记录网络覆盖设置：(sourceId, UA, Cookie, 代理)。
  final List<(String, String, String, String)> networks =
      <(String, String, String, String)>[];

  @override
  Future<void> setNetwork(
    String sourceId, {
    required String userAgent,
    required String cookie,
    required String proxy,
  }) async {
    networks.add((sourceId, userAgent, cookie, proxy));
    _replace(
      sourceId,
      (source) => SourceDescriptor(
        id: source.id,
        name: source.name,
        version: source.version,
        enabled: source.enabled,
        network: NetworkProfile(
          userAgent: userAgent,
          cookie: cookie,
          proxy: proxy,
        ),
      ),
    );
  }

  @override
  Future<String?> exportScript(String sourceId) async {
    exportedIds.add(sourceId);
    return scripts[sourceId];
  }

  @override
  Future<void> remove(String sourceId) async {
    removed.add(sourceId);
    sources.removeWhere((source) => source.id == sourceId);
  }

  /// 连通性测试结果（按 sourceId 配置）；未配置时按「能打开就可用」推断。
  final Map<String, SourceTestResult> testResults = <String, SourceTestResult>{};

  final List<String> testedIds = <String>[];

  @override
  Future<SourceTestResult> testConnectivity(String sourceId) async {
    testedIds.add(sourceId);
    final configured = testResults[sourceId];
    if (configured != null) return configured;
    // 默认口径：登记了数据源就当可用，否则按不可用报。
    if (opened.containsKey(sourceId)) {
      return const SourceTestResult.ok(
        itemCount: 1,
        categoryCount: 0,
        elapsed: Duration(milliseconds: 1),
      );
    }
    return const SourceTestResult.failed('图源打不开（脚本载入失败或引擎不可用）');
  }

  /// 订阅更新结果（按 sourceId 配置）；未配置时按「已是最新」推断。
  final Map<String, SourceUpdateResult> updateResults =
      <String, SourceUpdateResult>{};

  final List<String> updatedIds = <String>[];

  @override
  Future<SourceUpdateResult> updateFromSubscription(String sourceId) async {
    updatedIds.add(sourceId);
    final configured = updateResults[sourceId];
    if (configured != null) return configured;
    final descriptor = _enabled(sourceId);
    if (descriptor == null) {
      return const SourceUpdateResult.skipped('本地导入的图源没有订阅地址，无法更新');
    }
    return SourceUpdateResult.unchanged(descriptor);
  }

  @override
  void close() => closed = true;

  SourceDescriptor? _enabled(String sourceId) {
    for (final source in sources) {
      if (source.id == sourceId && source.enabled) return source;
    }
    return null;
  }

  void _replace(String id, SourceDescriptor Function(SourceDescriptor) update) {
    for (var index = 0; index < sources.length; index++) {
      if (sources[index].id == id) sources[index] = update(sources[index]);
    }
  }
}
