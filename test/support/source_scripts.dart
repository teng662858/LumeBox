import 'dart:io';

/// 源脚本的本地缓存（脚本已搬到独立仓库）。
///
/// 真机脚本**不随 App 仓库分发**：它们在
/// [LumeBox-Sources](https://github.com/teng662858/LumeBox-Sources)，
/// 按板块提供订阅清单。需要在真实 QuickJS 上跑真脚本的原生用例，先拉一份缓存：
///
/// ```
/// dart run tool/fetch_sources.dart
/// ```
///
/// 缓存落在 `.sources-cache/<section>/`（已 gitignore）。没拉缓存时这些用例
/// **整组跳过**，不是失败——它们验的是「脚本对得上站点真实结构」，
/// 而不是 App 自身的行为。
const String lumeSourcesRepo =
    'https://github.com/teng662858/LumeBox-Sources';
const String lumeSourcesRawBase =
    'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main';

/// 缓存根目录（相对仓库根；测试的工作目录就是仓库根）。
Directory get sourceCacheDir => Directory('.sources-cache');

/// 找一个源脚本的本地路径：先看缓存，再看历史位置（`sources/`）。
///
/// 返回 null 表示本机没有这份脚本（调用方跳过用例并说明去哪拉）。
String? sourceScriptPath(String name) {
  if (sourceCacheDir.existsSync()) {
    for (final entity in sourceCacheDir.listSync(recursive: true)) {
      if (entity is File && entity.uri.pathSegments.last == name) {
        return entity.path;
      }
    }
  }
  final legacy = File('sources/$name');
  return legacy.existsSync() ? legacy.path : null;
}

/// 整组跳过时给的原因（[sourceScriptPath] 返回 null 时用）。
String sourceScriptsSkipReason(String name) =>
    '本机没有 $name：脚本在 $lumeSourcesRepo，'
    '先跑 `dart run tool/fetch_sources.dart`（缓存到 .sources-cache/）再测';
