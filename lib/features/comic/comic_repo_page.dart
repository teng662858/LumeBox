import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'comic_extension_page.dart';
import 'repo/comic_repo_models.dart';
import 'repo/comic_repo_service.dart';
import 'repo/comic_repo_store.dart';

/// 漫画扩展仓库页：添加 / 删除 / 刷新仓库，进入仓库浏览扩展列表。
///
/// 只属于漫画板块：入口挂在漫画板块外壳上，服务自带板块守卫，其他板块
/// 既进不来、也没有句柄。页面只认 [ComicRepoService]，不认识 sqlite 与解析器。
class ComicRepoPage extends StatefulWidget {
  const ComicRepoPage({super.key, this.service, this.manager});

  /// 仓库服务；为空时打开正式实现（漫画板块）。测试注入用。
  final ComicRepoService? service;

  /// 漫画板块的图源端口；配合 [service] 为空时构造默认服务。
  final SourceManager? manager;

  @override
  State<ComicRepoPage> createState() => _ComicRepoPageState();
}

class _ComicRepoPageState extends State<ComicRepoPage> {
  ComicRepoService? _service;
  List<ComicRepo>? _repos;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // 只释放自己开的服务；注入进来的由调用方持有。
    if (widget.service == null) _service?.close();
    super.dispose();
  }

  Future<void> _open() async {
    if (widget.service != null) {
      _service = widget.service;
      await _reload();
      return;
    }
    try {
      final store = await ComicRepoStore.open();
      if (!mounted) {
        store.dispose();
        return;
      }
      setState(() {
        _service = ComicRepoService(
          store: store,
          sources: widget.manager ?? LumeSources.manager(Section.comic),
        );
      });
      await _reload();
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _reload() async {
    final service = _service;
    if (service == null) return;
    try {
      final repos = await service.repos();
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _failed = false;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _add() async {
    final service = _service;
    if (service == null) return;
    final request = await showDialog<_AddRepoRequest>(
      context: context,
      builder: (_) => const _AddRepoDialog(),
    );
    if (request == null || !mounted) return;

    try {
      final repo = await service.addRepo(
        url: request.url,
        kind: request.kind,
        name: request.name,
      );
      if (!mounted) return;
      _toast('已添加：${repo.name} · ${repo.extensionCount} 个扩展');
    } on SourceException catch (error) {
      if (!mounted) return;
      _toast('添加失败：${error.message}');
    } on FormatException catch (error) {
      if (!mounted) return;
      _toast('添加失败：${error.message}');
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      _toast('添加失败：$error');
    }
    await _reload();
  }

  Future<void> _refresh(ComicRepo repo) async {
    final service = _service;
    if (service == null) return;
    try {
      final updated = await service.refresh(repo.id);
      if (!mounted) return;
      _toast('已刷新：${updated.name} · ${updated.extensionCount} 个扩展');
    } on SourceException catch (error) {
      if (!mounted) return;
      _toast('刷新失败：${error.message}');
    } on FormatException catch (error) {
      if (!mounted) return;
      _toast('刷新失败：${error.message}');
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      _toast('刷新失败：$error');
    }
    await _reload();
  }

  Future<void> _delete(ComicRepo repo) async {
    final service = _service;
    if (service == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除仓库'),
        content: Text(
          '确定删除「${repo.name}」？\n'
          '已安装的扩展不会被卸载，仍可在「源管理」里继续使用。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await service.removeRepo(repo.id);
    await _reload();
  }

  Future<void> _browse(ComicRepo repo) async {
    final service = _service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicExtensionPage(service: service, repo: repo),
      ),
    );
    // 返回后重读：安装 / 卸载会改变仓库卡片上的信息。
    await _reload();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repos = _repos;
    return GlassScaffold(
      behindBar: true,
      title: '扩展仓库',
      floatingActionButton: repos == null || _failed
          ? null
          : FloatingActionButton(
              tooltip: '添加仓库',
              onPressed: _add,
              child: const Icon(Icons.add),
            ),
      child: _buildBody(repos),
    );
  }

  Widget _buildBody(List<ComicRepo>? repos) {
    if (_failed) {
      return const NoticeCard(
        title: '仓库存储不可用',
        subtitle: '漫画板块的扩展仓库库打不开，请重启应用后重试',
      );
    }
    if (repos == null) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    if (repos.isEmpty) {
      return const NoticeCard(
        title: '暂无仓库',
        subtitle: '点右下角按钮添加 Mihon / Tachiyomi 或 Venera 仓库地址',
      );
    }
    return ListView.separated(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.fromLTRB(16, 16, 16, 96)),
      itemCount: repos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _RepoTile(
        repo: repos[index],
        onBrowse: () => _browse(repos[index]),
        onRefresh: () => _refresh(repos[index]),
        onDelete: () => _delete(repos[index]),
      ),
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({
    required this.repo,
    required this.onBrowse,
    required this.onRefresh,
    required this.onDelete,
  });

  final ComicRepo repo;
  final VoidCallback onBrowse;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      onTap: onBrowse,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  repo.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: LumeTheme.fillStrong,
                ),
                child: Text(
                  repo.kind.label,
                  style: const TextStyle(fontSize: 11, color: LumeTheme.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            repo.url.toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          const SizedBox(height: 2),
          Text(
            repo.refreshedAt == null
                ? '尚未刷新'
                : '扩展 ${repo.extensionCount} 个 · 最近刷新 '
                    '${_formatTime(repo.refreshedAt!)}',
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: onRefresh,
              ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

/// 添加仓库的请求：地址 + 类型 + 可选名称。
class _AddRepoRequest {
  const _AddRepoRequest({
    required this.url,
    required this.kind,
    required this.name,
  });

  final String url;
  final RepoKind kind;
  final String name;
}

class _AddRepoDialog extends StatefulWidget {
  const _AddRepoDialog();

  @override
  State<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends State<_AddRepoDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  RepoKind _kind = RepoKind.mihon;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加仓库'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '仓库类型决定索引格式：Mihon / Tachiyomi 用 index.pb 或 index.min.json'
                '（APK 扩展，本平台只能浏览）；Venera 用 index.json（JS 扩展，可安装运行）。\n'
                '填根地址会自动探测索引文件；也可以直接粘贴 index.pb / index.min.json 的完整地址。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final kind in RepoKind.values)
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: _kind == kind,
                      onSelected: (_) => setState(() => _kind = kind),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                style: const TextStyle(color: LumeTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '仓库地址',
                  hintText: 'https://example.com/repo（可只给根地址）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                style: const TextStyle(color: LumeTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '名称（可选）',
                  hintText: '留空则用地址主机名',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _AddRepoRequest(
              url: _url.text,
              kind: _kind,
              name: _name.text,
            ),
          ),
          child: const Text('添加'),
        ),
      ],
    );
  }
}
