import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/js/cat_engines.dart';
import '../../core/net/network_settings.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../cat/cat_engine_settings_page.dart';
import 'add_source_button.dart';
import 'browse_page.dart';
import 'source_editor_page.dart';

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

  /// 正在测试的图源 id（按钮转圈用）。
  final Set<String> _testing = <String>{};

  /// 测试结论：sourceId → 结果。只存在内存里，退出页面即丢（每次测试都要
  /// 反映当下状态，缓存旧结论会误导）。
  final Map<String, SourceTestResult> _testResults = <String, SourceTestResult>{};

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

  /// 重命名：只改展示名（脚本与运行时不动），列表随即刷新。
  Future<void> _rename(SourceDescriptor source) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initialName: source.name),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _manager.rename(source.id, name);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已重命名为：${name.trim()}')),
    );
  }

  /// 打开可视化编辑器：表单生成脚本 → 导入（走与「+」相同的校验路径）。
  Future<void> _openEditor() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SourceEditorPage(
          section: widget.section,
          manager: widget.manager,
        ),
      ),
    );
    if (imported == true && mounted) await _reload();
  }

  /// 更新订阅源：从来源地址重新拉取并覆盖。
  Future<void> _updateSubscription(SourceDescriptor source) async {
    if (_testing.contains(source.id)) return;
    setState(() => _testing.add(source.id));
    try {
      final result = await _manager.updateFromSubscription(source.id);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            switch (result.status) {
              SourceUpdateStatus.updated => '「${source.name}」已更新到最新脚本',
              SourceUpdateStatus.unchanged => '「${source.name}」已是最新',
              SourceUpdateStatus.skipped => '跳过：${result.message}',
              SourceUpdateStatus.failed => '更新失败：${result.message}',
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _testing.remove(source.id));
    }
  }

  /// 批量刷新本板块的全部订阅源。
  Future<void> _updateAllSubscriptions() async {
    final targets = (_sources ?? const <SourceDescriptor>[])
        .where((source) => source.subscribed)
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本板块没有订阅导入的图源')),
      );
      return;
    }

    var updated = 0;
    var unchanged = 0;
    var failed = 0;
    for (final source in targets) {
      if (!mounted) return;
      setState(() => _testing.add(source.id));
      try {
        final result = await _manager.updateFromSubscription(source.id);
        if (!mounted) return;
        switch (result.status) {
          case SourceUpdateStatus.updated:
            updated++;
          case SourceUpdateStatus.unchanged:
            unchanged++;
          case SourceUpdateStatus.skipped:
          case SourceUpdateStatus.failed:
            failed++;
        }
      } finally {
        if (mounted) setState(() => _testing.remove(source.id));
      }
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '订阅刷新完成（${targets.length} 个）：更新 $updated'
          '${unchanged > 0 ? ' · 已最新 $unchanged' : ''}'
          '${failed > 0 ? ' · 失败 $failed' : ''}',
        ),
      ),
    );
  }

  /// 测试单个图源的连通性：走「载入脚本 → 取分类 → 取首屏列表」。
  ///
  /// 结果用**模态弹窗**如实展示（图源名称 / 状态 / 耗时 / 简短日志，底部「关闭」
  /// 结束，不自动消失）。结论同时落在列表行上——连着测好几个源时，关掉弹窗
  /// 也能一眼看到每个源的结果。
  Future<void> _test(SourceDescriptor source) async {
    if (_testing.contains(source.id)) return;
    setState(() => _testing.add(source.id));
    try {
      final result = await _manager.testConnectivity(source.id);
      if (!mounted) return;
      setState(() {
        _testResults[source.id] = result;
        // 结果已出，转圈到此为止：弹窗展示期间列表行保持可读。
        _testing.remove(source.id);
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _TestResultDialog(
          sourceName: source.name,
          result: result,
        ),
      );
    } finally {
      if (mounted && _testing.contains(source.id)) {
        setState(() => _testing.remove(source.id));
      }
    }
  }

  /// 批量测试本板块全部图源。
  ///
  /// 顺序逐个测（不是并发轰炸）：网络层已有并发限制，但测试本身会真实打目标站，
  /// 串行更稳、也让进度可见。停用的图源跳过（测试会如实报「已停用」，没意义）。
  Future<void> _testAll() async {
    final sources = (_sources ?? const <SourceDescriptor>[])
        .where((source) => source.enabled)
        .toList(growable: false);
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有已启用的图源可测试')),
      );
      return;
    }

    var ok = 0;
    var empty = 0;
    var failed = 0;
    for (final source in sources) {
      if (!mounted) return;
      setState(() => _testing.add(source.id));
      try {
        final result = await _manager.testConnectivity(source.id);
        if (!mounted) return;
        setState(() => _testResults[source.id] = result);
        switch (result.status) {
          case SourceTestStatus.ok:
            ok++;
          case SourceTestStatus.empty:
            empty++;
          case SourceTestStatus.failed:
            failed++;
        }
      } finally {
        if (mounted) setState(() => _testing.remove(source.id));
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '测试完成：可用 $ok'
          '${empty > 0 ? ' · 无内容 $empty' : ''}'
          '${failed > 0 ? ' · 不可用 $failed' : ''}',
        ),
      ),
    );
  }

  /// 网络配置：单图源的 UA / Cookie / 代理，覆盖全局设置（留空即继承）。
  ///
  /// 保存后丢弃该图源已建好的 HTTP 客户端与运行时——下次请求用新配置，
  /// 不会出现「改了配置还在用旧 Cookie」的错觉。
  Future<void> _editNetwork(SourceDescriptor source) async {
    final profile = await showDialog<NetworkProfile>(
      context: context,
      builder: (_) => _NetworkDialog(source: source),
    );
    if (profile == null || !mounted) return;
    await _manager.setNetwork(
      source.id,
      userAgent: profile.userAgent,
      cookie: profile.cookie,
      proxy: profile.proxy,
    );
    // 运行时重建：旧客户端带着旧 UA / Cookie，必须释放。
    await _manager.setEnabled(source.id, source.enabled);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          profile.isEmpty
              ? '已恢复「${source.name}」为全局网络设置'
              : '已保存「${source.name}」的网络配置',
        ),
      ),
    );
  }

  /// 导出脚本原文：弹窗展示全文，可一键复制（备份 / 迁移用）。
  Future<void> _export(SourceDescriptor source) async {
    final script = await _manager.exportScript(source.id);
    if (!mounted) return;
    if (script == null || script.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('读不到该图源的脚本')),
      );
      return;
    }
    var copied = false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导出脚本 · ${source.name}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              script,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: script));
              copied = true;
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('复制全文'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (copied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制「${source.name}」的脚本全文')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_manager.runtimeAvailable) {
      // 平台骨架：标题仍按「板块 · 源管理」口径，页面身份不含糊。
      return GlassScaffold(
        title: '${widget.section.label} · 源管理',
        child: const SkeletonNotice(),
      );
    }
    final sources = _sources;
    return GlassScaffold(
      title: '${widget.section.label} · 源管理',
      actions: <Widget>[
        IconButton(
          tooltip: '可视化编辑器',
          icon: const Icon(Icons.edit_note),
          onPressed: _openEditor,
        ),
        if (_sources != null && _sources!.any((source) => source.subscribed))
          IconButton(
            tooltip: '刷新全部订阅源',
            icon: const Icon(Icons.cloud_sync_outlined),
            onPressed: _testing.isEmpty ? _updateAllSubscriptions : null,
          ),
        if (_sources != null && _sources!.isNotEmpty)
          IconButton(
            tooltip: '批量测试连通性',
            icon: const Icon(Icons.network_check),
            onPressed: _testing.isEmpty ? _testAll : null,
          ),
        if (CatEngines.showsEngineSwitch(widget.section))
          IconButton(
            tooltip: '猫源引擎',
            icon: const Icon(Icons.memory_outlined),
            onPressed: _manageEngine,
          ),
        // 右上角统一的「+」添加图源：本地文件 / 订阅链接，只写本板块。
        AddSourceButton(
          section: widget.section,
          manager: _manager,
          onImported: _reload,
        ),
      ],
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
        title: '暂无源',
        subtitle: '点击右上角「+」导入源脚本',
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
          testing: _testing.contains(source.id),
          testResult: _testResults[source.id],
          onToggle: (enabled) => _toggle(source, enabled),
          onBrowse: source.enabled ? () => _browse(source) : null,
          onTest: () => _test(source),
          onUpdate: source.subscribed ? () => _updateSubscription(source) : null,
          onRename: () => _rename(source),
          onNetwork: () => _editNetwork(source),
          onExport: () => _export(source),
          onDelete: () => _delete(source),
        );
      },
    );
  }
}

/// 停用标记的颜色：与错误文案同色系，避免新造主题项。
const Color _disabledColor = Color(0xFFFF8A80);

/// 「网络已自定义」标记色：与停用区分开的提示色。
const Color _accentColor = Color(0xFF80D8FF);

/// 测试通过的标记色。
const Color _okColor = Color(0xFF81C784);

/// 单个图源行上的操作。
enum _SourceAction { browse, test, update, rename, network, exportScript, delete }

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    this.testing = false,
    this.testResult,
    required this.onToggle,
    required this.onBrowse,
    required this.onTest,
    required this.onUpdate,
    required this.onRename,
    required this.onNetwork,
    required this.onExport,
    required this.onDelete,
  });

  final SourceDescriptor source;

  /// 正在测试（按钮转圈）。
  final bool testing;

  /// 最近一次测试结论；未测试过为 null。
  final SourceTestResult? testResult;

  final ValueChanged<bool> onToggle;

  /// 停用的图源不可浏览，此时为 null。
  final VoidCallback? onBrowse;

  final VoidCallback onTest;

  /// 更新订阅源；本地导入的图源没有来源地址，此时为 null（菜单项置灰）。
  final VoidCallback? onUpdate;

  final VoidCallback onRename;

  final VoidCallback onNetwork;

  final VoidCallback onExport;

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
                    if (source.subscribed) ...<Widget>[
                      const SizedBox(width: 8),
                      const Text(
                        '订阅',
                        style: TextStyle(fontSize: 12, color: _accentColor),
                      ),
                    ],
                    if (source.hasNetworkOverride) ...<Widget>[
                      const SizedBox(width: 8),
                      const Text(
                        '网络已自定义',
                        style: TextStyle(fontSize: 12, color: _accentColor),
                      ),
                    ],
                    if (testResult != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        testResult!.status.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: switch (testResult!.status) {
                            SourceTestStatus.ok => _okColor,
                            SourceTestStatus.empty => _disabledColor,
                            SourceTestStatus.failed => _disabledColor,
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (testing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Switch(value: source.enabled, onChanged: onToggle),
          // 行内只留开关：浏览 / 重命名 / 导出 / 删除收进「更多」，
          // 手机窄屏也不会把四个按钮挤成一片。
          PopupMenuButton<_SourceAction>(
            tooltip: '更多操作',
            onSelected: (action) {
              switch (action) {
                case _SourceAction.browse:
                  onBrowse?.call();
                case _SourceAction.test:
                  onTest();
                case _SourceAction.update:
                  onUpdate?.call();
                case _SourceAction.rename:
                  onRename();
                case _SourceAction.network:
                  onNetwork();
                case _SourceAction.exportScript:
                  onExport();
                case _SourceAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<_SourceAction>>[
              PopupMenuItem<_SourceAction>(
                value: _SourceAction.browse,
                enabled: onBrowse != null,
                child: const Text('浏览'),
              ),
              const PopupMenuItem<_SourceAction>(
                value: _SourceAction.test,
                child: Text('测试连通性'),
              ),
              PopupMenuItem<_SourceAction>(
                value: _SourceAction.update,
                enabled: onUpdate != null,
                child: const Text('更新订阅源'),
              ),
              const PopupMenuItem<_SourceAction>(
                value: _SourceAction.rename,
                child: Text('重命名'),
              ),
              const PopupMenuItem<_SourceAction>(
                value: _SourceAction.network,
                child: Text('网络配置'),
              ),
              const PopupMenuItem<_SourceAction>(
                value: _SourceAction.exportScript,
                child: Text('导出脚本'),
              ),
              const PopupMenuItem<_SourceAction>(
                value: _SourceAction.delete,
                child: Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 连通性测试结果弹窗：图源名称 / 状态 / 耗时 / 简短日志，底部「关闭」结束。
///
/// 刻意做成**模态且不自动消失**：失败原因与耗时是排障要看的信息，SnackBar
/// 几秒就没了、长文案还没读完；结论同时保留在列表行上，关掉弹窗不丢。
class _TestResultDialog extends StatelessWidget {
  const _TestResultDialog({required this.sourceName, required this.result});

  /// 图源显示名（只用于展示，不认识图源内部状态）。
  final String sourceName;

  /// 引擎给出的测试结论（三态 + 说明 + 耗时）。
  final SourceTestResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连通性测试'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _InfoRow(label: '图源', value: sourceName),
          _InfoRow(
            label: '状态',
            value: result.status.label,
            valueColor:
                result.status == SourceTestStatus.ok ? _okColor : _disabledColor,
          ),
          _InfoRow(label: '耗时', value: _elapsedText(result.elapsed)),
          _InfoRow(label: '日志', value: _logText(result)),
        ],
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 耗时文本：毫秒 → 「0.8s」；失败可能拿不到耗时，如实给「—」不编造。
  static String _elapsedText(Duration? elapsed) {
    if (elapsed == null) return '—';
    return '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  /// 简短日志：引擎给的说明优先（空结果 / 失败原因）；成功时给一句摘要。
  static String _logText(SourceTestResult result) {
    final message = result.message.trim();
    if (message.isNotEmpty) return message;
    final items = result.itemCount ?? 0;
    final categories = result.categoryCount ?? 0;
    return '首屏返回 $items 条${categories > 0 ? ' · $categories 个分类' : ''}';
  }
}

/// 弹窗里的一行「标签 + 值」：标签定宽，值自动换行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;

  /// 值的颜色（默认白色；状态行用它表达三态）。
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: valueColor ?? Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 重命名弹窗：自己持有输入控制器（页面不跨弹窗生命周期持有它）。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名图源'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '图源名称',
          hintText: '例如：公开样片测试源',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 单图源网络配置弹窗：UA / Cookie / 代理三项，留空即继承全局设置。
///
/// 这三项对应文档要求：图源可自定义 UA / Cookie / 代理，且单图源配置优先于
/// 全局设置；Cookie 按图源隔离，不与其他图源共享。
class _NetworkDialog extends StatefulWidget {
  const _NetworkDialog({required this.source});

  final SourceDescriptor source;

  @override
  State<_NetworkDialog> createState() => _NetworkDialogState();
}

class _NetworkDialogState extends State<_NetworkDialog> {
  late final TextEditingController _ua =
      TextEditingController(text: widget.source.network.userAgent);
  late final TextEditingController _cookie =
      TextEditingController(text: widget.source.network.cookie);
  late final TextEditingController _proxy =
      TextEditingController(text: widget.source.network.proxy);

  @override
  void dispose() {
    _ua.dispose();
    _cookie.dispose();
    _proxy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('网络配置 · ${widget.source.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '留空即继承「设置 → 网络设置」里的全局值。这里的配置只作用于本图源，'
                'Cookie 不与其他图源共享。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ua,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'User-Agent',
                  hintText: '留空 = 用全局 UA',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cookie,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Cookie',
                  hintText: '留空 = 不带 Cookie',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxy,
                decoration: const InputDecoration(
                  labelText: '代理',
                  hintText: 'http://127.0.0.1:7890；留空 = 用全局代理',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(NetworkProfile.none),
          child: const Text('清除覆盖'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            NetworkProfile(
              userAgent: _ua.text,
              cookie: _cookie.text,
              proxy: _proxy.text,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
