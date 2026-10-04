import 'comic_repo_models.dart';

/// Mihon / Tachiyomi 通用仓库索引解析（`index.min.json`）。
///
/// 条目字段：`name / pkg / apk / lang / code / version / nsfw / sources[]`，
/// 其中 `sources[]` 的元素是 `{name, lang, id, baseUrl}`。载体是 `.apk`——
/// 需要 Android 运行时，本平台（iOS）只能浏览、不能运行。
///
/// 宽容口径：单条不合法（缺 pkg / apk / name，或不是对象）只跳过该条；
/// 整体不是数组才报错。下载地址按仓库索引地址解析（`apk` 也可能是绝对地址）。
class ComicRepoMihonParser {
  const ComicRepoMihonParser._();

  static RepoIndex parse(Object? json, {required Uri baseUri}) {
    if (json is! List) {
      throw const FormatException('Mihon 仓库索引不是数组');
    }
    final extensions = <RepoExtension>[];
    for (final item in json) {
      final extension = _parseEntry(item, baseUri);
      if (extension != null) extensions.add(extension);
    }
    return RepoIndex(kind: RepoKind.mihon, extensions: extensions);
  }

  static RepoExtension? _parseEntry(Object? item, Uri baseUri) {
    if (item is! Map) return null;
    final id = _text(item['pkg']);
    final name = _text(item['name']);
    final apk = _text(item['apk']);
    if (id == null || name == null || apk == null) return null;
    return RepoExtension(
      id: id,
      name: name,
      version: _text(item['version']) ?? '',
      language: _text(item['lang']) ?? '',
      artifact: ExtensionArtifact.apk,
      url: baseUri.resolve(apk),
      nsfw: _flag(item['nsfw']),
      sourceNames: _sourceNames(item['sources']),
    );
  }

  /// `sources[]` 里的来源名（扩展卡片上的补充说明）。
  static List<String> _sourceNames(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((entry) => entry is Map ? _text(entry['name']) : null)
        .whereType<String>()
        .toList(growable: false);
  }

  /// Mihon 的 `nsfw` 在不同仓库里写成 0/1、true/false 或字符串，都要认。
  static bool _flag(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = _text(value);
    return text == '1' || text == 'true';
  }

  static String? _text(Object? value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }
}
