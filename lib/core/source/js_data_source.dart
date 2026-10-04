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
  ];
}

/// 把 [DataSource] 语义映射到 JS 图源方法的适配器。
///
/// 本类只做「翻译」：接口方法 → JS 方法名与入参 → 结果解析 → 异常归一。
/// 它不持有运行时，也不负责脚本载入与沙箱生命周期。
class JsDataSource implements DataSource {
  JsDataSource({
    required this.id,
    required this.name,
    required this.section,
    required this.runtime,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final Section section;

  /// 调用运行时。适配器只使用它，不持有也不释放它的生命周期。
  final JsSourceRuntime runtime;

  @override
  Future<List<SourceCategory>> categories() async =>
      parseCategories(await _invoke(JsSourceContract.categories));

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async {
    final argument = <String, Object?>{'page': page < 1 ? 1 : page};
    final category = categoryId?.trim() ?? '';
    if (category.isNotEmpty) argument['categoryId'] = category;
    final search = keyword?.trim() ?? '';
    if (search.isNotEmpty) argument['keyword'] = search;
    return parseSourceList(await _invoke(JsSourceContract.list, argument));
  }

  @override
  Future<SourceDetail?> detail(String itemId) async => SourceDetail.parse(
        await _invoke(JsSourceContract.detail, <String, Object?>{'id': itemId}),
      );

  @override
  Future<List<SourceChapter>> chapters(String itemId) async => parseChapters(
        await _invoke(JsSourceContract.chapters, <String, Object?>{'id': itemId}),
      );

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

  Future<Object?> _invoke(String method, [Object? argument]) async {
    try {
      return await runtime.call(method, argument);
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException(
        SourceErrorKind.callFailed,
        '图源方法 $method 调用异常: $error',
      );
    }
  }
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
