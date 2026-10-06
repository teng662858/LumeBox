import '../session/section.dart';
import '../net/network_settings.dart';
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

/// 可选的「扩展能力」端口：图源实现它即具备该能力，不实现就是没有。
///
/// 为什么不做成 [DataSource] 的必选方法：弹幕、预告这类能力**不是每个图源都有**
/// （文档也把弹幕列为进阶项）。做成必选会逼所有图源（含模拟源与测试替身）实现
/// 一堆空方法；做成可选端口，调用方 `source is XxxCapable` 一问即可。
///
/// 能力缺失是**正常情况**，不是错误：调用方必须静默降级（如「这集没有弹幕」），
/// 不能因为图源没实现弹幕就让播放失败。
abstract interface class DanmakuCapable {
  /// 取某一集的弹幕。
  ///
  /// 返回形状由适配层宽容解析（数组 / `{danmaku: [...]}` 信封皆可）；没有弹幕时
  /// 返回空数组或 null。失败应抛 [SourceException]，由调用方决定是否降级。
  Future<Object?> danmaku({
    required String itemId,
    required String chapterId,
  });
}

/// 可选的「扩展能力」端口：**上报**弹幕（发一条弹幕到图源）。
///
/// 与 [DanmakuCapable] 分成两个端口，因为它们是两个独立能力：能读弹幕的图源
/// 未必能写（多数聚合源只取公开弹幕库，没有写入接口）。合成一个会逼「只读」
/// 的图源实现一个永远抛错的写入方法——分开后调用方按能力分别判断。
///
/// 返回语义：成功返回 true；图源明确不支持写入时返回 false（**不是异常**，
/// 它是正常情况）；网络 / 脚本失败抛 [SourceException]。
abstract interface class DanmakuPostCapable {
  /// 上报一条弹幕。
  ///
  /// [positionMs] 是相对本集开头的毫秒数；[mode] 是弹幕位置（滚动 / 顶部 /
  /// 底部），用契约里的稳定字符串（`scroll` / `top` / `bottom`）。
  /// [color] 是可选的十进制颜色值。
  Future<bool> postDanmaku({
    required String itemId,
    required String chapterId,
    required String text,
    required int positionMs,
    required String mode,
    int? color,
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
    this.network = NetworkProfile.none,
    this.originUrl = '',
    this.group = '',
    this.failureCount = 0,
    this.broken = false,
  });

  final String id;
  final String name;
  final String version;
  final bool enabled;

  /// 单图源网络覆盖（UA / Cookie / 代理）；空项继承全局设置。
  final NetworkProfile network;

  /// 是否配置了任意网络覆盖（管理页据此标「已自定义网络」）。
  bool get hasNetworkOverride => !network.isEmpty;

  /// 订阅来源地址；本地导入为空。
  final String originUrl;

  /// 是否来自订阅（管理页据此标「订阅」并允许「更新订阅源」）。
  bool get subscribed => originUrl.trim().isNotEmpty;

  /// 用户自定的分组名；空串表示未分组。
  ///
  /// 分组是同一板块内的**展示归类**，不改变归属板块（跨板块依然完全隔离）。
  final String group;

  /// 连续失败次数。
  final int failureCount;

  /// 是否已被标记为失效（不再参与自动重试）。
  final bool broken;

  /// 是否已分组。
  bool get hasGroup => group.trim().isNotEmpty;
}

/// 数据源失败分类。UI 只需区分这三类即可决定提示文案。
enum SourceErrorKind {
  /// 当前平台不提供图源运行时（Phase1 只在 iOS 提供）。
  unsupported('unsupported', '当前平台不提供源运行时'),

  /// 图源不存在、已禁用，或其运行时已经释放。
  notFound('notFound', '源不存在或已禁用'),

  /// 调用失败：脚本错误、超时、返回格式不符契约等。
  callFailed('callFailed', '源调用失败'),

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
