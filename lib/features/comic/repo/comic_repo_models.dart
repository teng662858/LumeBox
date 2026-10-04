/// 漫画扩展仓库的模型（只属于漫画板块）。
///
/// 两类仓库的索引格式不同、载体也不同：
/// - **Mihon / Tachiyomi**（`index.min.json`）：条目字段为
///   `name / pkg / apk / lang / code / version / nsfw / sources[]`，
///   载体是 `.apk`（需要 Android 运行时，本平台不能运行）；
/// - **Venera**（`index.json`）：条目字段为 `name / fileName / key / version`，
///   `fileName` 指向一个 `.js` 脚本（在漫画板块的沙箱里运行）。
///
/// 两者各写一个解析器（见 `comic_repo_mihon_parser.dart` /
/// `comic_repo_venera_parser.dart`），只在这份归一模型上汇合。
library;

/// 仓库类型。
enum RepoKind {
  mihon('mihon', 'Mihon / Tachiyomi'),
  venera('venera', 'Venera');

  const RepoKind(this.id, this.label);

  /// 稳定标识：落库与日志用。
  final String id;

  /// 显示名。
  final String label;

  /// 仓库地址给的是根地址（不以 .json 结尾）时，按类型补全索引文件名。
  String get indexPath => switch (this) {
        RepoKind.mihon => 'index.min.json',
        RepoKind.venera => 'index.json',
      };

  /// 读取落库值；无法识别时回退 Venera（JS 载体，iOS 可运行）。
  static RepoKind fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return RepoKind.venera;
  }
}

/// 扩展载体。
enum ExtensionArtifact {
  /// JS 脚本：在漫画板块的沙箱里运行（Venera 仓库）。
  js('js', 'JS'),

  /// APK 包：需要 Android 运行时，本平台只能浏览、不能运行（Mihon 仓库）。
  apk('apk', 'APK');

  const ExtensionArtifact(this.id, this.label);

  /// 稳定标识：落库与日志用。
  final String id;

  /// 显示名。
  final String label;

  static ExtensionArtifact fromId(String? id) {
    for (final artifact in values) {
      if (artifact.id == id) return artifact;
    }
    return ExtensionArtifact.js;
  }
}

/// 仓库里的一个扩展（两类格式归一后的模型）。
class RepoExtension {
  const RepoExtension({
    required this.id,
    required this.name,
    required this.version,
    required this.artifact,
    required this.url,
    this.language = '',
    this.nsfw = false,
    this.sourceNames = const <String>[],
  });

  /// 仓库内唯一标识：Mihon 用 `pkg`，Venera 用 `fileName`
  /// （Venera 的 `key` 是一族来源的标识，可能重复，不能用作 id）。
  final String id;

  final String name;

  /// 版本号；仓库没给时为空串。
  final String version;

  /// 语言（Mihon 的 `lang`）；Venera 没有该字段，为空串。
  final String language;

  final ExtensionArtifact artifact;

  /// 下载地址（已按仓库索引地址拼好）。
  final Uri url;

  /// 是否成人内容（Mihon 的 `nsfw`）。
  final bool nsfw;

  /// 扩展内含的来源名（Mihon 的 `sources[].name`）；Venera 为空。
  final List<String> sourceNames;

  /// 载体在本平台能不能运行：只有 JS 可以。
  bool get isRunnable => artifact == ExtensionArtifact.js;
}

/// 一份解析好的仓库索引。
class RepoIndex {
  const RepoIndex({required this.kind, required this.extensions});

  final RepoKind kind;

  final List<RepoExtension> extensions;
}

/// 已添加的仓库。
class ComicRepo {
  const ComicRepo({
    required this.id,
    required this.name,
    required this.url,
    required this.kind,
    this.extensionCount = 0,
    this.refreshedAt,
  });

  /// 稳定标识：索引地址归一化后的标识（同一地址重复添加即覆盖）。
  final String id;

  /// 显示名：添加时可填，为空时用地址主机名。
  final String name;

  /// 索引地址（已补全 index 文件名）。
  final Uri url;

  final RepoKind kind;

  /// 最近一次刷新解析出的扩展数量。
  final int extensionCount;

  /// 最近一次刷新时间；从未刷新过为 null。
  final DateTime? refreshedAt;

  ComicRepo copyWith({int? extensionCount, DateTime? refreshedAt}) =>
      ComicRepo(
        id: id,
        name: name,
        url: url,
        kind: kind,
        extensionCount: extensionCount ?? this.extensionCount,
        refreshedAt: refreshedAt ?? this.refreshedAt,
      );
}

/// 扩展安装记录：仓库扩展 → 漫画板块里的图源 id。
class InstalledExtension {
  const InstalledExtension({
    required this.repoId,
    required this.extensionId,
    required this.sourceId,
    required this.version,
    required this.installedAt,
  });

  final String repoId;
  final String extensionId;

  /// 安装落地后的图源标识（漫画板块图源表里的 id）。
  final String sourceId;

  /// 安装时的扩展版本。
  final String version;

  final DateTime installedAt;
}

/// 安装结果：成功带上落地的图源；失败带可读原因。
class RepoInstallResult {
  const RepoInstallResult.success(this.sourceId, this.sourceName)
      : message = null;

  const RepoInstallResult.failure(this.message)
      : sourceId = null,
        sourceName = null;

  final String? sourceId;
  final String? sourceName;
  final String? message;

  bool get isSuccess => sourceId != null;
}
