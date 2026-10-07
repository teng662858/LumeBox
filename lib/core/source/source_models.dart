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

import 'package:flutter/foundation.dart';

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
  const SourceChapter({
    required this.id,
    required this.title,
    this.publishedAt,
  });

  final String id;
  final String title;

  /// 章节发布时间（可选能力）：追剧日历据此把「更新」归到某一天。
  ///
  /// 图源给了就带上（`publishedAt` / `published` / `updatedAt` / `date` 几种写法
  /// 都认）；没给就是 null——日历只显示播放记录，不编造更新日期。
  final DateTime? publishedAt;

  static SourceChapter? parse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final title = '${json['title'] ?? ''}'.trim();
    return SourceChapter(
      id: id,
      title: title.isEmpty ? id : title,
      publishedAt: _parseTime(
        json['publishedAt'] ?? json['published'] ?? json['updatedAt'] ?? json['date'],
      ),
    );
  }

  /// 宽容解析发布时间：ISO 字符串 / 毫秒时间戳 / 秒级时间戳。
  static DateTime? _parseTime(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final millis = value > 100000000000 ? value.toInt() : (value * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    final text = '$value'.trim();
    if (text.isEmpty) return null;
    final numeric = num.tryParse(text);
    if (numeric != null) return _parseTime(numeric);
    return DateTime.tryParse(text);
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
        // 宽容口径：多线路脚本可能只给 qualities 不给 url——那就用第一条当默认。
        final qualities = _qualityList(json['qualities'] ?? json['levels']);
        final raw = '${json['url'] ?? ''}'.trim();
        var uri = Uri.tryParse(raw);
        if ((uri == null || !uri.hasScheme) && qualities.isNotEmpty) {
          uri = qualities.first.url;
        }
        if (uri == null || !uri.hasScheme) {
          throw FormatException('章节内容的 video.url 非法: $raw');
        }
        return VideoContent(
          url: uri,
          headers: _stringMap(json['headers']),
          qualities: qualities,
        );
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
    this.qualities = const <VideoQuality>[],
  });

  final Uri url;

  /// 播放时附带的请求头（防盗链等）。
  final Map<String, String> headers;

  /// 候选清晰度线路（图源给多条地址时才有；空列表 = 单线路）。
  ///
  /// **清晰度由图源数据决定，播放器只消费地址、不生成清晰度**（用户点名的
  /// 口径）：这里存的就是图源给的地址与它的标签，播放器只负责把它们列出来。
  final List<VideoQuality> qualities;

  /// 是否提供了多条线路（决定「清晰度」按钮是弹菜单还是弹提示）。
  bool get hasQualities => qualities.length > 1;
}

/// 一条候选清晰度线路：标签 + 地址（+ 该线路自己的请求头）。
///
/// 标签完全由图源决定（`1080P` / `超清` / `蓝光` 都行）：播放器不认识分辨率，
/// 只把它当展示名——「图源说这是什么画质」比播放器猜要可靠。
@immutable
class VideoQuality {
  const VideoQuality({
    required this.label,
    required this.url,
    this.headers = const <String, String>{},
  });

  /// 展示名（图源给的原始标签）。
  final String label;

  final Uri url;

  /// 这一条线路自己的请求头；为空时沿用主地址的 headers。
  final Map<String, String> headers;

  @override
  bool operator ==(Object other) =>
      other is VideoQuality &&
      other.label == label &&
      other.url == url &&
      other.headers.length == headers.length &&
      other.headers.entries.every((entry) => headers[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(
        label,
        url,
        Object.hashAllUnordered(
          headers.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      );

  @override
  String toString() => 'VideoQuality($label → $url)';
}

/// 解析候选清晰度线路。
///
/// 宽容口径（图源的写法五花八门，能救则救）：
/// - 标签取 `label` / `name` / `quality` / `title` / `resolution` 里第一个非空的；
/// - 地址取 `url` / `playUrl` / `src`；
/// - 条目非法（没有地址）就跳过，不影响其余线路；
/// - 标签缺失时用 `线路 N` 兜底——**不编造分辨率**（播放器不知道它是不是 1080P）。
List<VideoQuality> _qualityList(Object? value) {
  if (value is! List) return const <VideoQuality>[];
  final qualities = <VideoQuality>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final url = _text(entry['url']) ??
        _text(entry['playUrl']) ??
        _text(entry['src']) ??
        _text(entry['address']);
    if (url == null) continue;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) continue;
    final label = _text(entry['label']) ??
        _text(entry['name']) ??
        _text(entry['quality']) ??
        _text(entry['title']) ??
        _text(entry['resolution']) ??
        '线路 ${qualities.length + 1}';
    qualities.add(
      VideoQuality(
        label: label,
        url: uri,
        headers: _stringMap(entry['headers']),
      ),
    );
  }
  return List<VideoQuality>.unmodifiable(qualities);
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
