import 'data_source.dart';

/// 图源管理端口：管理界面依赖的最小能力集。
///
/// 页面只认这个接口，不认识门面、注册表、沙箱与数据库；正式实现由
/// `LumeSources.manager(section)` 提供（薄委托，一个实例绑定一个板块）。
/// 测试可以注入替身，因此在没有图源运行时的平台（Windows / Android）上，
/// 导入、列表、启停、删除这套管理流程依然可被完整验证。
///
/// 板块归属：端口以「一个实例只服务一个板块」表达隔离，跨板块由实现侧保证；
/// 替身实现同样不得跨板块返回图源。
abstract interface class SourceManager {
  /// 当前平台是否提供图源运行时（Phase1 只在 iOS 成立）。
  bool get runtimeAvailable;

  /// 板块内的图源列表，按名称排序。
  Future<List<SourceDescriptor>> list();

  /// 板块内当前图源：没有显式选择时回退到第一个启用的图源；
  /// 板块内没有启用图源时返回 null。
  Future<SourceDescriptor?> current();

  /// 设定当前图源。图源不存在、跨板块或已停用时返回 null（且不改变现状）。
  Future<SourceDescriptor?> select(String sourceId);

  /// 导入图源脚本：成功返回描述符，失败返回可读原因。
  Future<SourceImportResult> importScript(String script);

  /// 启用 / 停用图源。停用即释放它的运行时。
  Future<void> setEnabled(String sourceId, bool enabled);

  /// 重命名图源：只改展示名，脚本与运行时保持原样。
  /// 图源不存在、跨板块或名为空时无操作（不改变现状）。
  Future<void> rename(String sourceId, String name);

  /// 设置单图源网络覆盖（UA / Cookie / 代理）。空串表示继承全局设置；
  /// 图源不存在或跨板块时无操作。
  Future<void> setNetwork(
    String sourceId, {
    required String userAgent,
    required String cookie,
    required String proxy,
  });

  /// 导出图源脚本原文（备份 / 迁移用）；不存在或跨板块时返回 null。
  Future<String?> exportScript(String sourceId);

  /// 删除图源（含其运行时与脚本）。
  Future<void> remove(String sourceId);

  /// 打开统一数据源（板块内的图源）。不存在、已禁用或脚本载入失败时返回 null。
  Future<DataSource?> open(String sourceId);

  /// 释放本板块的图源运行时与数据库连接（页面退出时调用）。
  void close();
}

/// 图源导入结果：成功携带描述符，失败携带可读原因。
class SourceImportResult {
  const SourceImportResult.success(this.descriptor) : message = null;

  const SourceImportResult.failure(this.message) : descriptor = null;

  final SourceDescriptor? descriptor;

  /// 失败原因（成功时为 null）。
  final String? message;

  bool get isSuccess => descriptor != null;
}
