import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/net/source_subscription.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/tvbox_config.dart';
import '../../shared/widgets/glass_card.dart';

class TvBoxImportPage extends StatefulWidget {
  const TvBoxImportPage({super.key, this.manager, this.fetch, this.readFile});
  final SourceManager? manager;
  final Future<SourceFetchResult> Function(String)? fetch;
  final Future<({String name, String text})?> Function()? readFile;
  @override
  State<TvBoxImportPage> createState() => _TvBoxImportPageState();
}

class _TvBoxImportPageState extends State<TvBoxImportPage> {
  final _input = TextEditingController(), _search = TextEditingController();
  final _selected = <String>{}, _results = <String, String>{};
  TvBoxConfig? _config;
  String _label = '', _origin = '', _error = '', _progress = '';
  bool _busy = false, _cancel = false;
  String _filter = 'all';
  late final _manager = widget.manager ?? LumeSources.manager(Section.video);
  Future<SourceFetchResult> _fetch(String url) async {
    if (widget.fetch != null) return widget.fetch!(url);
    return SourceSubscription.viaHttp().fetch(url);
  }

  @override
  void dispose() {
    _cancel = true;
    _input.dispose();
    _search.dispose();
    super.dispose();
  }

  void _parse(String text, String name, String origin) {
    final config = TvBoxConfig.parse(text, origin: origin);
    setState(() {
      _config = config;
      _label = name;
      _origin = origin;
      _results.clear();
      _error = '';
      _progress = '';
      _selected
        ..clear()
        ..addAll(config.entries.where((e) => e.supported).map((e) => e.id));
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '读取或导入失败，请检查文件、地址和网络',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _local() => _run(() async {
    ({String name, String text})? selected;
    if (widget.readFile != null) {
      selected = await widget.readFile!();
    } else {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'TVBox 聚合 JSON',
            extensions: ['json'],
            uniformTypeIdentifiers: ['public.json', 'public.text'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('配置文件超过 4MB');
      }
      selected = (name: file.name, text: await file.readAsString());
    }
    if (selected != null && mounted) _parse(selected.text, selected.name, '');
  });
  Future<void> _loadInput() => _run(() async {
    final value = _input.text.trim();
    if (value.isEmpty) throw const FormatException('请粘贴配置链接或 JSON');
    if (TvBoxConfig.isHttp(value)) {
      final reply = await _fetch(value);
      if (mounted) _parse(reply.text, '在线配置', value);
    } else {
      _parse(value, '粘贴配置', '');
    }
  });
  Future<void> _import() => _run(() async {
    final targets = _config!.entries
        .where((e) => e.supported && _selected.contains(e.id))
        .toList();
    final existing = await _manager.list();
    final overlaps = targets
        .where((e) => existing.any((s) => s.id == e.id))
        .length;
    if (overlaps > 0 && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('更新已有源'),
          content: Text('所选条目中有 $overlaps 个源已安装，将更新其配置或脚本，保留现有源设置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续导入'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    _cancel = false;
    var next = 0, done = 0;
    Future<void> worker() async {
      while (!_cancel && mounted && next < targets.length) {
        final entry = targets[next++];
        try {
          final script = entry.kind == TvBoxKind.python
              ? entry.pythonScript((await _fetch(entry.api)).bytes)
              : entry.script;
          if (_cancel || !mounted) return;
          final result = await _manager.importScript(
            script,
            originUrl: entry.kind == TvBoxKind.python ? entry.api : _origin,
          );
          if (mounted) {
            setState(
              () => _results[entry.id] = result.isSuccess
                  ? '已导入${result.message?.isNotEmpty == true ? ' · ${result.message}' : ''}'
                  : '失败：${result.message ?? '运行环境无法加载'}',
            );
          }
        } catch (error) {
          if (mounted) {
            setState(
              () => _results[entry.id] =
                  '失败：${error is FormatException ? error.message : '下载或运行环境加载失败，请检查网络与依赖'}',
            );
          }
        }
        done++;
        if (mounted) {
          setState(() => _progress = '已处理 $done / ${targets.length}');
        }
      }
    }

    await Future.wait(
      List.generate(targets.length.clamp(0, 4), (_) => worker()),
    );
    if (mounted && _cancel) setState(() => _progress = '已停止；已完成的导入保留');
  });

  @override
  Widget build(BuildContext context) {
    final entries =
        _config?.entries
            .where(
              (entry) =>
                  (_filter == 'all' ||
                      (_filter == 'unsupported'
                          ? !entry.supported
                          : entry.kind.name == _filter)) &&
                  '${entry.name} ${entry.api}'.toLowerCase().contains(
                    _search.text.toLowerCase(),
                  ),
            )
            .toList() ??
        [];
    final successful = _results.values.where((r) => r.startsWith('已导入')).length;
    return PopScope(
      canPop: !_busy,
      child: GlassScaffold(
        effectModule: GlassModule.sources,
        title: 'TVBox 聚合配置导入',
        floatingActionButton: _config == null
            ? null
            : FloatingActionButton.extended(
                onPressed: _busy
                    ? () => setState(() => _cancel = true)
                    : _selected.isEmpty
                    ? null
                    : _import,
                icon: Icon(_busy ? Icons.stop : Icons.download),
                label: Text(_busy ? '停止后续导入' : '导入所选 ${_selected.length} 项'),
              ),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  const Text(
                    '导入到视频板块 · 支持采集 JSON/XML、Python Spider 和直播 M3U/TXT。导入成功不代表源站当前可用。',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _local,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('选择本地 JSON 文件'),
                  ),
                  TextField(
                    controller: _input,
                    enabled: !_busy,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '配置链接或 JSON',
                      hintText: 'https://…/config.json',
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _loadInput,
                        child: const Text('读取并预览'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final value = await Clipboard.getData(
                                  Clipboard.kTextPlain,
                                );
                                if (mounted) {
                                  setState(
                                    () => _input.text = value?.text ?? '',
                                  );
                                }
                              },
                        child: const Text('粘贴'),
                      ),
                    ],
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error.isNotEmpty) SelectableText(_error),
                  if (_config != null) ...[
                    Text(
                      '$_label · ${_config!.entries.length} 项 · 可导入 ${_config!.entries.where((e) => e.supported).length} 项',
                    ),
                    const Text('不兼容项会保留原因；不下载或执行 JAR/CSP 插件。'),
                    ExpansionTile(
                      title: Text('配置说明 ${_config!.notes.length} 项'),
                      children: [
                        for (final note in _config!.notes)
                          ListTile(dense: true, title: Text(note)),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _selected.addAll(
                                    entries
                                        .where((e) => e.supported)
                                        .map((e) => e.id),
                                  ),
                                ),
                          child: const Text('选择当前列表'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() => _selected.clear()),
                          child: const Text('取消全选'),
                        ),
                        if (_busy)
                          TextButton(
                            onPressed: () => setState(() => _cancel = true),
                            child: const Text('停止后续导入'),
                          ),
                      ],
                    ),
                    if (_results.isNotEmpty)
                      Text(
                        '导入成功 $successful 项 · 失败 ${_results.length - successful} 项',
                      ),
                    if (_progress.isNotEmpty) Text(_progress),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: '搜索名称或接口地址'),
                    ),
                    DropdownButton<String>(
                      value: _filter,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('全部条目')),
                        DropdownMenuItem(value: 'cms', child: Text('采集接口')),
                        DropdownMenuItem(
                          value: 'python',
                          child: Text('Python 源'),
                        ),
                        DropdownMenuItem(value: 'live', child: Text('直播列表')),
                        DropdownMenuItem(
                          value: 'unsupported',
                          child: Text('不兼容条目'),
                        ),
                      ],
                      onChanged: (value) => setState(() => _filter = value!),
                    ),
                  ],
                ],
              ),
            ),
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return CheckboxListTile(
                  value: _selected.contains(entry.id),
                  onChanged: _busy || !entry.supported
                      ? null
                      : (checked) => setState(() {
                          if (checked == true) {
                            _selected.add(entry.id);
                          } else {
                            _selected.remove(entry.id);
                          }
                        }),
                  title: Text(entry.name),
                  subtitle: Text(
                    _results[entry.id] ??
                        (entry.supported
                            ? '${entry.kind == TvBoxKind.cms
                                  ? (entry.type == 0 ? '采集 XML' : '采集 JSON')
                                  : entry.kind == TvBoxKind.python
                                  ? 'Python Spider'
                                  : '直播列表'}\n${entry.api}'
                            : entry.reason),
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }
}
