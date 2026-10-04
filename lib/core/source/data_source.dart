import '../session/section.dart';
import 'source_models.dart';

/// 统一数据源接口。
///
/// 四个板块（小说 / 漫画 / 自定义视频 / 猫源）的图源——JS 图源与模拟实现——
/// 都实现这一套能力。UI 只依赖本接口，不认识沙箱、脚本、数据库与网络。
///
/// 约定：
/// - **分类可缺省**：不提供分类的图源返回空列表，UI 据此隐藏分类入口；
/// - **列表一个入口三用**：`categoryId` 为空表示默认列表，`keyword` 非空表示
///   搜索，`page` 从 1 开始；分页语义由 [SourceList.hasMore] 承载；
/// - **空结果不算失败**：无结果返回空集合，条目找不到时 [detail] 返回 null，
///   章节暂无内容时 [content] 返回 null；
/// - **真失败抛 [SourceException]**：调用链失败（运行时不可用、脚本错误、
///   超时、返回格式不符契约）一律以异常表达，UI 只处理异常与空结果两种分支。
///
/// 生命周期：本接口不含 `dispose()`。实现方要么是无状态适配器（由注册表持有
/// 底层运行时），要么是纯内存模拟实现；打开与释放由门面统一负责。
abstract interface class DataSource {
  /// 图源标识（板块内唯一）。
  String get id;

  /// 图源显示名。
  String get name;

  /// 所属板块。
  Section get section;

  /// 获取分类。
  Future<List<SourceCategory>> categories();

  /// 列表：分类浏览、搜索与默认列表共用同一入口。
  Future<SourceList> list({String? categoryId, String? keyword, int page = 1});

  /// 详情。条目不存在时返回 null。
  Future<SourceDetail?> detail(String itemId);

  /// 章节列表。
  Future<List<SourceChapter>> chapters(String itemId);

  /// 播放 / 阅读章节：返回内容载荷（文本 / 图片列表 / 视频地址）。
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  });
}

/// 列表结果：条目与是否还有下一页。
class SourceList {
  const SourceList({this.items = const <SourceItem>[], this.hasMore = false});

  final List<SourceItem> items;

  /// 是否还有下一页。Phase1 的 UI 只翻第一页，分页语义预留给后续。
  final bool hasMore;

  bool get isEmpty => items.isEmpty;
}

/// 图源描述：管理界面需要的最小信息。
///
/// 它与数据库记录、脚本实现都解耦，UI 不接触持久化细节。
class SourceDescriptor {
  const SourceDescriptor({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
  });

  final String id;
  final String name;
  final String version;
  final bool enabled;
}

/// 数据源失败分类。UI 只需区分这三类即可决定提示文案。
enum SourceErrorKind {
  /// 当前平台不提供图源运行时（Phase1 只在 iOS 提供）。
  unsupported('unsupported', '当前平台不提供图源运行时'),

  /// 图源不存在、已禁用，或其运行时已经释放。
  notFound('notFound', '图源不存在或已禁用'),

  /// 调用失败：脚本错误、超时、返回格式不符契约等。
  callFailed('callFailed', '图源调用失败'),

  /// 网络异常：图源的 HTTP 请求没能完成（连接失败、超时、协议中断）。
  ///
  /// 与 [callFailed] 分开，是为了让「脚本报错」与「网络异常」在界面上能被
  /// 分别呈现：判定发生在发请求的那一层（宿主代理），不靠展示层猜文案。
  network('network', '网络异常');

  const SourceErrorKind(this.id, this.label);

  /// 稳定标识，用于日志与测试断言。
  final String id;

  /// 中文短标签。
  final String label;
}

/// 数据源调用失败。
class SourceException implements Exception {
  const SourceException(this.kind, this.message);

  final SourceErrorKind kind;
  final String message;

  @override
  String toString() => '${kind.label}: $message';
}
