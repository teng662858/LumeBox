import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/net/source_subscription.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'browse_page.dart';
import 'source_import_dialog.dart';
import 'source_import_flow.dart';

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
  const GlobalSourcePage({
    super.key,
    this.managerFactory,
    this.readLocalScripts,
    this.fetchSubscription,
  });

  /// 板块级管理端口工厂：一个板块一个实例。为空时使用 `LumeSources.manager`。
  final SourceManager Function(Section section)? managerFactory;

  /// 本地文件读取端口（测试注入）；为空时弹系统文件选择器（可多选）。
  final Future<List<({String name, String text})>> Function()? readLocalScripts;

  /// 订阅拉取端口（测试注入）；为空时经宿主网络层拉取。
  final Future<SourceFetchResult> Function(String url)? fetchSubscription;

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

  /// 备份 / 恢复服务（与测试同口径：可注入运行时判定）。
  final SourceBackupService _backupService = SourceBackupService();

  /// 正在测试的图源 id（按钮转圈用）。
  final Set<String> _testing = <String>{};

  /// 正在刷新订阅的图源 id（按钮转圈用）。
  final Set<String> _refreshing = <String>{};

  /// 测试结论：sourceId → 结果（只存内存，退出即丢）。
  final Map<String, SourceTestResult> _testResults = <String, SourceTestResult>{};

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

  /// 导入：先选目标板块，再走「本地文件 / 订阅链接 / 剪贴板」三条通道之一；
  /// 只写所选板块的库（与板块页共用同一个弹窗与同一套覆盖确认）。
  Future<void> _import({Section? target}) async {
    final request = await showDialog<SourceImportRequest>(
      context: context,
      builder: (_) => SourceImportDialog(
        sections: Section.values,
        initialSection: target ?? _filter ?? Section.novel,
        readLocalScripts: widget.readLocalScripts,
        fetchSubscription: widget.fetchSubscription,
      ),
    );
    if (request == null || !mounted) return;

    final section = request.section;
    final imported = await importSources(
      context,
      manager: _managers[section]!,
      items: request.items,
      skipped: request.skipped,
      notes: request.notes,
      sectionLabel: section.label,
    );
    if (!mounted) return;
    if (imported) await _reloadSection(section);
  }

  /// 导出备份：四个板块的全部图源（只含脚本与配置，不含 Cookie / 缓存）。
  Future<void> _exportBackup() async {
    final backup = await _backupService.export();
    if (!mounted) return;

    if (backup.totalCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('四个板块都没有源可备份')),
      );
      return;
    }

    final text = backup.encode();
    var copied = false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('备份源（${backup.totalCount} 个）'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '备份只含源脚本与配置，不含 Cookie、缓存与阅读记录。',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  text,
                  style: const TextStyle(fontSize: 11),
                  maxLines: 20,
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              copied = true;
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('复制备份'),
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
        SnackBar(content: Text('已复制 ${backup.totalCount} 个源的备份')),
      );
    }
  }

  /// 从剪贴板 / 粘贴的备份文本恢复图源。
  Future<void> _restoreBackup() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _RestoreDialog(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;

    final SourceBackup backup;
    try {
      backup = SourceBackup.decode(text);
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份无法识别：${error.message}')),
      );
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复源'),
        content: Text(
          '将恢复 ${backup.totalCount} 个源（备份时间 '
          '${_formatTime(backup.createdAt)}）。\n'
          '同 id 的源会被备份里的内容覆盖（脚本、启停状态与网络配置）。',
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

    final result = await _backupService.restore(backup);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.describe())),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 批量测试全部板块的图源（文档第 4 条：图源总管理支持批量测试）。
  ///
  /// 逐板块、逐图源串行：网络层已有并发限制，但测试会真实打目标站，串行更稳、
  /// 进度也可读。停用的跳过（测试会如实报「已停用」，没意义）。
  Future<void> _testAll() async {
    var ok = 0;
    var empty = 0;
    var failed = 0;
    var tested = 0;
    for (final section in Section.values) {
      for (final source in _listOf(section)) {
        if (!source.enabled) continue;
        if (!mounted) return;
        setState(() => _testing.add(source.id));
        try {
          final result = await _managers[section]!.testConnectivity(source.id);
          if (!mounted) return;
          setState(() => _testResults[source.id] = result);
          tested++;
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
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tested == 0
              ? '没有已启用的源可测试'
              : '测试完成（$tested 个）：可用 $ok'
                  '${empty > 0 ? ' · 无内容 $empty' : ''}'
                  '${failed > 0 ? ' · 不可用 $failed' : ''}',
        ),
      ),
    );
  }

  /// 批量刷新全部订阅源（文档第 4 条：图源总管理支持批量刷新全部订阅源）。
  ///
  /// 只处理**有订阅地址**的源（本地导入的没有可刷新的来源，跳过并计数）。
  /// 逐板块、逐源串行：刷新会真实打订阅地址，串行更稳、进度也可读，也不会
  /// 因为并发拉取把订阅站打爆（与「批量测试」同一取舍）。
  ///
  /// 刷新前先问一句：这会把订阅端的新脚本覆盖到本地（脚本、名称、版本），
  /// 用户的网络配置与启停状态保留——但仍是会改动多份源的操作，先确认再动手。
  Future<void> _refreshSubscriptions() async {
    final targets = <({Section section, SourceDescriptor source})>[];
    for (final section in Section.values) {
      for (final source in _listOf(section)) {
        if (!source.subscribed) continue;
        targets.add((section: section, source: source));
      }
    }

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('四个板块都没有订阅源可刷新')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('刷新 ${targets.length} 个订阅源？'),
        content: const Text(
          '会从各自的订阅地址重新拉取脚本：有新版本就覆盖本地（脚本、名称、版本），'
          '启停状态与网络配置（UA / Cookie / 代理）保留。\n'
          '本地导入的源没有订阅地址，不在本次范围内。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('刷新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    var updated = 0;
    var unchanged = 0;
    var failed = 0;
    final failures = <String>[];
    final touchedSections = <Section>{};

    for (final target in targets) {
      if (!mounted) return;
      setState(() => _refreshing.add(target.source.id));
      try {
        final result = await _managers[target.section]!
            .updateFromSubscription(target.source.id);
        touchedSections.add(target.section);
        switch (result.status) {
          case SourceUpdateStatus.updated:
            updated++;
          case SourceUpdateStatus.unchanged:
            unchanged++;
          case SourceUpdateStatus.skipped:
          case SourceUpdateStatus.failed:
            failed++;
            failures.add('${target.source.name}：${result.message}');
        }
      } catch (error, stackTrace) {
        // 单条异常不中断整批（与导入同口径：失败也要给出结论）。
        LumeLog.error(error, stackTrace);
        failed++;
        failures.add('${target.source.name}：$error');
      } finally {
        if (mounted) setState(() => _refreshing.remove(target.source.id));
      }
    }

    // 刷新过的板块重读列表（版本号会变）。
    for (final section in touchedSections) {
      await _reloadSection(section);
    }
    if (!mounted) return;

    final summary = '刷新完成（${targets.length} 个）：更新 $updated'
        '${unchanged > 0 ? ' · 已是最新 $unchanged' : ''}'
        '${failed > 0 ? ' · 失败 $failed' : ''}';
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
      return;
    }
    // 有失败就给模态弹窗：失败原因是排障要看的信息，SnackBar 几秒就没了。
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('订阅刷新结果'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(summary, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 10),
                for (final failure in failures)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      failure,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
        title: const Text('删除源'),
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
        const SnackBar(content: Text('源不可用')),
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
      behindBar: true,
      title: '源总管理',
      actions: <Widget>[
        if (_runtimeAvailable && !_loading)
          IconButton(
            tooltip: '恢复源',
            icon: const Icon(Icons.settings_backup_restore),
            onPressed: _restoreBackup,
          ),
        if (_runtimeAvailable && !_loading && _totalCount > 0) ...<Widget>[
          IconButton(
            tooltip: '备份源',
            icon: const Icon(Icons.save_alt),
            onPressed: _exportBackup,
          ),
          IconButton(
            tooltip: '批量刷新订阅源',
            icon: const Icon(Icons.sync),
            onPressed: _testing.isEmpty && _refreshing.isEmpty
                ? _refreshSubscriptions
                : null,
          ),
          IconButton(
            tooltip: '批量测试连通性',
            icon: const Icon(Icons.network_check),
            onPressed: _testing.isEmpty && _refreshing.isEmpty ? _testAll : null,
          ),
        ],
      ],
      floatingActionButton: _runtimeAvailable && !_loading
          ? FloatingActionButton(
              tooltip: '导入源',
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
        title: '四板块均无源',
        subtitle: '源由用户导入：点右下角按钮，并选择导入的目标板块',
        action: FilledButton(
          onPressed: () => _import(),
          child: const Text('导入源'),
        ),
      );
    }

    final visible =
        _filter == null ? Section.values : <Section>[_filter!];
    return Column(
      children: <Widget>[
        // 筛选条不是滚动视图，自己让出玻璃顶栏的高度。
        SizedBox(height: GlassScaffold.barHeight(context)),
        _buildFilterBar(),
        Expanded(
          child: ListView(
            // 尾部只留「页面节奏（24）+ 右下角 FAB 的净空（56）」：二级页底下没有
            // Dock，96 那套会多出一截空白（用户口径：二级页底部不要多余留白）。
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
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
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            Text(
              '启用 ${_enabledCount(section)} / 共 ${sources.length}',
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
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
        const _SectionNote('该板块源存储不可用')
      else if (sources.isEmpty)
        const _SectionNote('暂无源'),
      for (final source in sources)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SourceTile(
            source: source,
            testing: _testing.contains(source.id) || _refreshing.contains(source.id),
            testResult: _testResults[source.id],
            onToggle: (enabled) => _toggle(section, source, enabled),
            onBrowse: source.enabled ? () => _browse(section, source) : null,
            onDelete: () => _delete(section, source),
          ),
        ),
    ];
  }
}

/// 停用标记的颜色：与板块管理页同色系，避免新造主题项。
Color get _disabledColor => LumeTheme.danger;

/// 分组 / 「网络已自定义」标记色：与板块管理页同色系（提示色而非告警色）。
Color get _accentColor => LumeTheme.info;

/// 分组内的一行说明（空板块 / 存储故障）。
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Text(
          text,
          style: TextStyle(fontSize: 13, color: LumeTheme.muted),
        ),
      );
}

/// 图源条目：名称版本 + 启停 / 浏览 / 删除。
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    this.testing = false,
    this.testResult,
    required this.onToggle,
    required this.onBrowse,
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                // 与板块管理页同一处理：版本号 + 状态标记用 Wrap，窄屏自动折行
                // （并排实测溢出 6px）。Wrap.spacing 已给间距，无需再插 SizedBox。
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      source.version.isEmpty
                          ? LumeTheme.appName
                          : source.version,
                      style: TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                    if (!source.enabled)
                      Text(
                        '已停用',
                        style: TextStyle(fontSize: 12, color: _disabledColor),
                      ),
                    if (source.broken)
                      Text(
                        '已失效（连错 ${source.failureCount} 次）',
                        style: TextStyle(fontSize: 12, color: _disabledColor),
                      ),
                    if (source.hasGroup)
                      Text(
                        source.group,
                        style: TextStyle(fontSize: 12, color: _accentColor),
                      ),
                    if (testResult != null)
                      Text(
                        testResult!.status.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: testResult!.isOk
                              ? LumeTheme.success
                              : _disabledColor,
                        ),
                      ),
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

/// 恢复图源的输入弹窗：粘贴备份文本（或从剪贴板读）。
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted || text.isEmpty) return;
    _controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('恢复源'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '粘贴之前导出的备份内容。同 id 的源会被覆盖。',
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '粘贴备份 JSON',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _paste,
          child: const Text('从剪贴板读取'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('下一步'),
        ),
      ],
    );
  }
}
