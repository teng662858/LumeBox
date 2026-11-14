import 'dart:io';

import 'package:lume_box/core/js/source_script.dart';

/// 源脚本的本地缓存（脚本已搬到独立仓库）。
///
/// 真机脚本**不随 App 仓库分发**：它们在
/// [LumeBox-Sources](https://github.com/teng662858/LumeBox-Sources)，
/// 这是私有仓库。先配置 GH_TOKEN/GITHUB_TOKEN 或执行 gh auth login，
/// 再通过授权 GitHub API 拉取一份经过 SHA 校验的测试缓存：
///
/// ```
/// dart run tool/fetch_sources.dart
/// ```
///
/// 缓存落在 `.sources-cache/<section>/`（已 gitignore）。没拉缓存时这些用例
/// **整组跳过**，不是失败——它们验的是「脚本对得上站点真实结构」，
/// 而不是 App 自身的行为。
const String lumeSourcesRepo = 'https://github.com/teng662858/LumeBox-Sources';
const String lumeSourcesRawBase =
    'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main';

/// 缓存根目录（相对仓库根；测试的工作目录就是仓库根）。
Directory get sourceCacheDir => Directory('.sources-cache');

/// 缓存里的一份资产（脚本或站点快照）的本地路径；没有则 null。
///
/// 缓存由 `dart run tool/fetch_sources.dart` 从源仓库拉下来：
/// `novel|comic|video/` 放脚本，`snapshots/` 放站点快照（写脚本时站点的样子，
/// 校验解析规则对着它跑；站点改版后旧快照不适用，就该更新它）。
String? sourceAssetPath(String name, {Directory? cache}) {
  final root = cache ?? sourceCacheDir;
  if (!root.existsSync()) return null;
  final aliases = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.uri.pathSegments.last == name) {
      return entity.path;
    }
    // Published filenames can change to Chinese display names. Older fixtures
    // address the stable source ID; never duplicate scripts or match snapshots.
    if (name.endsWith('.js') &&
        entity is File &&
        entity.path.endsWith('.js') &&
        !entity.uri.pathSegments.contains('snapshots')) {
      try {
        if (SourceMetadata.parseHeader(entity.readAsStringSync())?.id ==
            name.substring(0, name.length - 3)) {
          aliases.add(entity.path);
        }
      } on FileSystemException {
        // A disappearing cache entry cannot resolve an alias.
      } on FormatException {
        // Invalid scripts are reported by the contract audit itself.
      }
    }
  }
  return aliases.singleOrNull;
}

/// 找一个源脚本的本地路径（语义别名）。
String? sourceScriptPath(String name) => sourceAssetPath(name);

/// 找一份站点快照的本地路径（语义别名）。
String? sourceSnapshotPath(String name) => sourceAssetPath(name);

/// 整组跳过时给的原因（[sourceScriptPath] 返回 null 时用）。
String sourceScriptsSkipReason(String name) =>
    '本机没有 $name：脚本与站点快照都在 $lumeSourcesRepo，'
    '先跑 `dart run tool/fetch_sources.dart`（缓存到 .sources-cache/）再测';
