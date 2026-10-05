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
  /// 导入图源脚本。[originUrl] 非空表示来自订阅链接（记下来供「更新订阅源」
  /// 重新拉取）；本地导入留空。
  Future<SourceImportResult> importScript(String script, {String originUrl = ''});

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

  /// 更新订阅源：从它记录里的订阅地址重新拉取脚本并覆盖导入。
  ///
  /// 只对**订阅导入**的图源有效（本地导入的没有来源地址）；不是订阅源时返回
  /// 带说明的失败结果，而不是静默无事发生。
  Future<SourceUpdateResult> updateFromSubscription(String sourceId);

  /// 测试单个图源的连通性：走一遍「载入脚本 → 取分类 → 取列表」。
  ///
  /// 与「浏览」的区别是它**不改动任何状态**（不动当前图源、不进页面），只回报
  /// 结果；供管理页的「测试」按钮与批量测试使用。
  Future<SourceTestResult> testConnectivity(String sourceId);

  /// 释放本板块的图源运行时与数据库连接（页面退出时调用）。
  void close();
}

/// 订阅更新的结论。
class SourceUpdateResult {
  const SourceUpdateResult._({
    required this.status,
    required this.message,
    this.descriptor,
  });

  const SourceUpdateResult.updated(SourceDescriptor descriptor)
      : this._(
          status: SourceUpdateStatus.updated,
          message: '',
          descriptor: descriptor,
        );

  const SourceUpdateResult.unchanged(SourceDescriptor descriptor)
      : this._(
          status: SourceUpdateStatus.unchanged,
          message: '',
          descriptor: descriptor,
        );

  const SourceUpdateResult.skipped(String message) : this._(
          status: SourceUpdateStatus.skipped,
          message: message,
        );

  const SourceUpdateResult.failed(String message) : this._(
          status: SourceUpdateStatus.failed,
          message: message,
        );

  final SourceUpdateStatus status;

  /// 可读说明（失败 / 跳过时非空）。
  final String message;

  /// 更新后的描述符（成功时有值）。
  final SourceDescriptor? descriptor;

  bool get isSuccess =>
      status == SourceUpdateStatus.updated ||
      status == SourceUpdateStatus.unchanged;
}

/// 订阅更新的四种结论。
enum SourceUpdateStatus {
  /// 拉到了新脚本并覆盖成功。
  updated('updated', '已更新'),

  /// 拉到的脚本与现有内容一致（服务端没变）。
  unchanged('unchanged', '已是最新'),

  /// 没更新：不是订阅源、或该板块没有图源运行时。
  skipped('skipped', '跳过'),

  /// 更新失败：网络异常、MD5 校验不符、脚本不合法。
  failed('failed', '更新失败');

  const SourceUpdateStatus(this.id, this.label);

  final String id;
  final String label;
}

/// 图源连通性测试结果。
///
/// 三态而非两态：**可用 / 有内容但取不到 / 不可用**要分开——「脚本能跑但列表为空」
/// 与「脚本报错」对用户的含义完全不同（前者可能是图源改版，后者是脚本本身的问题）。
class SourceTestResult {
  const SourceTestResult._({
    required this.status,
    required this.message,
    this.itemCount,
    this.categoryCount,
    this.elapsed,
  });

  const SourceTestResult.ok({
    required int itemCount,
    required int categoryCount,
    required Duration elapsed,
  }) : this._(
          status: SourceTestStatus.ok,
          message: '',
          itemCount: itemCount,
          categoryCount: categoryCount,
          elapsed: elapsed,
        );

  const SourceTestResult.empty({
    required Duration elapsed,
    required String message,
  }) : this._(
          status: SourceTestStatus.empty,
          message: message,
          elapsed: elapsed,
        );

  const SourceTestResult.failed(String message) : this._(
          status: SourceTestStatus.failed,
          message: message,
        );

  final SourceTestStatus status;

  /// 可读说明（成功时为空；空结果与失败带原因）。
  final String message;

  /// 首屏条目数（成功时有值）。
  final int? itemCount;

  /// 分类数（成功时有值）。
  final int? categoryCount;

  /// 耗时（成功与空结果有值；失败时可能为 null）。
  final Duration? elapsed;

  bool get isOk => status == SourceTestStatus.ok;
}

/// 连通性测试的三种结论。
enum SourceTestStatus {
  /// 能取到内容。
  ok('ok', '可用'),

  /// 脚本能跑，但首屏没有内容（图源改版、分类为空等）。
  empty('empty', '无内容'),

  /// 打不开：脚本载入失败、网络异常或平台无运行时。
  failed('failed', '不可用');

  const SourceTestStatus(this.id, this.label);

  final String id;
  final String label;
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
