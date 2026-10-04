import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/js/cat_engines.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../cat/cat_engine_settings_page.dart';
import 'browse_page.dart';

/// 板块页面：图源管理 + 浏览入口。
///
/// 本页只依赖图源管理端口 [SourceManager] 与数据源接口 [DataSource]：图源脚本、
/// 沙箱与数据库都在端口背后，页面不直接接触。默认走 [LumeSources] 的正式实现；
/// 注入替身时同一套界面可以在没有图源运行时的平台上被完整验证。
///
/// 隔离：一个页面绑定一个板块、持有一个管理器，本页不提供任何跨板块操作。
class SourceSectionPage extends StatefulWidget {
  const SourceSectionPage({super.key, required this.section, this.manager});

  final Section section;

  /// 图源管理端口。为空时使用 [LumeSources.manager] 的正式实现。
  final SourceManager? manager;

  @override
  State<SourceSectionPage> createState() => _SourceSectionPageState();
}

class _SourceSectionPageState extends State<SourceSectionPage> {
  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  List<SourceDescriptor>? _sources;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (_manager.runtimeAvailable) _reload();
  }

  @override
  void dispose() {
    _manager.close();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final sources = await _manager.list();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _failed = false;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _import() async {
    final script = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportDialog(),
    );
    if (script == null || script.trim().isEmpty) return;
    if (!mounted) return;

    final existing = <String>{
      for (final source in _sources ?? const <SourceDescriptor>[]) source.id,
    };
    final result = await _manager.importScript(script);
    if (!mounted) return;

    final descriptor = result.descriptor;
    final message = descriptor == null
        ? '导入失败：${result.message}'
        : existing.contains(descriptor.id)
            ? '已更新：${descriptor.name}'
            : '已导入：${descriptor.name}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    if (descriptor != null) await _reload();
  }

  Future<void> _toggle(SourceDescriptor source, bool enabled) async {
    await _manager.setEnabled(source.id, enabled);
    await _reload();
  }

  /// 删除前二次确认：删除会连同脚本与运行时一起移除。
  Future<void> _delete(SourceDescriptor source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除图源'),
        content: Text('确定删除「${source.name}」？其脚本与运行时将一并移除。'),
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
    await _manager.remove(source.id);
    await _reload();
  }

  /// 猫源引擎设置：**只有 Android 的猫源板块显示这个入口**（任务书第 4 条），
  /// 其他系统与其他板块隐藏。
  Future<void> _manageEngine() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CatEngineSettingsPage()),
    );
  }

  Future<void> _browse(SourceDescriptor source) async {
    final dataSource = await _manager.open(source.id);
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
    if (!_manager.runtimeAvailable) {
      return GlassScaffold(
        title: widget.section.label,
        child: const SkeletonNotice(),
      );
    }
    final sources = _sources;
    return GlassScaffold(
      title: widget.section.label,
      actions: <Widget>[
        if (CatEngines.showsEngineSwitch(widget.section))
          IconButton(
            tooltip: '猫源引擎',
            icon: const Icon(Icons.memory_outlined),
            onPressed: _manageEngine,
          ),
      ],
      floatingActionButton: sources == null
          ? null
          : FloatingActionButton(
              onPressed: _import,
              child: const Icon(Icons.add),
            ),
      child: sources == null
          ? (_failed
              ? const NoticeCard(
                  title: '图源存储不可用',
                  subtitle: LumeTheme.appName,
                )
              : const SourceStateView(state: SourceStateKind.loading))
          : _buildSources(sources),
    );
  }

  Widget _buildSources(List<SourceDescriptor> sources) {
    if (sources.isEmpty) {
      return const NoticeCard(
        title: '暂无图源',
        subtitle: '点击右下角按钮导入图源脚本',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sources.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final source = sources[index];
        return _SourceTile(
          source: source,
          onToggle: (enabled) => _toggle(source, enabled),
          onDelete: () => _delete(source),
          onBrowse: source.enabled ? () => _browse(source) : null,
        );
      },
    );
  }
}

/// 停用标记的颜色：与错误文案同色系，避免新造主题项。
const Color _disabledColor = Color(0xFFFF8A80);

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.onToggle,
    required this.onDelete,
    required this.onBrowse,
  });

  final SourceDescriptor source;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  /// 停用的图源不可浏览，此时为 null。
  final VoidCallback? onBrowse;

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

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final TextEditingController _controller = TextEditingController();

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
        width: 420,
        child: TextField(
          controller: _controller,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '粘贴图源脚本内容',
            border: OutlineInputBorder(),
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
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
