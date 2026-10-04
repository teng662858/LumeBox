import '../../../core/session/section.dart';
import '../../../core/source/source.dart';
import '../../../core/util/lume_log.dart';
import 'comic_repo_fetcher.dart';
import 'comic_repo_models.dart';
import 'comic_repo_parser.dart';
import 'comic_repo_store.dart';

/// 漫画扩展仓库服务：仓库与扩展的全部编排（添加 / 刷新 / 安装 / 启停 / 卸载）。
///
/// **只服务漫画板块**（宪法第 3、4 条）：构造时校验板块，非漫画直接拒绝；
/// 解析与存储都在漫画模块内（`lib/features/comic/repo/`），其他板块既没有
/// 调用入口，也没有句柄。
///
/// 安装落地处是漫画板块自己的图源端口（[SourceManager]，即漫画板块的
/// SourceRegistry）：JS 扩展脚本经与「导入图源」完全相同的校验与落库路径进入
/// `sections/comic/`，因此天然与其他板块隔离。APK 载体（Mihon 仓库）如实拒绝：
/// 本平台没有 Android 运行时，只能浏览。
class ComicRepoService {
  ComicRepoService({
    required this.store,
    required this.sources,
    RepoFetcher? fetcher,
    Section section = Section.comic,
  }) : _fetcher = fetcher ?? LumeHttpRepoFetcher(),
       _ownsFetcher = fetcher == null {
    if (section != Section.comic) {
      throw ArgumentError(
        '漫画扩展仓库只服务漫画板块，收到「${section.id}」——其他板块不得调用相关解析',
      );
    }
  }

  /// 漫画板块独占的仓库库。
  final ComicRepoStore store;

  /// 漫画板块的图源端口（安装 / 启停 / 卸载的落地处）。由调用方持有与释放。
  final SourceManager sources;

  final RepoFetcher _fetcher;
  final bool _ownsFetcher;

  /// 已添加的仓库。
  Future<List<ComicRepo>> repos() async => store.repos();

  /// 添加仓库：补全索引地址 → 抓取 → 按类型独立解析 → 落库。
  ///
  /// 地址已带 `.json` 时原样使用；否则按仓库类型补全索引文件名
  /// （Mihon → `index.min.json`，Venera → `index.json`）。
  /// 抓取或解析失败抛出 [SourceException] / [FormatException]，由页面转成提示。
  Future<ComicRepo> addRepo({
    required String url,
    required RepoKind kind,
    String? name,
  }) async {
    final indexUri = indexUriFor(url, kind);
    final index = await _fetchIndex(kind, indexUri);
    final trimmedName = name?.trim() ?? '';
    final record = ComicRepo(
      id: indexUri.toString(),
      name: trimmedName.isEmpty ? _defaultName(indexUri) : trimmedName,
      url: indexUri,
      kind: kind,
      extensionCount: index.extensions.length,
      refreshedAt: DateTime.now(),
    );
    store.upsertRepo(record);
    store.replaceExtensions(record.id, index.extensions);
    return record;
  }

  /// 刷新仓库：重新抓取索引、重解析并更新扩展表与计数。
  Future<ComicRepo> refresh(String repoId) async {
    final existing = store.repo(repoId);
    if (existing == null) {
      throw SourceException(SourceErrorKind.notFound, '仓库不存在：$repoId');
    }
    final index = await _fetchIndex(existing.kind, existing.url);
    store.replaceExtensions(existing.id, index.extensions);
    final updated = existing.copyWith(
      extensionCount: index.extensions.length,
      refreshedAt: DateTime.now(),
    );
    store.upsertRepo(updated);
    return updated;
  }

  /// 删除仓库。已安装的扩展不随之卸载（它们是独立的漫画图源）。
  Future<void> removeRepo(String repoId) async => store.removeRepo(repoId);

  /// 仓库里的可用扩展（来自最近一次刷新缓存下来的索引）。
  Future<List<RepoExtension>> extensions(String repoId) async =>
      store.extensionsOf(repoId);

  /// 仓库里已安装的扩展：extensionId → 安装记录。
  Future<Map<String, InstalledExtension>> installed(String repoId) async =>
      store.installedOf(repoId);

  /// 已安装扩展的启用状态（来自漫画板块图源表）：sourceId → enabled。
  Future<Map<String, bool>> enabledStates() async {
    final list = await sources.list();
    return <String, bool>{
      for (final source in list) source.id: source.enabled,
    };
  }

  /// 安装扩展。
  ///
  /// - JS 载体：抓取脚本 → 走与「导入图源」相同的校验与落库链路；
  /// - APK 载体：如实拒绝（本平台没有 Android 运行时）。
  /// 失败一律以 [RepoInstallResult.failure] 返回可读原因，不向页面抛异常。
  Future<RepoInstallResult> install(
    ComicRepo repo,
    RepoExtension extension,
  ) async {
    if (extension.artifact == ExtensionArtifact.apk) {
      return const RepoInstallResult.failure(
        'APK 载体需要 Android 运行时，当前平台不能运行（仅支持浏览）',
      );
    }
    final String script;
    try {
      script = await _fetcher.fetchText(extension.url);
    } on SourceException catch (error) {
      return RepoInstallResult.failure('下载失败：${error.message}');
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return RepoInstallResult.failure('下载失败：$error');
    }
    final result = await sources.importScript(script);
    final descriptor = result.descriptor;
    if (descriptor == null) {
      return RepoInstallResult.failure('安装失败：${result.message}');
    }
    store.markInstalled(
      repoId: repo.id,
      extensionId: extension.id,
      sourceId: descriptor.id,
      version: extension.version,
    );
    return RepoInstallResult.success(descriptor.id, descriptor.name);
  }

  /// 启用 / 停用已安装的扩展（等价于漫画板块图源的启停）。
  Future<void> setEnabled(InstalledExtension installed, bool enabled) =>
      sources.setEnabled(installed.sourceId, enabled);

  /// 卸载扩展：先摘除漫画板块里的图源，再清掉安装记录。
  Future<void> uninstall(InstalledExtension installed) async {
    await sources.remove(installed.sourceId);
    store.clearInstalled(
      repoId: installed.repoId,
      extensionId: installed.extensionId,
    );
  }

  /// 释放服务自有的资源：仓库库（始终）与自建的抓取器（仅自己创建时）。
  ///
  /// 图源端口由调用方持有，不在这里释放。
  void close() {
    store.dispose();
    if (_ownsFetcher) _fetcher.dispose();
  }

  Future<RepoIndex> _fetchIndex(RepoKind kind, Uri indexUri) async {
    final text = await _fetcher.fetchText(indexUri);
    return ComicRepoParser.parseText(kind, text, baseUri: indexUri);
  }

  /// 索引地址：带 `.json` 原样用；否则按仓库类型补全索引文件名。
  /// 只接受 http / https 地址（仓库索引一律走网络）。
  static Uri indexUriFor(String url, RepoKind kind) {
    final trimmed = url.trim();
    final parsed = Uri.tryParse(trimmed);
    final scheme = parsed?.scheme.toLowerCase();
    if (parsed == null ||
        parsed.host.isEmpty ||
        (scheme != 'http' && scheme != 'https')) {
      throw SourceException(
        SourceErrorKind.callFailed,
        '仓库地址无效（需要 http/https）：$url',
      );
    }
    if (parsed.path.toLowerCase().endsWith('.json')) return parsed;
    final path =
        parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed.replace(path: '$path${kind.indexPath}');
  }

  /// 默认显示名：地址主机名（用户没填名字时用）。
  static String _defaultName(Uri indexUri) => indexUri.host;
}
