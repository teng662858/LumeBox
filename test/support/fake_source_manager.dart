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

  @override
  Future<SourceImportResult> importScript(String script) async {
    imported.add(script);
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
  Future<void> remove(String sourceId) async {
    removed.add(sourceId);
    sources.removeWhere((source) => source.id == sourceId);
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
