import '../../core/source/source_subscription_sync.dart';
import '../../shared/widgets/source_update_badge.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/source/source_content_rating.dart';
import '../../shared/widgets/source_rating_badge.dart';
import '../../core/source/source_order.dart';
import 'source_maintenance.dart';
import 'source_action_dialogs.dart';
import '../../core/reading/reading_library.dart';
import '../../core/source/source_preferences.dart';
import '../../core/source/source_picker_groups.dart';
import '../../shared/widgets/source_icon.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/js/cat_engines.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../cat/cat_engine_settings_page.dart';
import 'add_source_button.dart';
import 'source_editor_page.dart';
import 'source_import_dialog.dart';

/// 板块页面：图源维护与批量操作。日常五项操作位于首页源抽屉。
///
/// 本页只依赖图源管理端口 [SourceManager] 与数据源接口 [DataSource]：图源脚本、
/// 沙箱与数据库都在端口背后，页面不直接接触。默认走 [LumeSources] 的正式实现；
/// 注入替身时同一套界面可以在没有图源运行时的平台上被完整验证。
///
/// 隔离：一个页面绑定一个板块、持有一个管理器，本页不提供任何跨板块操作。
class SourceSectionPage extends StatefulWidget {
  const SourceSectionPage({
    super.key,
    required this.section,
    this.manager,
    this.readLocalScripts,
    this.fetchSubscription,
  });

  final Section section;

  /// 源管理端口。为空时使用 [LumeSources.manager] 的正式实现。
  final SourceManager? manager;

  /// 本地文件 / 订阅拉取端口，透传给导入弹窗（测试注入用）。
  final Future<List<({String name, String text})>> Function()? readLocalScripts;
  final Future<SourceFetchResult> Function(String url)? fetchSubscription;

  @override
  State<SourceSectionPage> createState() => _SourceSectionPageState();
}

class _SourceSectionPageState extends State<SourceSectionPage> {
  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  List<SourceDescriptor>? _sources;
  bool _failed = false;
  String _sourceQuery = '';
  String? _group;
  bool _compact = false;
  int _sourceFilter = 0;
  bool _selecting = false;
  bool _maintaining = false;
  final Set<String> _selectedIds = {};
  String? _maintenanceStatus;

  /// 正在测试的图源 id（按钮转圈用）。
  final Set<String> _testing = <String>{};

  /// 测试结论：sourceId → 结果。只存在内存里，退出页面即丢（每次测试都要
  /// 反映当下状态，缓存旧结论会误导）。
  final Map<String, SourceTestResult> _testResults =
      <String, SourceTestResult>{};

  @override
  void initState() {
    super.initState();
    SourceSubscriptionSync.revision(widget.section)
        .addListener(_subscriptionChanged);
    if (_manager.runtimeAvailable) _reload();
  }

  void _subscriptionChanged() {
    if (mounted && _manager.runtimeAvailable) _reload();
  }

  @override
  void dispose() {
    SourceSubscriptionSync.revision(widget.section)
        .removeListener(_subscriptionChanged);
    if (widget.manager == null) _manager.close();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      if (widget.manager == null) await ReadingLibrary.open(widget.section);
      final sources = await _manager.list();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _compact =
            ReadingLibrary.find(widget.section)
                ?.setting('source.manager.compact') ==
            'true';
        _selectedIds.removeWhere(
          (id) => !sources.any((source) => source.id == id),
        );
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
        title: const Text('删除源'),
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
    try {
      final result = await SourceMaintenance(
        section: widget.section,
        manager: _manager,
      ).remove([source]);
      await _reload();
      if (mounted && result.errors.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.errors.join('；'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除未完成：$error')));
      }
    }
  }

  /// 猫源引擎设置：**只有 Android 的猫源板块显示这个入口**（任务书第 4 条），
  /// 其他系统与其他板块隐藏。
  Future<void> _manageEngine() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CatEngineSettingsPage()),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已重命名为：${name.trim()}')));
  }

  /// 设置分组：只改展示归类，不改变归属板块。
  ///
  /// 分组名由用户自定（没有预设分组）：文档里举的例子是「视频组 / 漫画组 /
  /// 小说组」，但本 App 的板块已经是物理隔离的一层，再拿板块名当分组没意义
  /// ——分组的用处是**同一板块内**按用户自己的习惯归类（如「主力 / 备用」）。
  Future<void> _setGroup(SourceDescriptor source) async {
    final group = await showDialog<String>(
      context: context,
      builder: (_) =>
          _GroupDialog(initialGroup: source.group, knownGroups: _knownGroups()),
    );
    if (group == null || !mounted) return;
    await _manager.setGroup(source.id, group);
    await _reload();
    if (!mounted) return;
    final trimmed = group.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trimmed.isEmpty ? '已取消「${source.name}」的分组' : '已归入分组：$trimmed',
        ),
      ),
    );
  }

  /// 本板块已有的分组名（给对话框做快捷选项）。
  List<String> _knownGroups() {
    final groups = <String>{};
    for (final source in _sources ?? const <SourceDescriptor>[]) {
      final group = source.group.trim();
      if (group.isNotEmpty) groups.add(group);
    }
    final list = groups.toList()..sort();
    return list;
  }

  /// 恢复被标记失效的源：清零失败计数并解除标记。
  Future<void> _recover(SourceDescriptor source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复源'),
        content: Text(
          '「${source.name}」已被标记为失效（连续失败 ${source.failureCount} 次），'
          '因此不再参与自动重试。\n'
          '恢复会清零失败计数，让它重新进入批量测试 / 批量刷新的范围。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _manager.clearFailure(source.id);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已恢复「${source.name}」')));
  }

  /// 打开可视化编辑器：表单生成脚本 → 导入（走与「+」相同的校验路径）。
  Future<void> _openEditor() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            SourceEditorPage(section: widget.section, manager: widget.manager),
      ),
    );
    if (imported == true && mounted) await _reload();
  }

  /// 空态里的「导入源」：与右上角「+」同一个弹窗、同一套导入编排。
  Future<void> _import() async {
    final imported = await runSourceImport(
      context,
      section: widget.section,
      manager: _manager,
      readLocalScripts: widget.readLocalScripts,
      fetchSubscription: widget.fetchSubscription,
    );
    if (imported && mounted) await _reload();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有已启用的源可测试')));
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

  /// 源设置：单图源的网络覆盖（UA / Cookie / 代理）、换网址（镜像 / 自定义域名）
  /// 与账号登入。网络覆盖留空即继承全局设置。
  ///
  /// 保存后丢弃该图源已建好的 HTTP 客户端与运行时——下次请求用新配置，
  /// 不会出现「改了配置还在用旧 Cookie」的错觉。换网址 / 账号登入只落库：
  /// 它在**每次调用前**注入脚本（`LumeSource.config`），因此下一次浏览就用新值。
  Future<void> _editNetwork(SourceDescriptor source) async {
    final result = await showDialog<SourceSettingsResult>(
      context: context,
      builder: (_) => SourceNetworkDialog(source: source),
    );
    if (result == null || !mounted) return;
    final profile = result.network;
    await _manager.setNetwork(
      source.id,
      userAgent: profile.userAgent,
      cookie: profile.cookie,
      proxy: profile.proxy,
      bridge: profile.bridge,
      allowBadCertificate: profile.allowBadCertificate,
    );
    await _manager.setSiteConfig(source.id, result.site);
    // 运行时重建：旧客户端带着旧 UA / Cookie，必须释放。
    await _manager.setEnabled(source.id, source.enabled);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.site.hasCustomDomain || result.site.safeMirrorIndex > 0
              ? '已保存「${source.name}」的源设置（换网址已生效）'
              : profile.isEmpty
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('读不到该源的脚本')));
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
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
              ),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已复制「${source.name}」的脚本全文')));
    }
  }

  Future<bool> _confirmMaintenance(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认移除'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _removeSources(
    List<SourceDescriptor> targets, {
    bool clearData = false,
  }) async {
    if (_maintaining || _testing.isNotEmpty) return;
    if (targets.isEmpty && !clearData) return;
    final title = clearData ? '移除所有站点数据' : '移除已安装站点';
    final detail = clearData
        ? '仅清理「${widget.section.label}」版块：已安装源、保存的订阅、站点 Cookie／验证会话、源设置和浏览缓存。书架、阅读／播放进度与已保存的图片保留。其他版块仍在使用的共享网页会话保留。此操作无法撤销。'
        : '将移除「${widget.section.label}」中选定的 ${targets.length} 个站点及运行时。书架、进度和站点设置保留；自动订阅不会重新装回已移除站点。重新添加对应订阅可恢复安装。';
    if (!await _confirmMaintenance(title, detail) || !mounted) return;
    setState(() {
      _maintaining = true;
      _maintenanceStatus = '正在处理…';
    });
    try {
      final result = await SourceMaintenance(
        section: widget.section,
        manager: _manager,
      ).remove(targets, clearData: clearData);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedIds.clear();
        _selecting = false;
        _maintenanceStatus =
            '已移除 ${result.removed.length} 个站点${result.errors.isEmpty ? '' : '，${result.errors.length} 项失败：${result.errors.join('；')}'}';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_maintenanceStatus!)));
    } catch (error) {
      if (mounted) setState(() => _maintenanceStatus = '操作未完成：$error');
    } finally {
      if (mounted) setState(() => _maintaining = false);
    }
  }

  Future<void> _bulkEnabled(bool value) async {
    if (_maintaining || _selectedIds.isEmpty) return;
    setState(() => _maintaining = true);
    var count = 0;
    final errors = <String>[];
    for (final id in _selectedIds.toList()) {
      try {
        await _manager.setEnabled(id, value);
        count++;
      } catch (error) {
        errors.add('$id：$error');
      }
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    setState(() {
      _maintaining = false;
      _maintenanceStatus =
          '已${value ? '启用' : '停用'} $count 个站点${errors.isEmpty ? '' : '，失败 ${errors.length} 项'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_manager.runtimeAvailable) {
      // 平台骨架：标题仍按「板块 · 源管理」口径，页面身份不含糊。
      return GlassScaffold(
        effectModule: GlassModule.sources,
        behindBar: true,
        title: '${widget.section.label} · 源管理',
        child: const SkeletonNotice(),
      );
    }
    final sources = _sources;
    return GlassScaffold(
      effectModule: GlassModule.sources,
      // 内容从玻璃顶栏底下穿过，顶部空间由列表的 barInset 让——见 settings_page
      // 的同名注释：漏了这一句，SafeArea 与 barInset 会各让一次栏高。
      behindBar: true,
      title: '${widget.section.label} · 源管理',
      actions:
          <Widget>[
                PopupMenuButton<String>(
                  tooltip: '站点维护',
                  enabled: !_maintaining && _testing.isEmpty,
                  onSelected: (action) {
                    if (action == 'select') {
                      setState(() {
                        _selecting = !_selecting;
                        _selectedIds.clear();
                      });
                    } else {
                      _removeSources(
                        List.of(_sources ?? []),
                        clearData: action == 'clear',
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'select',
                      child: Text(_selecting ? '退出多选' : '多选站点'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      enabled: (_sources ?? []).isNotEmpty,
                      child: const Text('移除已安装站点'),
                    ),
                    const PopupMenuItem(
                      value: 'clear',
                      child: Text('移除所有站点数据'),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: '可视化编辑器',
                  icon: const Icon(Icons.edit_note),
                  onPressed: _openEditor,
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
                // 右上角统一的「+」添加源：本地文件 / 订阅链接 / 剪贴板，只写本板块。
                AddSourceButton(
                  section: widget.section,
                  manager: _manager,
                  onImported: _reload,
                  readLocalScripts: widget.readLocalScripts,
                  fetchSubscription: widget.fetchSubscription,
                ),
              ]
              .map(
                (action) =>
                    IgnorePointer(ignoring: _maintaining, child: action),
              )
              .toList(),
      child: sources == null
          ? (_failed
                ? const NoticeCard(title: '源存储不可用', subtitle: LumeTheme.appName)
                : const SourceStateView(state: SourceStateKind.loading))
          : AbsorbPointer(
              absorbing: _maintaining,
              child: _buildSources(sources),
            ),
    );
  }

  Widget _buildSources(List<SourceDescriptor> sources) {
    if (sources.isEmpty) {
      // 空态直接给按钮：新用户第一步的动作应该能点，而不是先去解读「右上角的 +」。
      return ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: [
          NoticeCard(
            title: '暂无源',
            subtitle: '导入后即可在本板块浏览内容',
            action: FilledButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('导入源'),
            ),
          ),
        ],
      );
    }
    final query = _sourceQuery.toLowerCase().trim();
    final visible =
        sources
            .where(
              (source) =>
                  PrivacySettings.instance.allowsSource(
                    source.id,
                    source.name,
                  ) &&
                  (query.isEmpty ||
                      '${source.name} ${source.id} ${source.group}'
                          .toLowerCase()
                          .contains(query)) &&
                  (_group == null || source.group == _group) &&
                  (_sourceFilter == 0 ||
                      (_sourceFilter == 1 ? source.enabled : source.broken)),
            )
            .toList()
          ..sort((a, b) {
            final pinA = SourcePreferences.read(widget.section, a.id).pinned;
            final pinB = SourcePreferences.read(widget.section, b.id).pinned;
            if (pinA != pinB) return pinA ? -1 : 1;
            return SourceOrder.compare(
              widget.section,
              a.id,
              b.id,
              sources.map((s) => s.id).toList(),
            );
          });
    Future<void> move(String from, String to) async {
      final all = List<SourceDescriptor>.of(sources)
        ..sort(
          (a, b) => SourceOrder.compare(
            widget.section,
            a.id,
            b.id,
            sources.map((s) => s.id).toList(),
          ),
        );
      await SourceOrder.move(
        widget.section,
        all.map((s) => s.id).toList(),
        visible.map((s) => s.id).toList(),
        visible.indexWhere((s) => s.id == from),
        visible.indexWhere((s) => s.id == to),
      );
      if (mounted) setState(() {});
    }

    Widget entry(BuildContext context, int index) {
      if (index == 0) {
        return Column(
          key: const ValueKey('source-manager-header'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              onChanged: (value) => setState(() => _sourceQuery = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索源名称、ID 或分组',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in [(0, '全部'), (1, '已启用'), (2, '异常')])
                  ChoiceChip(
                    label: Text(
                      label,
                      style: TextStyle(
                        color: _sourceFilter == value
                            ? Colors.white
                            : LumeTheme.chipIdleForeground,
                      ),
                    ),
                    labelStyle: LumeTheme.chipLabelStyle,
                    backgroundColor: LumeTheme.chipIdleBackground,
                    selectedColor: LumeTheme.chipSelectedBackground,
                    checkmarkColor: Colors.white,
                    selected: _sourceFilter == value,
                    onSelected: (_) => setState(() => _sourceFilter = value),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _group ?? '__all__',
                    items: [
                      const DropdownMenuItem(
                        value: '__all__',
                        child: Text('总分组（全部）'),
                      ),
                      for (final group
                          in sources.map((source) => source.group).toSet())
                        DropdownMenuItem(
                          value: group,
                          child: Text(group.isEmpty ? '未分组' : group),
                        ),
                    ],
                    onChanged: (value) => setState(
                      () => _group = value == '__all__' ? null : value,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _compact ? '详细排列' : '紧凑排列',
                  icon: Icon(
                    _compact
                        ? Icons.view_agenda_outlined
                        : Icons.view_list_outlined,
                  ),
                  onPressed: () async {
                    final library = await ReadingLibrary.open(widget.section);
                    library.setSetting(
                      'source.manager.compact',
                      '${!_compact}',
                    );
                    if (mounted) setState(() => _compact = !_compact);
                  },
                ),
              ],
            ),
            Text('${visible.length} 个源 · 长按源条目拖动排序'),
            if (_maintenanceStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_maintenanceStatus!),
              ),
            if (_selecting) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: () => setState(
                      () => _selectedIds.addAll(
                        visible.map((source) => source.id),
                      ),
                    ),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setState(_selectedIds.clear),
                    child: const Text('清空选择'),
                  ),
                  Text('已选 ${_selectedIds.length} 个'),
                  TextButton(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => _bulkEnabled(true),
                    child: const Text('批量启用'),
                  ),
                  TextButton(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => _bulkEnabled(false),
                    child: const Text('批量停用'),
                  ),
                  TextButton(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => _removeSources(
                            sources
                                .where(
                                  (source) => _selectedIds.contains(source.id),
                                )
                                .toList(),
                          ),
                    child: const Text('删除所选'),
                  ),
                ],
              ),
            ],
            if (visible.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text('没有匹配的源')),
          ],
        );
      }
      final source = visible[index - 1];
      return SourceDragTile(
        key: ValueKey('source-manager-${source.id}'),
        id: source.id,
        name: source.name,
        accepts: (id) => visible.any((s) => s.id == id),
        onMove: move,
        child: Row(
          children: [
            if (_selecting)
              Checkbox(
                key: ValueKey('select-source-${source.id}'),
                value: _selectedIds.contains(source.id),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _selectedIds.add(source.id);
                  } else {
                    _selectedIds.remove(source.id);
                  }
                }),
              ),
            Expanded(
              child: _compact
                  ? ListTile(
                      title: Text(
                        source.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (SourceContentRating.isAdult(
                            source.id,
                            source.name,
                          ))
                            const SourceRatingBadge(),
                          SourceUpdateBadge(
                            section: widget.section,
                            sourceId: source.id,
                          ),
                          Text(source.hasGroup ? source.group : '未分组'),
                        ],
                      ),
                      leading: SourceIcon(
                        name: source.name,
                        siteUrl: source.siteUrl,
                        iconUrl:
                            SourcePreferences.read(
                              widget.section,
                              source.id,
                            ).iconUrl.trim().isEmpty
                            ? source.iconUrl
                            : SourcePreferences.read(
                                widget.section,
                                source.id,
                              ).iconUrl,
                        section: widget.section,
                        sourceId: source.id,
                      ),
                      trailing: Switch(
                        value: source.enabled,
                        onChanged: (value) => _toggle(source, value),
                      ),
                      onTap: () => _rename(source),
                    )
                  : _SourceTile(
                      source: source,
                      section: widget.section,
                      pinned: SourcePreferences.read(
                        widget.section,
                        source.id,
                      ).pinned,
                      customIcon: SourcePreferences.read(
                        widget.section,
                        source.id,
                      ).iconUrl,
                      testing: _testing.contains(source.id),
                      testResult: _testResults[source.id],
                      onToggle: (enabled) => _toggle(source, enabled),
                      onRename: () => _rename(source),
                      onGroup: () => _setGroup(source),
                      onRecover: source.broken ? () => _recover(source) : null,
                      onNetwork: () => _editNetwork(source),
                      onExport: () => _export(source),
                      onDelete: () => _delete(source),
                    ),
            ),
          ],
        ),
      );
    }

    final inset = GlassScaffold.barInset(context)
        .add(
          EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + ShellDockScope.bottomInset(context),
          ),
        )
        .resolve(Directionality.of(context));
    final grouped = <String, List<int>>{};
    for (var i = 0; i < visible.length; i++) {
      final source = visible[i];
      final label = source.group.trim().isNotEmpty
          ? source.group.trim()
          : SourcePickerGroups.forSection(widget.section)
                .firstWhere(
                  (group) =>
                      group.$1 ==
                      SourcePickerGroups.groupFor(widget.section, source),
                )
                .$2;
      grouped.putIfAbsent(label, () => []).add(i);
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: inset.copyWith(bottom: 12),
          sliver: SliverToBoxAdapter(child: entry(context, 0)),
        ),
        for (final group in grouped.entries) ...[
          SliverToBoxAdapter(
            child: Semantics(
              header: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Text(
                  group.key,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + ShellDockScope.bottomInset(context),
            ),
            sliver: SliverList.separated(
              itemCount: group.value.length,
              itemBuilder: (context, i) => entry(context, group.value[i] + 1),
              separatorBuilder: (_, _) => const SizedBox(height: 12),
            ),
          ),
        ],
      ],
    );
  }
}

/// 停用标记的颜色：与错误文案同色系，避免新造主题项。
Color get _disabledColor => LumeTheme.danger;

/// 「网络已自定义」标记色：与停用区分开的提示色。
Color get _accentColor => LumeTheme.info;

/// 测试通过的标记色。
Color get _okColor => LumeTheme.success;

/// 单个图源行上的操作。
enum _SourceAction { rename, group, recover, network, exportScript, delete }

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.section,
    this.pinned = false,
    this.customIcon = '',
    this.testing = false,
    this.testResult,
    required this.onToggle,
    required this.onRename,
    required this.onGroup,
    required this.onNetwork,
    required this.onExport,
    required this.onDelete,
    this.onRecover,
  });

  final SourceDescriptor source;

  /// 这个源属于哪个板块（取图标时要用该源的会话，见 [SourceIcon.section]）。
  final Section section;

  final bool pinned;
  final String customIcon;

  /// 正在测试（按钮转圈）。
  final bool testing;

  /// 最近一次测试结论；未测试过为 null。
  final SourceTestResult? testResult;

  final ValueChanged<bool> onToggle;

  final VoidCallback onRename;

  /// 设置分组。
  final VoidCallback onGroup;

  /// 恢复被标记失效的源；未失效时为 null（菜单项不出现）。
  final VoidCallback? onRecover;

  final VoidCallback onNetwork;

  final VoidCallback onExport;

  final VoidCallback onDelete;

  Widget _menu() => PopupMenuButton<_SourceAction>(
    tooltip: '更多操作',
    onSelected: (action) {
      switch (action) {
        case _SourceAction.rename:
          onRename();
        case _SourceAction.group:
          onGroup();
        case _SourceAction.recover:
          onRecover?.call();
        case _SourceAction.network:
          onNetwork();
        case _SourceAction.exportScript:
          onExport();
        case _SourceAction.delete:
          onDelete();
      }
    },
    itemBuilder: (context) => <PopupMenuEntry<_SourceAction>>[
      const PopupMenuItem<_SourceAction>(
        value: _SourceAction.rename,
        child: Text('重命名'),
      ),
      const PopupMenuItem<_SourceAction>(
        value: _SourceAction.group,
        child: Text('设置分组'),
      ),
      // 只有失效的源才有「恢复」——正常的源没有可恢复的状态。
      if (onRecover != null)
        const PopupMenuItem<_SourceAction>(
          value: _SourceAction.recover,
          child: Text('恢复（解除失效标记）'),
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
  );

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          SourceIcon(
            name: source.name,
            siteUrl: source.siteUrl,
            iconUrl: customIcon.isEmpty ? source.iconUrl : customIcon,
            // 带上板块与源标识：Cloudflare 站要用该源验证过的会话才给图标。
            section: section,
            sourceId: source.id,
          ),
          const SizedBox(width: 12),
          if (pinned)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.push_pin, size: 14, color: LumeTheme.accent),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  source.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: LumeTypography.sectionTitleSize,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                // 元信息行用 Wrap 而不是 Row：这里有版本号 + 「已停用 / 已失效 /
                // 分组 / 订阅 / 网络已自定义 / 测试结论」最多六个标记，窄屏
                // （320pt）下并排必然溢出（实测 121px，画面上是黄黑条纹）。
                // Wrap 让标记自动折到下一行——信息一个不少，只是多占一行。
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    SourceUpdateBadge(section: section, sourceId: source.id),
                    Text(
                      source.version.isEmpty
                          ? LumeTheme.appName
                          : source.version,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: LumeTypography.descriptionSize,
                        color: LumeTheme.descriptionColor,
                      ),
                    ),
                    if (SourceContentRating.isAdult(source.id, source.name))
                      const SourceRatingBadge(),
                    if (!source.enabled) ...<Widget>[
                      Text(
                        '已停用',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _disabledColor,
                        ),
                      ),
                    ],
                    if (source.broken) ...<Widget>[
                      Text(
                        '已失效（连错 ${source.failureCount} 次）',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _disabledColor,
                        ),
                      ),
                    ],
                    if (source.hasGroup) ...<Widget>[
                      Text(
                        source.group,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _accentColor,
                        ),
                      ),
                    ],
                    if (source.subscribed) ...<Widget>[
                      Text(
                        '订阅',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _accentColor,
                        ),
                      ),
                    ],
                    if (source.hasNetworkOverride) ...<Widget>[
                      Text(
                        '网络已自定义',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _accentColor,
                        ),
                      ),
                    ],
                    // 换过网址（选了非主站镜像 / 填了自定义域名）：列表上标一句，
                    // 否则「列表为空」时用户不会想到自己去过另一个域名。
                    if (source.hasMirrorOverride) ...<Widget>[
                      Text(
                        '换网址',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                          color: _accentColor,
                        ),
                      ),
                    ],
                    if (testResult != null) ...<Widget>[
                      Text(
                        testResult!.status.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
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
          Wrap(
            direction: MediaQuery.sizeOf(context).width < 380
                ? Axis.vertical
                : Axis.horizontal,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Switch(value: source.enabled, onChanged: onToggle),
              // 行内只留开关：浏览 / 重命名 / 导出 / 删除收进「更多」，
              // 手机窄屏也不会把四个按钮挤成一片。
              _menu(),
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
/// 重命名弹窗：自己持有输入控制器（页面不跨弹窗生命周期持有它）。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名源'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '源名称',
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

/// 分组设置弹窗：输入分组名，或用本板块已有的分组名快捷选择。
///
/// 留空即取消分组——因此「取消分组」不需要单独的按钮，清空保存即可。
/// 分组只是**展示归类**，不改变归属板块：跨板块依旧完全隔离。
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.initialGroup, required this.knownGroups});

  final String initialGroup;

  /// 本板块已有的分组名（快捷选项）。
  final List<String> knownGroups;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialGroup,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置分组'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '分组只影响本板块列表里的归类显示，不改变源的归属板块。'
            '留空保存即取消分组。',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '分组名',
              hintText: '例如：主力 / 备用',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          if (widget.knownGroups.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '已有分组',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final group in widget.knownGroups)
                  ActionChip(
                    label: Text(group),
                    onPressed: () => setState(() => _controller.text = group),
                  ),
              ],
            ),
          ],
        ],
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

/// 单图源网络配置弹窗：UA / Cookie / 代理 / 桥接服务地址，留空即继承全局设置。
///
/// 这三项对应文档要求：图源可自定义 UA / Cookie / 代理，且单图源配置优先于
/// 全局设置；Cookie 按图源隔离，不与其他图源共享。
