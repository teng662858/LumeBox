import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/github_source_repository.dart';
import '../../core/source/source.dart';
import '../../core/source/source_import_routing.dart';
import '../../core/source/source_content_category.dart';
import '../../core/session/section.dart';
import 'source_import_flow.dart';
import '../../shared/widgets/glass_card.dart';

class SourceRepositoryPage extends StatefulWidget {
  const SourceRepositoryPage({
    super.key,
    this.store,
    this.clientFactory,
    this.managers = const {},
  });
  final RepositoryCredentialStore? store;
  final GithubSourceRepository Function(String)? clientFactory;
  final Map<Section, SourceManager> managers;
  @override
  State<SourceRepositoryPage> createState() => _SourceRepositoryPageState();
}

class _SourceRepositoryPageState extends State<SourceRepositoryPage> {
  final _token = TextEditingController();
  final _search = TextEditingController();
  late final _store = widget.store ?? RepositoryCredentialStore();
  GithubSourceRepository? _repo;
  RepositorySnapshot? _snapshot;
  RepositoryOperation? _operation;
  RepositoryPublication? _publication;
  Timer? _poll;
  bool _busy = false, _checking = false, _loading = true;
  bool _installing = false;
  String _filterKind = 'all';
  String _runtime = 'all';
  int _installation = 0;
  String? _error;
  final Map<String, Section> _installed = {};
  final Map<String, RepositoryUpload> _additions = {};
  final Map<String, RepositorySource> _removals = {};
  final Map<String, Map<String, String?>> _removalVersions = {};
  SourceManager _manager(Section section) =>
      widget.managers[section] ?? LumeSources.manager(section);

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _repo?.close();
    _token.dispose();
    _search.dispose();
    super.dispose();
  }

  GithubSourceRepository _client(String token) =>
      widget.clientFactory?.call(token) ?? GithubSourceRepository(token);

  Future<void> _restore() async {
    try {
      final data = await _store.load();
      if (!mounted) return;
      final token = data['token'] as String? ?? '';
      if (token.isNotEmpty) {
        _repo = _client(token);
        _operation = RepositoryOperation.parse(data['operation']);
        await _refresh();
        if (_operation?.manual == true && _operation?.dispatched == false) {
          _publication = const RepositoryPublication('已提交，等待手动发布');
        }
        if (_operation != null &&
            (!_operation!.manual || _operation!.dispatched)) {
          _watch();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取 GitHub 授权，请重新连接');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy || _installing) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } on RepositoryFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请刷新仓库核对结果后重试');
    } finally {
      if (mounted && !_installing) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    final repo = _client(_token.text.trim());
    try {
      await repo.connect();
      final snapshot = await repo.snapshot();
      await _readInstalled();
      await _store.save({'token': repo.token});
      if (!mounted) {
        repo.close();
        return;
      }
      _repo?.close();
      setState(() {
        _repo = repo;
        _snapshot = snapshot;
        _token.clear();
      });
    } catch (_) {
      repo.close();
      rethrow;
    }
  });

  Future<void> _refresh() async {
    final snapshot = await _repo!.snapshot();
    await _readInstalled();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  void _watch() {
    _poll?.cancel();
    _check();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  Future<void> _check() async {
    final operation = _operation;
    final repo = _repo;
    if (_checking || operation == null || repo == null) return;
    _checking = true;
    try {
      final result = await repo.publication(operation);
      if (!mounted || _operation != operation) return;
      setState(() {
        _publication = result;
        _error = null;
      });
      if (result.finished) {
        _poll?.cancel();
        await _refresh();
        if (result.succeeded && operation.installPaths.isNotEmpty && mounted) {
          setState(() {
            _installing = true;
            _busy = true;
          });
          final sources = _snapshot!.sources
              .where((s) => s.paths.any(operation.installPaths.contains))
              .toList();
          if (sources.isEmpty) {
            throw const RepositoryFailure('发布已完成，但新源尚未出现在最新仓库清单中。请刷新后重试安装。');
          }
          for (final source in sources) {
            if (!mounted) return;
            await _install(source);
          }
          final completed = RepositoryOperation(
            operation.branch,
            operation.commit,
            manual: operation.manual,
            dispatched: operation.dispatched,
          );
          _operation = completed;
          await _store.save({
            'token': repo.token,
            'operation': completed.toJson(),
          });
        }
      }
    } on RepositoryFailure catch (error) {
      _poll?.cancel();
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      _poll?.cancel();
      if (mounted) setState(() => _error = '无法查询发布结果，请手动刷新');
    } finally {
      _checking = false;
      if (_installing && mounted) {
        setState(() {
          _installing = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _submitted(RepositoryOperation operation) async {
    if (!mounted) return;
    setState(() {
      _operation = operation;
      _publication = RepositoryPublication(
        operation.manual ? '已提交，等待手动发布' : '已提交，等待 GitHub 发布',
      );
    });
    // The operation is visible even if persistence fails after GitHub accepted it.
    if (!operation.manual) _watch();
    await _store.save({'token': _repo!.token, 'operation': operation.toJson()});
  }

  Future<void> _publish() => _run(() async {
    final operation = _operation;
    if (operation == null || !operation.manual || operation.dispatched) return;
    if (!await _confirm('手动发布', '将发布已提交的变更，更新并核对仓库订阅。', confirmLabel: '确认发布') ||
        !mounted) {
      return;
    }
    await _repo!.dispatchPublication(operation);
    final dispatched = RepositoryOperation(
      operation.branch,
      operation.commit,
      installPaths: operation.installPaths,
      manual: true,
      dispatched: true,
    );
    setState(() {
      _operation = dispatched;
      _publication = const RepositoryPublication('已启动发布，等待 GitHub 工作流');
    });
    _watch();
    await _store.save({
      'token': _repo!.token,
      'operation': dispatched.toJson(),
    });
  });

  bool get _pending => _operation != null && !(_publication?.finished ?? false);

  Future<void> _upload() => _run(() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'LumeBox 源文件',
          extensions: ['js', 'py'],
          uniformTypeIdentifiers: ['public.item'],
        ),
      ],
    );
    if (files.isEmpty || !mounted) return;
    for (final file in files) {
      if (await file.length() > 4 * 1024 * 1024) {
        throw const RepositoryFailure('源文件不能超过 4MB');
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final text = utf8.decode(bytes);
      if (!RegExp(r'(?://|#)\s*@?LumeSource\s*[:=]').hasMatch(text)) {
        throw const RepositoryFailure(
          '此文件没有仓库源声明；REX 等模块请在源管理中使用“导入源”，无需上传 GitHub',
        );
      }
      var inferred = SourceImportRouting.repositoryKind(
        text,
        fallback: 'unknown',
      );
      if (inferred == 'unknown') {
        final selected = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('选择发布分类'),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('无法自动识别源分类，请选择发布目录。'),
              ),
              for (final entry in GithubSourceRepository.kinds.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, entry.key),
                  child: Text(entry.value),
                ),
            ],
          ),
        );
        if (selected == null || !mounted) return;
        inferred = selected;
      }
      String? contentCategory;
      if (['movie', 'video'].contains(inferred) &&
          SourceContentCategories.fromScript(text).isEmpty) {
        contentCategory = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('确认内容分类'),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('文件没有声明内容分类，请选择一次；下次会自动识别。'),
              ),
              for (final kind in [
                SourceContentCategory.movie,
                SourceContentCategory.adult,
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, kind.id),
                  child: Text(kind.label),
                ),
            ],
          ),
        );
        if (contentCategory == null || !mounted) return;
      }
      final draft = GithubSourceRepository.prepareUpload(
        file.name,
        bytes,
        fallbackKind: inferred,
        contentCategory: contentCategory,
      );
      final path = draft.path;
      final meta = draft.metadata;
      final existing = _snapshot!.sources
          .where((s) => s.id == meta.id || s.paths.contains(path))
          .firstOrNull;
      if (existing != null ||
          _snapshot!.files.containsKey(path) ||
          _additions.values.any(
            (item) => item.path == path || item.metadata.id == meta.id,
          )) {
        throw RepositoryFailure('「${meta.name}」的 ID 或路径已存在，请核对后重试');
      }
      setState(() => _additions[path] = draft);
    }
  });

  Future<void> _submitBatch() => _run(() async {
    if (_additions.isEmpty && _removals.isEmpty) return;
    final description = [
      for (final item in _additions.values)
        '新增：${item.metadata.name} · ${item.path}',
      for (final item in _removals.values)
        '删除：${item.name} · ${item.paths.join('、')}',
    ].join('\n');
    if (!await _confirm(
          '提交仓库变更',
          '以下变更将提交到草稿分支，不会立即发布：\n\n$description\n\n提交后可手动发布；发布成功后新增源会安装到本机。',
        ) ||
        !mounted) {
      return;
    }
    final previousHead = _snapshot!.head;
    await _refresh();
    if (!mounted) return;
    if (_snapshot!.head != previousHead) {
      throw const RepositoryFailure('仓库刚刚更新，待提交的选择已保留，请核对后重新提交');
    }
    final removals = <RepositorySource>[];
    for (final item in _removals.values) {
      final current = _snapshot!.sources
          .where((s) => s.id == item.id)
          .firstOrNull;
      if (current == null ||
          current.paths.length != item.paths.length ||
          !current.paths.toSet().containsAll(item.paths) ||
          current.paths.any(
            (path) =>
                _snapshot!.files[path] != _removalVersions[item.id]?[path],
          )) {
        throw const RepositoryFailure('仓库源已变化，待提交的选择已保留，请核对后重试');
      }
      removals.add(current);
    }
    final operation = await _repo!.applyBatch(
      _snapshot!,
      additions: _additions.values.toList(),
      removals: removals,
    );
    setState(() {
      _additions.clear();
      _removals.clear();
      _removalVersions.clear();
    });
    await _submitted(operation);
  });

  Future<void> _readInstalled() async {
    _installed.clear();
    for (final section in [Section.comic, Section.video]) {
      for (final source in await _manager(section).list()) {
        _installed[source.id] = section;
      }
    }
  }

  Future<void> _install(RepositorySource source) async {
    final text = await _repo!.readSource(_snapshot!, source);
    final section = SourceImportRouting.section(text);
    if (!mounted) return;
    final installed = await importSources(
      context,
      manager: _manager(section),
      section: section,
      items: [
        SourceImportItem(
          script: text,
          label: source.name,
          originUrl:
              'https://raw.githubusercontent.com/${GithubSourceRepository.repository}/main/${source.paths.first}',
        ),
      ],
    );
    if (installed) await _readInstalled();
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(
    String title,
    String text, {
    String confirmLabel = '确认提交',
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  void _toggleRemoval(RepositorySource source) {
    setState(() {
      if (_removals.containsKey(source.id)) {
        _removals.remove(source.id);
        _removalVersions.remove(source.id);
      } else {
        _removals[source.id] = source;
        _removalVersions[source.id] = {
          for (final path in source.paths) path: _snapshot!.files[path],
        };
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sources =
        _snapshot?.sources
            .where(
              (s) =>
                  (_filterKind == 'all' ||
                      s.paths.any(
                        (path) => path.startsWith('$_filterKind/'),
                      )) &&
                  (_runtime == 'all' ||
                      s.paths.any((path) => path.endsWith('.$_runtime'))) &&
                  (_installation == 0 ||
                      (_installed.containsKey(s.id) == (_installation == 1))) &&
                  '${s.name} ${s.id} ${s.paths.join(' ')}'
                      .toLowerCase()
                      .contains(_search.text.toLowerCase()),
            )
            .toList() ??
        [];
    return PopScope(
      canPop: !_busy && _additions.isEmpty && _removals.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy || (_additions.isEmpty && _removals.isEmpty)) {
          return;
        }
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃待提交的变更？'),
            content: const Text('尚未提交的添加和删除选择将被清除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃并退出'),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) {
          setState(() {
            _additions.clear();
            _removals.clear();
            _removalVersions.clear();
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
        }
      },
      child: GlassScaffold(
        effectModule: GlassModule.sources,
        title: '仓库维护',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'LumeBox-Sources · main',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(_error!),
              ),
            if (_repo == null && !_loading) ...[
              const Text(
                '使用此仓库的 GitHub fine-grained token：Contents 和 Actions 均需读写。令牌只保存在本机钥匙串。',
              ),
              TextField(
                controller: _token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'GitHub 令牌'),
                enabled: !_busy,
              ),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: const Text('授权并读取仓库'),
              ),
            ],
            if (_repo != null) ...[
              Align(
                alignment: Alignment.centerRight,
                child: PopupMenuButton<String>(
                  tooltip: '仓库选项',
                  onSelected: (value) {
                    if (value == 'refresh') {
                      _run(() async {
                        await _refresh();
                        if (_operation != null &&
                            (!_operation!.manual || _operation!.dispatched)) {
                          _watch();
                        }
                      });
                    } else if (value == 'disconnect') {
                      _run(() async {
                        await _store.clear();
                        _poll?.cancel();
                        _repo?.close();
                        if (mounted) {
                          setState(() {
                            _repo = null;
                            _snapshot = null;
                            _operation = null;
                            _publication = null;
                            _additions.clear();
                            _removals.clear();
                            _removalVersions.clear();
                          });
                        }
                      });
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Text('刷新仓库与发布状态'),
                    ),
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Text('移除授权'),
                    ),
                  ],
                ),
              ),
              if (_operation != null)
                Card(
                  child: ExpansionTile(
                    title: Text(_publication?.status ?? '等待查询发布结果'),
                    subtitle: const Text('查看提交与发布详情'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText('提交：${_operation!.commit}'),
                            if (_publication?.url.isNotEmpty ?? false)
                              SelectableText(_publication!.url),
                            TextButton(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text: _publication?.url.isNotEmpty == true
                                        ? _publication!.url
                                        : 'https://github.com/${GithubSourceRepository.repository}/actions',
                                  ),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('发布页面链接已复制')),
                                  );
                                }
                              },
                              child: const Text('复制 GitHub 发布页面链接'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (_operation?.manual == true && _operation?.dispatched == false)
                FilledButton.icon(
                  onPressed: _busy ? null : _publish,
                  icon: const Icon(Icons.publish),
                  label: const Text('发布待发布的变更'),
                ),
              const SizedBox(height: 12),
              const Text('仓库发布', style: TextStyle(fontWeight: FontWeight.w600)),
              FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: const Icon(Icons.upload_file),
                label: const Text('上传源文件'),
              ),
              if (_additions.isNotEmpty || _removals.isNotEmpty) ...[
                Text('待提交：新增 ${_additions.length}，删除 ${_removals.length}'),
                for (final item in _additions.values)
                  ListTile(
                    title: Text('新增：${item.metadata.name}'),
                    subtitle: Text(item.path),
                    trailing: IconButton(
                      tooltip: '取消添加',
                      icon: const Icon(Icons.close),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _additions.remove(item.path)),
                    ),
                  ),
                for (final item in _removals.values)
                  ListTile(
                    title: Text('删除：${item.name}'),
                    subtitle: Text(item.paths.join('、')),
                    trailing: IconButton(
                      tooltip: '取消删除',
                      icon: const Icon(Icons.close),
                      onPressed: _busy ? null : () => _toggleRemoval(item),
                    ),
                  ),
                FilledButton(
                  onPressed: _busy || _pending ? null : _submitBatch,
                  child: const Text('手动提交全部变更'),
                ),
                if (_pending) const Text('上一批尚未发布完成，可以继续选择，发布完成后提交。'),
              ],
              const SizedBox(height: 16),
              const Text(
                '仓库源列表',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                decoration: const InputDecoration(labelText: '搜索仓库源'),
                onChanged: (_) => setState(() {}),
              ),
              ExpansionTile(
                title: const Text('筛选'),
                children: [
                  Semantics(
                    label: '浏览分类',
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('repository-filter-$_filterKind'),
                      initialValue: _filterKind,
                      decoration: const InputDecoration(hintText: '浏览分类'),
                      items: [
                        const DropdownMenuItem(
                          value: 'all',
                          child: Text('全部分类'),
                        ),
                        for (final entry
                            in GithubSourceRepository.kinds.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _filterKind = value!),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (value, label) in [
                        ('all', '全部类型'),
                        ('py', 'PY'),
                        ('js', 'JS'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _runtime == value,
                          onSelected: (_) => setState(() => _runtime = value),
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (value, label) in [
                        (0, '全部安装状态'),
                        (1, '已安装'),
                        (2, '未安装'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _installation == value,
                          onSelected: (_) =>
                              setState(() => _installation = value),
                        ),
                    ],
                  ),
                ],
              ),
              Text('找到 ${sources.length} 个源'),
              for (final source in sources)
                Card(
                  child: ListTile(
                    title: Text(source.name),
                    subtitle: Text(
                      '${GithubSourceRepository.kinds[source.paths.first.split('/').first] ?? '源'} · ${source.paths.first.split('.').last.toUpperCase()} · ${source.version}\n${_installed.containsKey(source.id) ? '已安装' : '未安装'}',
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '源操作',
                      enabled: !_busy,
                      onSelected: (value) {
                        if (value == 'install') {
                          _run(() => _install(source));
                        } else {
                          _toggleRemoval(source);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'install',
                          child: Text('安装到本机'),
                        ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(
                            _removals.containsKey(source.id) ? '取消删除' : '从仓库删除',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
