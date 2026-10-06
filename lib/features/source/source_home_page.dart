import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'browse_page.dart';
import 'source_section_page.dart';

/// 板块业务页：把板块内的图源接到统一数据源接口上。
///
/// 本页只做数据粘合：向 [SourceManager] 要「本板块当前图源」，经它打开一个
/// [DataSource]（正式实现是 `JsDataSource`），再把分类、列表、搜索交给浏览面。
/// 阅读渲染不在本轮范围内——章节点击仍只提示。
///
/// 隔离：管理器按板块构造，图源列表与切换目标都只来自本板块；数据源打开后
/// 还会再校验一次 [DataSource.section]，不符即拒绝渲染（禁止跨板块调用）。
///
/// 管理入口在**图源条**里（与阅读板块的图源条同一口径），点它进图源管理页，
/// 返回后自动重新解析当前图源。
///
/// 平台边界：没有图源运行时的平台（Android / Windows）按宪法只显示骨架。
class SourceHomePage extends StatelessWidget {
  const SourceHomePage({
    super.key,
    required this.section,
    this.manager,
    this.onItemTap,
  });

  final Section section;

  /// 图源管理端口。为空时使用 [LumeSources.manager] 的正式实现。
  final SourceManager? manager;

  /// 条目点击。为空时浏览面按通用口径进详情页。
  final void Function(DataSource source, SourceItem item)? onItemTap;

  @override
  Widget build(BuildContext context) => GlassScaffold(
        title: section.label,
        child: SourceBrowsePane(
          section: section,
          manager: manager,
          onItemTap: onItemTap,
        ),
      );
}

/// 板块图源浏览面板：解析当前图源 → 图源条（可切换）+ 浏览面（分类 / 搜索 / 列表）。
///
/// 面板不带页面骨架（AppBar 与右上角入口由宿主给）：视频板块把它当首页的
/// 「浏览」页签，[SourceHomePage] 把它当整页内容。图源条右侧的「图源管理」
/// 快捷入口可由宿主关掉（[showSourceActions] 为 false），避免与页面右上角的
/// 同名入口重复。
///
/// 生命周期：面板使用（必要时创建）本板块的管理器端口，退出时释放——与
/// 板块页「进板块打开、退出板块释放」的口径一致。
class SourceBrowsePane extends StatefulWidget {
  const SourceBrowsePane({
    super.key,
    required this.section,
    this.manager,
    this.onItemTap,
    this.pipeline,
    this.showSourceActions = true,
    this.revision = 0,
  });

  final Section section;

  /// 图源管理端口。为空时使用 [LumeSources.manager] 的正式实现。
  final SourceManager? manager;

  /// 条目点击（同时给出该条目所属的数据源）。为空时浏览面按通用口径进详情页。
  final void Function(DataSource source, SourceItem item)? onItemTap;

  /// 封面图管线（可选）：转发给浏览面，条目带封面时列表行左侧显示缩略图。
  /// 为空时列表保持纯文字排布（图源管理里的浏览入口走这条）。
  final SectionImagePipeline? pipeline;

  /// 刷新代数：宿主（板块页）在导入 / 删除图源后 +1，面板据此**原地重解析**
  /// 当前图源与列表。
  ///
  /// 为什么不是换 Key 重挂：重挂会让新旧两个面板实例短暂共存，新实例先取到
  /// 板块共享的图源注册表、旧实例随后 `dispose` 把它整个拆掉（引擎 + 数据库），
  /// 新实例随后的读取就撞上「数据库已关闭」——页面上表现为导入成功后反而
  /// 报「图源存储不可用」。原地重解析走同一个实例，不存在这个竞态。
  final int revision;

  /// 图源条右侧是否显示「图源管理」快捷入口。
  final bool showSourceActions;

  @override
  State<SourceBrowsePane> createState() => _SourceBrowsePaneState();
}

class _SourceBrowsePaneState extends State<SourceBrowsePane> {
  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  List<SourceDescriptor> _sources = const <SourceDescriptor>[];
  SourceDescriptor? _current;
  DataSource? _source;

  /// 面板状态：五状态统一由 [SourceStateKind] 表达。
  SourceStateKind _state = SourceStateKind.loading;

  /// 状态标题覆盖（同一状态在不同页面说法不同时使用）。
  String? _title;

  /// 状态说明，通常是数据层给出的原始原因。
  String? _detail;

  /// 基础设施故障（例如板块库打不开），不属于五状态。
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (_manager.runtimeAvailable) _resolve();
  }

  @override
  void didUpdateWidget(SourceBrowsePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 图源变更（导入 / 删除）：原地重解析，不换实例（见 [revision] 的说明）。
    if (oldWidget.revision != widget.revision) _resolve();
  }

  @override
  void dispose() {
    _manager.close();
    super.dispose();
  }

  /// 解析当前图源并打开数据源。
  ///
  /// 当前图源被停用或删除后，管理器会自动回退到板块内下一个启用图源，
  /// 所以这里不需要额外的修复逻辑，重跑一次即可。
  Future<void> _resolve() async {
    setState(() {
      _state = SourceStateKind.loading;
      _title = null;
      _detail = null;
    });
    try {
      final sources = await _manager.list();

      // 空数据：板块内一个图源都没有。
      if (sources.isEmpty) {
        _settle(
          state: SourceStateKind.empty,
          title: '暂无源',
          detail: '进入源管理导入并启用源',
          sources: sources,
        );
        return;
      }

      // 图源禁用：有图源，但全部被停用。
      if (!sources.any((source) => source.enabled)) {
        _settle(
          state: SourceStateKind.disabled,
          detail: '板块内的源都被停用，去源管理里启用',
          sources: sources,
        );
        return;
      }

      final current = await _manager.current();
      if (current == null) {
        _settle(
          state: SourceStateKind.disabled,
          detail: '板块内没有可用的源',
          sources: sources,
        );
        return;
      }

      final source = await _manager.open(current.id);
      if (source == null) {
        // 管理器打不开它：多半是脚本载入失败。
        _settle(
          state: SourceStateKind.scriptError,
          detail: '当前源打不开（脚本载入失败或源不可用）',
          sources: sources,
          current: current,
        );
        return;
      }
      if (source.section != widget.section) {
        // 双保险：跨板块的数据源一律不渲染。
        LumeLog.warn(
          '[${widget.section.id}] 拒绝渲染跨板块数据源: ${source.id} '
          '归属「${source.section.id}」',
        );
        _settle(
          state: SourceStateKind.disabled,
          title: '源不可用',
          detail: '源板块不符，已拒绝加载',
          sources: sources,
          current: current,
        );
        return;
      }

      if (!mounted) return;
      setState(() {
        _sources = sources;
        _current = current;
        _source = source;
        _state = SourceStateKind.ready;
        _title = null;
        _detail = null;
        _failed = false;
      });
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.section.id}] 源状态异常: $error');
      _settle(state: stateForError(error), detail: error.message);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _state = SourceStateKind.ready;
        _source = null;
        _failed = true;
      });
    }
  }

  void _settle({
    required SourceStateKind state,
    String? title,
    String? detail,
    List<SourceDescriptor>? sources,
    SourceDescriptor? current,
  }) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _title = title;
      _detail = detail;
      _sources = sources ?? _sources;
      _current = current;
      _source = null;
      _failed = false;
    });
  }

  /// 切换图源：候选只来自本板块已启用的图源。
  Future<void> _switchSource() async {
    final options =
        _sources.where((source) => source.enabled).toList(growable: false);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SourceSwitchSheet(
        sources: options,
        currentId: _current?.id,
      ),
    );
    if (!mounted || selected == null || selected == _current?.id) return;

    final record = await _manager.select(selected);
    if (!mounted) return;
    if (record == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该源不可用')),
      );
    }
    await _resolve();
  }

  /// 进入图源管理；返回后重新解析（可能导入了新图源、改变了当前图源）。
  Future<void> _manage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSectionPage(
          section: widget.section,
          manager: widget.manager,
        ),
      ),
    );
    if (!mounted) return;
    await _resolve();
  }

  @override
  Widget build(BuildContext context) => _buildBody();

  Widget _buildBody() {
    if (!_manager.runtimeAvailable) return const SkeletonNotice();
    if (_failed) {
      return NoticeCard(
        title: '源存储不可用',
        subtitle: LumeTheme.appName,
        action: _manageButton(),
      );
    }
    final source = _source;
    if (_state == SourceStateKind.ready && source != null) {
      final onItemTap = widget.onItemTap;
      return Column(
        children: <Widget>[
          _buildSourceBar(),
          Expanded(
            child: BrowseView(
              // 换代时连浏览面一起重挂：换图源要重取列表，图源没换时刷新
              // 也要求看到当下的内容（与从前「换 Key 重挂」的可见行为一致）。
              key: ValueKey<String>('${source.id}#${widget.revision}'),
              dataSource: source,
              pipeline: widget.pipeline,
              // 宿主没给回调就走浏览面的通用口径（进详情页）。
              onItemTap:
                  onItemTap == null ? null : (item) => onItemTap(source, item),
            ),
          ),
        ],
      );
    }
    return SourceStateView(
      state: _state,
      title: _title,
      detail: _detail,
      onRetry: _state == SourceStateKind.loading ? null : _resolve,
      action: _state == SourceStateKind.loading ? null : _manageButton(),
    );
  }

  /// 当前图源条：点击切换（候选只来自本板块已启用的图源）。
  Widget _buildSourceBar() {
    final current = _current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: _switchSource,
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.source_outlined,
              size: 18,
              color: LumeTheme.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                current?.name ?? '未选择源',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            if (widget.showSourceActions)
              IconButton(
                tooltip: '源管理',
                icon: const Icon(Icons.tune, size: 20),
                onPressed: _manage,
              )
            else
              const Icon(Icons.expand_more, size: 18, color: LumeTheme.muted),
          ],
        ),
      ),
    );
  }

  Widget _manageButton() => FilledButton(
        onPressed: _manage,
        child: const Text('源管理'),
      );
}

/// 切换图源面板：列出板块内已启用的图源，当前项打勾。
class _SourceSwitchSheet extends StatelessWidget {
  const _SourceSwitchSheet({required this.sources, required this.currentId});

  final List<SourceDescriptor> sources;
  final String? currentId;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '切换源',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              for (final source in sources)
                ListTile(
                  title: Text(
                    source.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    source.version.isEmpty ? LumeTheme.appName : source.version,
                    style: const TextStyle(
                      fontSize: 12,
                      color: LumeTheme.muted,
                    ),
                  ),
                  trailing: source.id == currentId
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                  onTap: () => Navigator.of(context).pop(source.id),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
