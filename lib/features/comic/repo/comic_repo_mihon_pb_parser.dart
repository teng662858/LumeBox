import 'dart:io';
import 'dart:typed_data';

import 'comic_repo_models.dart';
import 'comic_repo_protobuf.dart';

/// Mihon / Tachiyomi 仓库的 **protobuf 索引**（`index.pb`）解析。
///
/// 现实背景：Mihon 系的仓库现在正式发布 `index.pb`（gzip 过的 protobuf），
/// 而 `index.min.json` 可能只是「旧客户端请升级」的占位（keiyoushi 就是这种）。
/// 因此根地址优先取 `.pb`，用户直接给 `.pb` 地址时更要按 protobuf 读。
///
/// 结构（对着真实索引逐字段核对，字段号写死在这里并在测试里固化）：
/// ```
/// Index           { string name = 1; string badge = 2; ... message extensions = 101 }
/// extensions      { repeated Extension extensions = 1 }
/// Extension       { string name = 1; string pkg = 2; Payload payload = 3;
///                   string minApp = 4; int64 size = 5; string version = 6;
///                   int64 code = 7; repeated Source sources = 8 }
/// Payload         { string apk = 1; string icon = 2; string jar = 501 }
/// Source          { int64 id = 1; string name = 2; string lang = 3; string baseUrl = 4 }
/// ```
///
/// 载体仍然是 `.apk`（本平台只能浏览、不能运行），与 JSON 索引口径一致；
/// `nsfw` 在 protobuf 里没有对应字段，统一按 false 处理。
class ComicRepoMihonPbParser {
  const ComicRepoMihonPbParser._();

  /// 顶层扩展列表所在字段号。
  static const int extensionsField = 101;

  /// 扩展条目在列表里的字段号。
  static const int extensionEntryField = 1;

  static RepoIndex parse(Uint8List payload, {required Uri baseUri}) {
    final bytes = _gunzipIfNeeded(payload);
    final top = ProtobufReader.fieldsOf(bytes);

    Uint8List? list;
    for (final field in top) {
      if (field.number == extensionsField && field.bytes != null) {
        list = field.bytes;
        break;
      }
    }
    if (list == null) {
      throw const FormatException('index.pb 结构不符：找不到扩展列表（字段 101）');
    }

    final extensions = <RepoExtension>[];
    for (final entry in ProtobufReader.fieldsOf(list)) {
      if (entry.number != extensionEntryField || entry.bytes == null) continue;
      final parsed = _parseExtension(entry.bytes!, baseUri);
      if (parsed != null) extensions.add(parsed);
    }
    return RepoIndex(kind: RepoKind.mihon, extensions: extensions);
  }

  static RepoExtension? _parseExtension(Uint8List bytes, Uri baseUri) {
    String? name;
    String? pkg;
    String? version;
    String? language;
    Uri? artifact;
    final sourceNames = <String>[];

    for (final field in ProtobufReader.fieldsOf(bytes)) {
      switch (field.number) {
        case 1:
          name = field.text?.trim();
        case 2:
          pkg = field.text?.trim();
        case 3:
          // 载荷：apk 下载地址（绝对地址，带文件名）、图标、jar。
          final payload = field.bytes;
          if (payload == null) break;
          for (final item in ProtobufReader.fieldsOf(payload)) {
            if (item.number != 1 || item.bytes == null) continue;
            final link = item.text?.trim() ?? '';
            if (link.isEmpty) break;
            artifact ??= baseUri.resolve(link);
            break;
          }
        case 6:
          version = field.text?.trim();
        case 8:
          // 来源：名字用于卡片补充说明；语言取第一个来源的（JSON 索引同口径）。
          final source = field.bytes;
          if (source == null) break;
          String? sourceName;
          String? sourceLang;
          for (final item in ProtobufReader.fieldsOf(source)) {
            if (item.number == 2) sourceName = item.text?.trim();
            if (item.number == 3) sourceLang = item.text?.trim();
          }
          if (sourceName != null && sourceName.isNotEmpty) {
            sourceNames.add(sourceName);
          }
          language ??= sourceLang;
      }
    }

    if (name == null ||
        name.isEmpty ||
        pkg == null ||
        pkg.isEmpty ||
        artifact == null) {
      return null;
    }
    return RepoExtension(
      id: pkg,
      name: name,
      version: version ?? '',
      language: language ?? '',
      artifact: ExtensionArtifact.apk,
      url: artifact,
      sourceNames: sourceNames,
    );
  }

  /// 真实索引是 gzip 过的（`1f 8b` 开头），偶尔也可能直接给裸 protobuf。
  static Uint8List _gunzipIfNeeded(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;
    try {
      return Uint8List.fromList(gzip.decode(bytes));
    } on Object catch (error) {
      throw FormatException('index.pb 的 gzip 解压失败：$error');
    }
  }
}
