import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'browse_page.dart';

/// 全局图源总管理页：一个页面汇总四个板块的图源，逐个板块执行管理操作。
///
/// 与板块内的管理入口相比，本页只改变「范围」，不改变「通道」：四个板块各持有
/// 一个 [SourceManager]（一板块一端口），列表、导入、启停、删除与浏览全部经对应
/// 板块自己的端口完成，页面上不存在任何跨板块的共用路径——板块隔离由这一条在
/// 本页被显式维持。
///
/// 范围边界：当前源切换（「设为当前图源」）经确认延后，不在本页实现；板块内
/// 业务页自己的切换入口不在本页范围内。
///
/// 平台边界：图源运行时不可用时（Android / Windows）只显示骨架，不打开任何
/// 板块的库、不创建任何沙箱。生命周期：退出时逐个 `close()` 四个板块的管理器，
/// 释放各自的 JSContext、HTTP 客户端与数据库连接。
class GlobalSourcePage extends StatefulWidget {
  const GlobalSourcePage({super.key, this.managerFactory});

  /// 板块级管理端口工厂：一个板块一个实例。为空时使用 `LumeSources.manager`。
  final SourceManager Function(Section section)? managerFactory;

  @override
  State<GlobalSourcePage> createState() => _GlobalSourcePageState();
}

class _GlobalSourcePageState extends State<GlobalSourcePage> {
  /// 一板块一端口：本页唯一的管理通道，四个板块互相独立。
  late final Map<Section, SourceManager> _managers = <Section, SourceManager>{
    for (final section in Section.values)
      section: (widget.managerFactory ?? LumeSources.manager)(section),
  };

  /// 板块 → 图源列表（只保存读取结果，不缓存其他状态）。
  final Map<Section, List<SourceDescriptor>> _sources =
      <Section, List<SourceDescriptor>>{};

  /// 读取失败的板块（存储故障）。单个板块失败不影响其他板块。
  final Set<Section> _failed = <Section>{};

  bool _loading = true;

  /// 当前筛选的板块；null 表示「全部」。
  Section? _filter;

  /// 平台是否提供图源运行时。正式实现四个板块同值，任一可用即认为可用。
  bool get _runtimeAvailable =>
      _managers.values.any((manager) => manager.runtimeAvailable);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    // 退出即释放：四个板块各自的运行时与数据库连接一起收口。
    for (final manager in _managers.values) {
      manager.close();
    }
    super.dispose();
  }

  /// 重新读取四个板块。互不阻塞：某板块失败只标记该板块。
  Future<void> _reload() async {
    if (!_runtimeAvailable) return;
    await Future.wait(Section.values.map(_reloadSection));
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _reloadSection(Section section) async {
    final manager = _managers[section]!;
    if (!manager.runtimeAvailable) return;
    try {
      final sources = await manager.list();
      if (!mounted) return;
      setState(() {
        _sources[section] = sources;
        _failed.remove(section);
      });
    } catch (error, stackTrace) {
      // 只记录不冒泡：一个板块的存储故障不牵连其他板块（宪法第 8 条）。
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed.add(section));
    }
  }

  List<SourceDescriptor> _listOf(Section section) =>
      _sources[section] ?? const <SourceDescriptor>[];

  int _enabledCount(Section section) =>
      _listOf(section).where((source) => source.enabled).length;

  int get _totalCount => Section.values.fold(
        0,
        (sum, section) => sum + _listOf(section).length,
      );

  int get _enabledTotal => Section.values.fold(
        0,
        (sum, section) => sum + _enabledCount(section),
      );

  /// 导入：先选目标板块，再粘贴脚本；只写所选板块的库。
  Future<void> _import({Section? target}) async {
    final request = await showDialog<_ImportRequest>(
      context: context,
      builder: (_) => _ImportDialog(
        initialSection: target ?? _filter ?? Section.novel,
      ),
    );
    if (request == null || !mounted) return;
    if (request.script.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('脚本内容为空')),
      );
      return;
    }

    final section = request.section;
    final existing = <String>{
      for (final source in _listOf(section)) source.id,
    };
    final result = await _managers[section]!.importScript(request.script);
    if (!mounted) return;

    final descriptor = result.descriptor;
    final message = descriptor == null
        ? '导入失败：${result.message}'
        : existing.contains(descriptor.id)
            ? '已更新：${descriptor.name}（${section.label}）'
            : '已导入：${descriptor.name}（${section.label}）';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    if (descriptor != null) await _reloadSection(section);
  }

  /// 启停：停用即释放该图源的运行时；只作用于所属板块。
  Future<void> _toggle(
    Section section,
    SourceDescriptor source,
    bool enabled,
  ) async {
    await _managers[section]!.setEnabled(source.id, enabled);
    await _reloadSection(section);
  }

  /// 删除前二次确认：删除会连同脚本与运行时一起移除，只删所属板块的记录。
  Future<void> _delete(Section section, SourceDescriptor source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图源'),
        content: Text(
          '确定删除「${source.name}」（${section.label}）？'
          '其脚本与运行时将一并移除。',
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
    await _managers[section]!.remove(source.id);
    await _reloadSection(section);
  }

  Future<void> _browse(Section section, SourceDescriptor source) async {
    final dataSource = await _managers[section]!.open(source.id);
    if (!mounted) return;
    if (dataSource == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图源不可用')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BrowsePage(dataSource: dataSource)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: '图源总管理',
      floatingActionButton: _runtimeAvailable && !_loading
          ? FloatingActionButton(
              tooltip: '导入图源',
              onPressed: () => _import(),
              child: const Icon(Icons.add),
            )
          : null,
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_runtimeAvailable) return const SkeletonNotice();
    if (_loading) return const SourceStateView(state: SourceStateKind.loading);

    final allEmpty = Section.values.every((section) => _listOf(section).isEmpty);
    if (allEmpty && _failed.isEmpty) {
      return NoticeCard(
        title: '四板块均无图源',
        subtitle: '图源由用户导入：点右下角按钮，并选择导入的目标板块',
        action: FilledButton(
          onPressed: () => _import(),
          child: const Text('导入图源'),
        ),
      );
    }

    final visible =
        _filter == null ? Section.values : <Section>[_filter!];
    return Column(
      children: <Widget>[
        _buildFilterBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: <Widget>[
              for (final section in visible) ..._buildSectionChildren(section),
            ],
          ),
        ),
      ],
    );
  }

  /// 板块筛选：每个分区显示「启用 / 总数」，全部与四个板块都能作为筛选。
  Widget _buildFilterBar() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          _buildChip(null, '全部', _enabledTotal, _totalCount),
          for (final section in Section.values)
            _buildChip(
              section,
              section.label,
              _enabledCount(section),
              _listOf(section).length,
            ),
        ],
      ),
    );
  }

  Widget _buildChip(Section? section, String label, int enabled, int total) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label $enabled/$total'),
        selected: _filter == section,
        onSelected: (_) => setState(() => _filter = section),
      ),
    );
  }

  List<Widget> _buildSectionChildren(Section section) {
    final sources = _listOf(section);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 0, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                section.label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            Text(
              '启用 ${_enabledCount(section)} / 共 ${sources.length}',
              style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            IconButton(
              tooltip: '导入到${section.label}',
              icon: const Icon(Icons.add),
              onPressed: () => _import(target: section),
            ),
          ],
        ),
      ),
      if (_failed.contains(section))
        const _SectionNote('该板块图源存储不可用')
      else if (sources.isEmpty)
        const _SectionNote('暂无图源'),
      for (final source in sources)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SourceTile(
            source: source,
            onToggle: (enabled) => _toggle(section, source, enabled),
            onBrowse: source.enabled ? () => _browse(section, source) : null,
            onDelete: () => _delete(section, source),
          ),
        ),
    ];
  }
}

/// 停用标记的颜色：与板块管理页同色系，避免新造主题项。
const Color _disabledColor = Color(0xFFFF8A80);

/// 分组内的一行说明（空板块 / 存储故障）。
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
        ),
      );
}

/// 图源条目：名称版本 + 启停 / 浏览 / 删除。
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.onToggle,
    required this.onBrowse,
    required this.onDelete,
  });

  final SourceDescriptor source;

  final ValueChanged<bool> onToggle;

  /// 停用的图源不可浏览，此时为 null。
  final VoidCallback? onBrowse;

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Text(
                      source.version.isEmpty
                          ? LumeTheme.appName
                          : source.version,
                      style: const TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                    if (!source.enabled) ...<Widget>[
                      const SizedBox(width: 8),
                      const Text(
                        '已停用',
                        style: TextStyle(fontSize: 12, color: _disabledColor),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Switch(value: source.enabled, onChanged: onToggle),
          IconButton(
            tooltip: '浏览',
            icon: const Icon(Icons.chevron_right),
            onPressed: onBrowse,
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// 导入请求：目标板块 + 脚本内容。
class _ImportRequest {
  const _ImportRequest({required this.section, required this.script});

  final Section section;
  final String script;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.initialSection});

  final Section initialSection;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final TextEditingController _controller = TextEditingController();
  late Section _section = widget.initialSection;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadBuiltin() async {
    final text = await rootBundle.loadString('assets/js/example_source.js');
    if (!mounted) return;
    _controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入图源'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '目标板块：图源只写入所选板块，不会跨板块共用。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final section in Section.values)
                    ChoiceChip(
                      label: Text(section.label),
                      selected: _section == section,
                      onSelected: (_) => setState(() => _section = section),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '粘贴图源脚本内容',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _loadBuiltin,
          child: const Text('载入内置示例'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _ImportRequest(section: _section, script: _controller.text),
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
