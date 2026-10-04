import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'repo/comic_repo_models.dart';
import 'repo/comic_repo_service.dart';

/// 仓库的扩展列表页：下载 / 安装 / 启用 / 停用 / 卸载。
///
/// 只属于漫画板块（由 [ComicRepoPage] 进入）。服务不认识 UI，页面不认识
/// sqlite 与解析器；安装落地在漫画板块的图源表里，因此启停与卸载等价于
/// 图源的启停与摘除。
class ComicExtensionPage extends StatefulWidget {
  const ComicExtensionPage({
    super.key,
    required this.service,
    required this.repo,
  });

  final ComicRepoService service;
  final ComicRepo repo;

  @override
  State<ComicExtensionPage> createState() => _ComicExtensionPageState();
}

class _ComicExtensionPageState extends State<ComicExtensionPage> {
  List<RepoExtension>? _extensions;
  Map<String, InstalledExtension> _installed = <String, InstalledExtension>{};
  Map<String, bool> _enabled = <String, bool>{};
  final Set<String> _busy = <String>{};
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final extensions = await widget.service.extensions(widget.repo.id);
      final installed = await widget.service.installed(widget.repo.id);
      final enabled = await widget.service.enabledStates();
      if (!mounted) return;
      setState(() {
        _extensions = extensions;
        _installed = installed;
        _enabled = enabled;
        _failed = false;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _refresh() async {
    try {
      final updated = await widget.service.refresh(widget.repo.id);
      if (!mounted) return;
      _toast('已刷新：${updated.extensionCount} 个扩展');
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

  Future<void> _install(RepoExtension extension) async {
    setState(() => _busy.add(extension.id));
    final result = await widget.service.install(widget.repo, extension);
    if (!mounted) return;
    setState(() => _busy.remove(extension.id));
    _toast(
      result.isSuccess
          ? '已安装：${result.sourceName}'
          : '安装失败：${result.message}',
    );
    await _reload();
  }

  Future<void> _toggle(InstalledExtension installed, bool enabled) async {
    await widget.service.setEnabled(installed, enabled);
    await _reload();
  }

  Future<void> _uninstall(RepoExtension extension, InstalledExtension installed) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载扩展'),
        content: Text('确定卸载「${extension.name}」？对应的漫画图源会一并移除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.service.uninstall(installed);
    await _reload();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: widget.repo.name,
      actions: <Widget>[
        IconButton(
          tooltip: '刷新仓库',
          icon: const Icon(Icons.refresh),
          onPressed: _refresh,
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_failed) {
      return const NoticeCard(
        title: '仓库存储不可用',
        subtitle: '漫画板块的扩展仓库库打不开，请重启应用后重试',
      );
    }
    final extensions = _extensions;
    if (extensions == null) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    if (extensions.isEmpty) {
      return const NoticeCard(
        title: '仓库里没有可用扩展',
        subtitle: '点右上角刷新，或检查仓库地址与类型是否匹配',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: extensions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final extension = extensions[index];
        final installed = _installed[extension.id];
        return _ExtensionTile(
          extension: extension,
          installed: installed,
          enabled: installed == null
              ? null
              : (_enabled[installed.sourceId] ?? false),
          busy: _busy.contains(extension.id),
          onInstall: () => _install(extension),
          onToggle: installed == null
              ? null
              : (value) => _toggle(installed, value),
          onUninstall: installed == null
              ? null
              : () => _uninstall(extension, installed),
        );
      },
    );
  }
}

/// 停用标记的颜色：与其他管理页同色系。
const Color _disabledColor = Color(0xFFFF8A80);

class _ExtensionTile extends StatelessWidget {
  const _ExtensionTile({
    required this.extension,
    required this.installed,
    required this.enabled,
    required this.busy,
    required this.onInstall,
    required this.onToggle,
    required this.onUninstall,
  });

  final RepoExtension extension;

  /// 已安装时的记录；未安装为 null。
  final InstalledExtension? installed;

  /// 已安装时的启用状态；未安装为 null。
  final bool? enabled;

  final bool busy;
  final VoidCallback onInstall;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onUninstall;

  @override
  Widget build(BuildContext context) {
    final installedHere = installed != null;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  extension.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              _Chip(
                text: extension.artifact.label,
                danger: !extension.isRunnable,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            <String>[
              if (extension.version.isNotEmpty) 'v${extension.version}',
              if (extension.language.isNotEmpty) extension.language,
              if (extension.nsfw) 'NSFW',
              if (installedHere) '已安装 v${installed!.version}',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          if (extension.sourceNames.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '来源：${extension.sourceNames.join('、')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
          ],
          if (!extension.isRunnable) ...<Widget>[
            const SizedBox(height: 6),
            const Text(
              'APK 载体需要 Android 运行时，本平台不能运行——只能浏览',
              style: TextStyle(fontSize: 12, color: _disabledColor),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (!extension.isRunnable)
                const TextButton(
                  onPressed: null,
                  child: Text('不可运行'),
                )
              else if (!installedHere)
                FilledButton.tonal(
                  onPressed: busy ? null : onInstall,
                  child: Text(busy ? '安装中…' : '安装'),
                )
              else ...<Widget>[
                Switch(value: enabled ?? false, onChanged: onToggle),
                IconButton(
                  tooltip: '卸载',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onUninstall,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: danger
            ? _disabledColor.withValues(alpha: 0.2)
            : Colors.white.withValues(alpha: 0.12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: danger ? _disabledColor : Colors.white,
        ),
      ),
    );
  }
}
