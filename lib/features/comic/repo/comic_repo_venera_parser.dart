import 'comic_repo_models.dart';

/// Venera 仓库索引解析（`index.json`）。
///
/// 条目字段：`name / fileName / key / version`。`fileName` 指向一个 `.js`
/// 脚本——在漫画板块的 QuickJS 沙箱里运行（本平台可运行）。
/// `key` 是一族来源的标识（同一 key 可能有多个条目，例如多账号变体），
/// 因此扩展的稳定标识用 `fileName`。
///
/// 宽容口径与 Mihon 侧一致：单条不合法只跳过；整体不是数组才报错。
class ComicRepoVeneraParser {
  const ComicRepoVeneraParser._();

  static RepoIndex parse(Object? json, {required Uri baseUri}) {
    if (json is! List) {
      throw const FormatException('Venera 仓库索引不是数组');
    }
    final extensions = <RepoExtension>[];
    for (final item in json) {
      final extension = _parseEntry(item, baseUri);
      if (extension != null) extensions.add(extension);
    }
    return RepoIndex(kind: RepoKind.venera, extensions: extensions);
  }

  static RepoExtension? _parseEntry(Object? item, Uri baseUri) {
    if (item is! Map) return null;
    final fileName = _text(item['fileName']);
    final name = _text(item['name']);
    if (fileName == null || name == null) return null;
    return RepoExtension(
      id: fileName,
      name: name,
      version: _text(item['version']) ?? '',
      // Venera 索引没有语言与分级字段：留空、不误填。
      artifact: ExtensionArtifact.js,
      url: baseUri.resolve(fileName),
    );
  }

  static String? _text(Object? value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }
}
