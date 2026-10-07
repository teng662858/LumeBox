import '../cache/section_memory_cache.dart';
import '../net/waf.dart';
import '../net/waf_auto_verify.dart';
import '../util/lume_log.dart';
import '../session/section.dart';
import 'data_source.dart';
import 'source_models.dart';

/// JS 图源运行时端口：数据源适配器认识的最小能力集。
///
/// 由组合根（`lume_sources.dart`）用真实引擎实现，测试可以用假实现替代，
/// 因此本层在 Windows 上也能被完整验证。适配器只依赖这个端口，
/// 不认识沙箱、策略、脚本句柄与网络。
abstract interface class JsSourceRuntime {
  /// 调用图源脚本的 JS 方法。成功返回 JSON 解码值（脚本可以显式返回 null）；
  /// 失败必须抛 [SourceException]。
  Future<Object?> call(String method, [Object? argument]);

  /// 脚本**实际提供**的契约方法集合（按别名表判定）。
  ///
  /// 用途：可选契约（`home` / `filters` / `suggest`）**不能因为接口实现了就当它
  /// 一定存在**——老脚本没有 `home()` 时，进「首页模式」会直接抛错、把整块首页
  /// 变成错误页（真机反馈过这条）。这里先问清楚「有没有」，没有就照旧走老路径。
  Future<Set<String>> contractMethods();
}

/// JS 侧方法契约：方法挂在脚本的全局 `LumeSource` 上。
///
/// 契约形状（示例脚本、模拟实现与测试都以此为准）：
/// - `categories()` → `[{id, title}]`
/// - `list({categoryId?, keyword?, page})` →
///   `{items: [{id, title, cover?, subtitle?}], hasMore?}`，也接受裸数组
/// - `detail({id})` → `{id, title, cover?, subtitle?, description?}` 或 null
/// - `chapters({id})` → `[{id, title}]`
/// - `content({id, chapterId})` → `{kind: 'text', text}` /
///   `{kind: 'images', images: [...]}` / `{kind: 'video', url, headers?}`
///
/// 两种脚本写法引擎都认（见 `LumeSourceBridgePolyfill`）：
/// 1. **对象式**：脚本自己声明 `LumeSource = { categories, list, … }`（上面这套
///    入参口径，入参是一个对象）；
/// 2. **函数式**：脚本只写顶层函数 `getList(page)` / `getSearch(keyword, page)` /
///    `getDetail(id)` / `getChapters(id)` / `getContent(id, chapterId)` /
///    `getCategories()`——宿主注入的 `LumeSource` 桥接对象按位置参数把它们接上，
///    返回值同样按宽容口径解析（`{list: [...]}` 与 `{title, url}` 条目都认）。
///    函数式脚本没有可供读取 id / name 的对象字段，导入口径要求它写头部注释。
class JsSourceContract {
  JsSourceContract._();

  static const String categories = 'categories';
  static const String list = 'list';

  /// 筛选标签（可选契约；脚本没实现时按「不支持」处理）。
  static const String filters = 'filters';

  /// 首页（可选契约）：多板块数组 / 旧兼容的纯 Item 数组，App 自动识别。
  static const String home = 'home';
  static const String detail = 'detail';
  static const String chapters = 'chapters';
  static const String content = 'content';

  /// 全部契约方法名，供文档与测试遍历。
  static const List<String> methods = <String>[
    categories,
    list,
    detail,
    chapters,
    content,
    // 可选契约（有别名表、可被脚本实现；没实现也不影响导入）。
    home,
    filters,
  ];
}

/// 把 [DataSource] 语义映射到 JS 图源方法的适配器。
///
/// 本类只做「翻译」：接口方法 → JS 方法名与入参 → 结果解析 → 异常归一。
/// 它不持有运行时，也不负责脚本载入与沙箱生命周期。
///
/// 可选读缓存（[cache]）：给了就把**元数据读取**（分类 / 详情 / 章节）按板块
/// 缓存起来，同一份内容第二次读不再走脚本；列表与章节内容不缓存（变化快、
/// 体积大）。缓存由组合根注入（正式实现是 [SectionMemoryCache]），测试不传
/// 就没有缓存行为；脚本被覆盖导入 / 图源被删除时由注册表负责作废。
class JsDataSource
    implements
        DataSource,
        DanmakuCapable,
        DanmakuPostCapable,
        FilterCapable,
        HomeCapable {
  JsDataSource({
    required this.id,
    required this.name,
    required this.section,
    required this.runtime,
    this.cache,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final Section section;

  /// 调用运行时。适配器只使用它，不持有也不释放它的生命周期。
  final JsSourceRuntime runtime;

  /// 读缓存（可选，按板块隔离）。为空表示不做任何缓存。
  final SourceReadCache? cache;

  @override
  Future<List<SourceCategory>> categories() async {
    const key = 'categories';
    final cached = cache?.read(section, id, key);
    if (cached is List<SourceCategory>) return cached;
    final value = parseCategories(await _invoke(JsSourceContract.categories));
    cache?.write(section, id, key, value);
    return value;
  }

  /// 脚本是否真的实现了 `home()`（探测一次、缓存住）。
  bool? _hasHome;

  @override
  Future<bool> supportsHome() async {
    final cached = _hasHome;
    if (cached != null) return cached;
    final methods = await runtime.contractMethods();
    final has = methods.contains(JsSourceContract.home);
    _hasHome = has;
    return has;
  }

  @override
  Future<SourceHome> home() async {
    // 首页不缓存：它代表「现在有什么推荐」，刷新就该看到最新的。
    return SourceHome.parse(await _invoke(JsSourceContract.home));
  }

  /// 脚本是否真的实现了 `filters()`（探测一次、缓存住）。
  bool? _hasFilters;

  @override
  Future<bool> supportsFilters() async {
    final cached = _hasFilters;
    if (cached != null) return cached;
    final methods = await runtime.contractMethods();
    final has = methods.contains(JsSourceContract.filters);
    _hasFilters = has;
    return has;
  }

  @override
  Future<List<SourceFilterGroup>> filters() async {
    // 标签组不缓存（用户要求「每次打开实时抓，加短时缓存」——短时缓存放在
    // 视频板块的 VideoFilterCache 里，App 侧统一 TTL，脚本只管取最新值）。
    return SourceFilterGroup.parseAll(
      await _invoke(JsSourceContract.filters),
    );
  }

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final argument = <String, Object?>{'page': page < 1 ? 1 : page};
    final category = categoryId?.trim() ?? '';
    if (category.isNotEmpty) argument['categoryId'] = category;
    final search = keyword?.trim() ?? '';
    if (search.isNotEmpty) argument['keyword'] = search;
    // 筛选条件原样交给脚本（组 id → 选中项 id，多选以英文逗号相连）。
    if (filters != null && filters.isNotEmpty) {
      argument['filters'] = <String, String>{
        for (final entry in filters.entries)
          if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
      };
    }
    // 列表不缓存：分类切换 / 搜索 / 刷新都要求看到当下内容。
    return parseSourceList(await _invoke(JsSourceContract.list, argument));
  }

  @override
  Future<SourceDetail?> detail(String itemId) async {
    final key = 'detail|$itemId';
    final cached = cache?.read(section, id, key);
    if (cached is SourceDetail) return cached;
    final value = SourceDetail.parse(
      await _invoke(JsSourceContract.detail, <String, Object?>{'id': itemId}),
    );
    // 空结果是「条目不存在」，不是可复用的元数据，不进缓存。
    if (value != null) cache?.write(section, id, key, value);
    return value;
  }

  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    final key = 'chapters|$itemId';
    final cached = cache?.read(section, id, key);
    if (cached is List<SourceChapter>) return cached;
    final value = parseChapters(
      await _invoke(JsSourceContract.chapters, <String, Object?>{'id': itemId}),
    );
    cache?.write(section, id, key, value);
    return value;
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    final value = await _invoke(
      JsSourceContract.content,
      <String, Object?>{'id': itemId, 'chapterId': chapterId},
    );
    try {
      return ChapterContent.parse(value);
    } on FormatException catch (error) {
      throw SourceException(
        SourceErrorKind.callFailed,
        '章节内容不符合契约：${error.message}',
      );
    }
  }

  /// 可选能力：弹幕（图源脚本实现 `danmaku({id, chapterId})` 才有）。
  ///
  /// 走的是与其它方法同一条调用链；脚本没实现时引擎会给出可读错误，
  /// 由调用方静默降级成「这集没有弹幕」。
  @override
  Future<Object?> danmaku({
    required String itemId,
    required String chapterId,
  }) =>
      _invoke('danmaku', <String, Object?>{
        'id': itemId,
        'chapterId': chapterId,
      });

  /// 可选能力：上报弹幕（图源脚本实现 `postDanmaku({...})` 才有）。
  ///
  /// 返回值口径：脚本返回 `true` / `{ok: true}` / 有内容都算成功；脚本**没有实现
  /// 这个方法**（引擎报「方法不存在」）算「不支持写入」，返回 false 而不是抛错——
  /// 与「能读不能写」的图源占多数这一事实对应，调用方据此提示「本图源不支持
  /// 发送弹幕」而不是报一个吓人的错误。
  @override
  Future<bool> postDanmaku({
    required String itemId,
    required String chapterId,
    required String text,
    required int positionMs,
    required String mode,
    int? color,
  }) async {
    try {
      final result = await runtime.call('postDanmaku', <String, Object?>{
        'id': itemId,
        'chapterId': chapterId,
        'text': text,
        'position': positionMs,
        'mode': mode,
        'color': ?color,
      });
      if (result is bool) return result;
      if (result is Map && result['ok'] is bool) return result['ok'] as bool;
      // 脚本没显式返回时按成功处理（发出去了就行）。
      return true;
    } on SourceException catch (error) {
      // 「方法不存在」= 图源不支持写入，是正常情况，不当失败。
      if (_isMissingMethod(error)) return false;
      rethrow;
    }
  }

  /// 判断异常是否为「脚本没实现这个方法」。
  ///
  /// 引擎对缺失方法的措辞在不同实现间略有差异（quickjs 报「不是函数」，
  /// 桥接层报「方法不存在」），因此按关键词宽松匹配——这里只用来区分
  /// 「不支持写入」（正常）与「调用失败」（要上报）。
  static bool _isMissingMethod(SourceException error) {
    final message = error.message;
    return message.contains('不是函数') ||
        message.contains('方法不存在') ||
        message.contains('undefined') ||
        message.contains('not a function');
  }

  Future<Object?> _invoke(String method, [Object? argument]) async {
    return _invokeOnce(method, argument, retriedWaf: false);
  }

  /// 调一次脚本方法；被 WAF 拦下时**自动过校验并重试一次**（用户口径 2 / 3）。
  ///
  /// 这里只做一件额外的事：认出脚本抛的 `NEED_WEBVIEW_VERIFY` 标记 → 让界面层去
  /// 弹那个小悬浮窗（[WafAutoVerify.run]，引擎层不认识 Navigator）→ 拿到会话后
  /// **原样重试同一次调用**。重试只做一次，避免和站点来回拉锯；重试仍失败就按
  /// 普通失败往上抛（界面照旧给【重试】+【网页视图】两个出口）。
  Future<Object?> _invokeOnce(
    String method,
    Object? argument, {
    required bool retriedWaf,
  }) async {
    try {
      return await runtime.call(method, argument);
    } on SourceException catch (error) {
      if (!retriedWaf && _needsWebView(error.message)) {
        final handled = await WafAutoVerify.run(
          section: section,
          sourceId: id,
          sourceName: name,
          url: urlFromFailure(error.message) ?? '',
        );
        if (handled) {
          LumeLog.info('[$id] WAF 校验完成，重试 $method');
          return _invokeOnce(method, argument, retriedWaf: true);
        }
      }
      rethrow;
    } catch (error) {
      throw SourceException(
        SourceErrorKind.callFailed,
        '源方法 $method 调用异常: $error',
      );
    }
  }

  /// 这条失败信息是不是「需要网页视图过一下人机校验」。
  ///
  /// 只认脚本抛的固定标记（用户口径 2：保留 `NEED_WEBVIEW_VERIFY`）；认证不出标记
  /// 的普通失败不在这里自动弹窗——那种该由用户自己决定要不要去网页视图。
  static bool _needsWebView(String? message) =>
      (message ?? '').toUpperCase().contains('NEED_WEBVIEW_VERIFY');
}

/// 解析列表信封：接受 `{items: [...], hasMore: bool}`、`{list: [...], hasMore}`
/// 与裸数组三种形状。
///
/// `list` 是函数式脚本（顶层 `getList(page)`）的常见写法——它与 `items` 同义，
/// 引擎的桥接层不做改写，宽容解析统一落在这一层。
/// 与其余集合解析一致保持宽容：无法识别时返回空列表，而不是抛错。
SourceList parseSourceList(Object? json) {
  if (json is List) return SourceList(items: parseItems(json));
  if (json is Map) {
    return SourceList(
      items: parseItems(json['items'] ?? json['list']),
      hasMore: json['hasMore'] == true,
    );
  }
  return const SourceList();
}
