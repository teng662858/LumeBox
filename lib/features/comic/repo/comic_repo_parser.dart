import 'dart:convert';

import 'comic_repo_mihon_parser.dart';
import 'comic_repo_models.dart';
import 'comic_repo_venera_parser.dart';

/// 仓库索引解析的统一入口：按类型分派到各自独立的解析器。
///
/// 两类仓库的字段与载体都不同（见 [RepoKind] 的文档），这里只做分派，
/// 不共用任何字段解读逻辑——格式差异留在两个解析器内部。
class ComicRepoParser {
  const ComicRepoParser._();

  static RepoIndex parse(RepoKind kind, Object? json, {required Uri baseUri}) =>
      switch (kind) {
        RepoKind.mihon => ComicRepoMihonParser.parse(json, baseUri: baseUri),
        RepoKind.venera => ComicRepoVeneraParser.parse(json, baseUri: baseUri),
      };

  /// 从文本解析；JSON 解不开时给出可读原因（错误里带仓库类型便于定位）。
  static RepoIndex parseText(
    RepoKind kind,
    String text, {
    required Uri baseUri,
  }) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (error) {
      throw FormatException('${kind.label} 仓库索引不是合法 JSON：${error.message}');
    }
    return parse(kind, json, baseUri: baseUri);
  }
}
