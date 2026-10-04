/// 图源数据模型与契约解析。
///
/// 四个板块（小说 / 漫画 / 自定义视频 / 猫源）共用这一套模型：模型本身不持有
/// 任何跨板块状态，也不认识沙箱、脚本与数据库。JS 适配器与模拟实现都产出
/// 这里的类型，UI 只认这些类型。
///
/// 解析风格：集合类解析（分类 / 条目 / 章节 / 详情）保持宽容，无法识别的
/// 输入返回空集合或 null；章节内容（单个载荷）保持严格，无法识别即抛
/// [FormatException]，由适配器转成数据源层异常。
library;

/// 图源分类。
class SourceCategory {
  const SourceCategory({required this.id, required this.title});

  /// 分类标识（图源内唯一）。
  final String id;

  /// 分类显示名。
  final String title;

  static SourceCategory? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final title = '${json['title'] ?? ''}'.trim();
    return SourceCategory(id: id, title: title.isEmpty ? id : title);
  }
}

/// 列表条目。
class SourceItem {
  const SourceItem({
    required this.id,
    required this.title,
    this.cover,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? cover;
  final String? subtitle;

  /// 解析条目。宽容口径：视频类脚本常用 `{title, url}` 表达条目
  /// （见图源契约的函数式写法），此时 `url` 兼作 id（详情 / 播放都按它取），
  /// 标题也接受 `name` 写法；两者都缺才判定为不可识别。
  static SourceItem? parse(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']) ?? _text(json['url']);
    final title = _text(json['title']) ?? _text(json['name']);
    if (id == null || title == null) return null;
    return SourceItem(
      id: id,
      title: title,
      cover: _text(json['cover']),
      subtitle: _text(json['subtitle']),
    );
  }
}

/// 条目详情。
class SourceDetail {
  const SourceDetail({
    required this.id,
    required this.title,
    this.cover,
    this.subtitle,
    this.description,
  });

  final String id;
  final String title;
  final String? cover;
  final String? subtitle;
  final String? description;

  static SourceDetail? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    final title = '${json['title'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    return SourceDetail(
      id: id,
      title: title,
      cover: _text(json['cover']),
      subtitle: _text(json['subtitle']),
      description: _text(json['description']),
    );
  }
}

/// 章节条目。
class SourceChapter {
  const SourceChapter({required this.id, required this.title});

  final String id;
  final String title;

  static SourceChapter? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final title = '${json['title'] ?? ''}'.trim();
    return SourceChapter(id: id, title: title.isEmpty ? id : title);
  }
}

/// 章节内容载荷：播放 / 阅读的统一出口。
///
/// 用密封类表达三类载荷，Phase2 的阅读器与播放器可以对它做穷尽 switch，
/// 不会因为漏掉一类内容而出错。
sealed class ChapterContent {
  const ChapterContent();

  /// 解析契约 JSON。供 JS 适配器与测试使用。
  ///
  /// - `null` → null（该章节暂无内容）；
  /// - 字符串 → [TextContent]（空串视为暂无内容）；
  /// - 字符串数组 → [ImageContent]；
  /// - `{kind: 'text' | 'images' | 'video', ...}` → 对应类型；
  /// - 其他输入 → 抛 [FormatException]（不符合契约）。
  static ChapterContent? parse(Object? json) {
    if (json == null) return null;
    if (json is String) {
      final text = json.trim();
      return text.isEmpty ? null : TextContent(text);
    }
    if (json is List) {
      final images = _imageList(json);
      return images.isEmpty ? null : ImageContent(images);
    }
    if (json is! Map) {
      throw FormatException('无法识别的章节内容: $json');
    }
    final kind = '${json['kind'] ?? ''}'.trim().toLowerCase();
    switch (kind) {
      case 'text':
        final text = '${json['text'] ?? ''}';
        return text.trim().isEmpty ? null : TextContent(text);
      case 'images':
      case 'image':
        final images = _imageList(json['images']);
        return images.isEmpty ? null : ImageContent(images);
      case 'video':
        final raw = '${json['url'] ?? ''}'.trim();
        final uri = Uri.tryParse(raw);
        if (uri == null || !uri.hasScheme) {
          throw FormatException('章节内容的 video.url 非法: $raw');
        }
        return VideoContent(url: uri, headers: _stringMap(json['headers']));
      default:
        throw FormatException('未知的章节内容 kind: $kind');
    }
  }
}

/// 文本正文（小说类）。
final class TextContent extends ChapterContent {
  const TextContent(this.text);

  final String text;
}

/// 图片列表（漫画 / 图集类）。
final class ImageContent extends ChapterContent {
  const ImageContent(this.images);

  final List<String> images;
}

/// 视频地址（视频 / 猫源类）。
final class VideoContent extends ChapterContent {
  const VideoContent({
    required this.url,
    this.headers = const <String, String>{},
  });

  final Uri url;

  /// 播放时附带的请求头（防盗链等）。
  final Map<String, String> headers;
}

List<SourceCategory> parseCategories(Object? json) {
  if (json is! List) return const <SourceCategory>[];
  return json
      .map(SourceCategory.parse)
      .whereType<SourceCategory>()
      .toList(growable: false);
}

List<SourceItem> parseItems(Object? json) {
  if (json is! List) return const <SourceItem>[];
  return json
      .map(SourceItem.parse)
      .whereType<SourceItem>()
      .toList(growable: false);
}

List<SourceChapter> parseChapters(Object? json) {
  if (json is! List) return const <SourceChapter>[];
  return json
      .map(SourceChapter.parse)
      .whereType<SourceChapter>()
      .toList(growable: false);
}

List<String> _imageList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return value.map((key, item) => MapEntry('$key', '$item'));
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}
