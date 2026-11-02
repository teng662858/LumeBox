import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/github_source_repository.dart';
import '../../shared/widgets/glass_card.dart';

class SourceRepositoryPage extends StatefulWidget {
  const SourceRepositoryPage({super.key, this.store, this.clientFactory});
  final RepositoryCredentialStore? store;
  final GithubSourceRepository Function(String)? clientFactory;
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
  String _kind = 'movie';
  String? _error;

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
        if (_operation != null) _watch();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取 GitHub 授权，请重新连接');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() task) async {
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    final repo = _client(_token.text.trim());
    try {
      await repo.connect();
      final snapshot = await repo.snapshot();
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
      }
    } on RepositoryFailure catch (error) {
      _poll?.cancel();
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      _poll?.cancel();
      if (mounted) setState(() => _error = '无法查询发布结果，请手动刷新');
    } finally {
      _checking = false;
    }
  }

  Future<void> _submitted(RepositoryOperation operation) async {
    if (!mounted) return;
    setState(() {
      _operation = operation;
      _publication = const RepositoryPublication('已提交，等待 GitHub 发布');
    });
    // The operation is visible even if persistence fails after GitHub accepted it.
    _watch();
    await _store.save({'token': _repo!.token, 'operation': operation.toJson()});
  }

  bool get _pending => _operation != null && !(_publication?.finished ?? false);

  Future<void> _upload() => _run(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'LumeBox 源文件',
          extensions: ['js', 'py'],
          uniformTypeIdentifiers: ['public.item'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    if (await file.length() > 4 * 1024 * 1024) {
      throw const RepositoryFailure('源文件不能超过 4MB');
    }
    final bytes = await file.readAsBytes();
    final path = '$_kind/${file.name}';
    final meta = GithubSourceRepository.validateUpload(path, bytes);
    final accepted = await _confirm(
      '上传源到 GitHub',
      '将新增「${meta.name}」${meta.version}\n$path\n发布成功后，所有使用该仓库订阅的用户都能获取。上传前请确认分类、搜索、封面和播放已实测。',
    );
    if (!accepted || !mounted) return;
    await _refresh();
    if (!mounted) return;
    await _submitted(await _repo!.add(_snapshot!, path, bytes));
  });

  Future<bool> _confirm(String title, String text) async =>
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
              child: const Text('确认提交'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _delete(RepositorySource source) => _run(() async {
    if (!await _confirm(
          '从 GitHub 删除源',
          '将从远端仓库删除「${source.name}」及其 ${source.paths.length} 个文件，并从两条线路订阅移除。此操作影响所有订阅用户。\n\n${source.paths.join('\n')}',
        ) ||
        !mounted) {
      return;
    }
    final previous = _snapshot!;
    await _refresh();
    if (!mounted) return;
    if (_snapshot!.head != previous.head) {
      throw const RepositoryFailure('仓库刚刚更新，请核对刷新后的源再删除');
    }
    final selected = _snapshot!.sources.firstWhere((s) => s.id == source.id);
    await _submitted(await _repo!.remove(_snapshot!, selected));
  });

  @override
  Widget build(BuildContext context) {
    final sources =
        _snapshot?.sources
            .where(
              (s) =>
                  s.paths.first.startsWith('$_kind/') &&
                  '${s.name} ${s.id} ${s.paths.join(' ')}'
                      .toLowerCase()
                      .contains(_search.text.toLowerCase()),
            )
            .toList() ??
        [];
    return PopScope(
      canPop: !_busy,
      child: GlassScaffold(
        effectModule: GlassModule.sources,
        title: 'GitHub 仓库源管理',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '远端仓库：teng662858/LumeBox-Sources · main\n这里的增删会真实修改 GitHub 文件和公共订阅。',
            ),
            const SizedBox(height: 12),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(_error!),
              ),
            if (_repo == null && !_loading) ...[
              const Text(
                '使用此仓库的 GitHub fine-grained token：Contents 读写、Actions 只读。令牌只保存在本机钥匙串。',
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
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _refresh();
                            if (_operation != null) {
                              _watch();
                            }
                          }),
                    child: const Text('刷新仓库与发布状态'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _store.clear();
                            _poll?.cancel();
                            _repo?.close();
                            if (mounted) {
                              setState(() {
                                _repo = null;
                                _snapshot = null;
                                _operation = null;
                                _publication = null;
                              });
                            }
                          }),
                    child: const Text('移除授权'),
                  ),
                ],
              ),
              if (_operation != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_publication?.status ?? '等待查询发布结果'),
                        SelectableText('提交：${_operation!.commit}'),
                        if (_publication?.url.isNotEmpty ?? false)
                          SelectableText(_publication!.url),
                        TextButton(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                              text: _publication?.url.isNotEmpty == true
                                  ? _publication!.url
                                  : 'https://github.com/${GithubSourceRepository.repository}/actions',
                            ),
                          ),
                          child: const Text('复制 GitHub 发布页面链接'),
                        ),
                      ],
                    ),
                  ),
                ),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: '仓库内容分类'),
                items: [
                  for (final entry in GithubSourceRepository.kinds.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _kind = value!),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy || _pending ? null : _upload,
                icon: const Icon(Icons.upload_file),
                label: const Text('选择文件并新增到 GitHub'),
              ),
              TextField(
                controller: _search,
                decoration: const InputDecoration(labelText: '搜索仓库源'),
                onChanged: (_) => setState(() {}),
              ),
              Text('当前分类 ${sources.length} 个源'),
              for (final source in sources)
                Card(
                  child: ListTile(
                    title: Text(source.name),
                    subtitle: Text('${source.version} · ${source.paths.first}'),
                    trailing: IconButton(
                      tooltip: '从 GitHub 删除源',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _busy || _pending
                          ? null
                          : () => _delete(source),
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
