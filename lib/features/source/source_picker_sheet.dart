import '../../shared/widgets/source_type_swipe.dart';
import 'source_entry_order_sheet.dart';
import '../../shared/widgets/native_glass_surfaces.dart';
import '../../shared/widgets/source_picker_card.dart';
import '../../shared/widgets/source_picker_header.dart';
import '../../shared/widgets/source_picker_scroll_list.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/browse_side_drawer.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../shared/widgets/cat_site_tile.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_swipe_tile.dart';
import '../../shared/widgets/source_card_metrics.dart';
import '../../shared/widgets/source_icon.dart';
import '../../core/source/source_content_rating.dart';
import '../../shared/widgets/source_rating_badge.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_content_visibility.dart';

import '../../shared/widgets/frosted_glass_widget.dart';

import 'package:flutter/material.dart';

import '../../core/reading/reading_library.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_picker_groups.dart';
import '../../core/source/source_preferences.dart';
import '../../core/theme/lume_theme.dart';
import 'source_action_dialogs.dart';
import 'source_preferences_page.dart';
import 'source_section_page.dart';
import 'source_maintenance.dart';
import 'add_source_button.dart';
import 'source_drawer_actions.dart';
import '../shell/section_preloader.dart';
import '../settings/subscription_sync_page.dart';

enum SourceQuickAction { pin, preferences, browse, test, update }

Future<String?> showSourcePicker({
  required BuildContext context,
  required Section section,
  required List<SourceDescriptor> sources,
  required String? currentId,
  SourceManager? manager,
  VoidCallback? onChanged,
  BrowseDrawerMotion? motion,
}) => showBrowseSideDrawer<String>(
  context: context,
  side: motion?.side ?? BrowseDrawerSide.left,
  edgeToggle: true,
  motion: motion,
  builder: (_) => SourcePickerSheet(
    section: section,
    sources: sources,
    currentId: currentId,
    manager: manager,
    extraActions: SourceDrawerActions.of(context),
    onChanged: onChanged,
  ),
);

class SourcePickerSheet extends StatefulWidget {
  static const contentFilterKey = 'source.picker.contentFilter';
  const SourcePickerSheet({
    super.key,
    required this.section,
    required this.sources,
    required this.currentId,
    this.manager,
    this.onChanged,
    this.initialColumns,
    this.extraActions = const [],
  });
  final Section section;
  final List<SourceDescriptor> sources;
  final String? currentId;
  final SourceManager? manager;
  final List<Widget> extraActions;
  final VoidCallback? onChanged;

  /// 预览/测试用：强制初始单双列；为空时读板块设置。
  final bool? initialColumns;
  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  late final SourceManager manager =
      widget.manager ?? LumeSources.manager(widget.section);
  late List<SourceDescriptor> sources = List.of(widget.sources);
  late bool columns =
      widget.initialColumns ??
      // 漫画 / 视频固定两列；猫源按设置切换，默认单列。
      (widget.section != Section.cat ||
          switch (ReadingLibrary.find(widget.section)
              ?.setting('source.picker.columns')) {
            'true' => true,
            _ => false,
          });
  String query = '';
  String contentGroup = 'all';
  final _typeKeys = <String, GlobalKey>{};
  final _currentSourceKey = GlobalKey();
  bool _locateCurrent = true;
  List<SourceDescriptor>? _sortInput, _sorted;
  List<SourceDescriptor> _orderedSources() {
    if (identical(_sortInput, sources) && _sorted != null) return _sorted!;
    _sortInput = sources;
    final compare = SourceOrder.comparator(
      widget.section,
      sources.map((s) => s.id).toList(),
    );
    final pins = {
      for (final source in sources)
        source.id: SourcePreferences.read(widget.section, source.id).pinned,
    };
    return _sorted = List<SourceDescriptor>.of(sources)
      ..sort((a, b) {
        final pa = pins[a.id]!, pb = pins[b.id]!;
        return pa == pb
            ? compare(a.id, b.id)
            : pa
            ? -1
            : 1;
      });
  }

  final busy = <String>{};
  final results = <String, SourceTestResult>{};

  @override
  void initState() {
    super.initState();
    if (widget.section == Section.comic) {
      final groups = SourceContentVisibility.instance.groups(widget.section);
      final saved = ReadingLibrary.find(widget.section)
          ?.setting(SourcePickerSheet.contentFilterKey);
      contentGroup = saved == 'all' || groups.any((group) => group.$1 == saved)
          ? saved!
          : 'all';
    }
    SourceSubscriptionSync.revision(widget.section)
        .addListener(_subscriptionChanged);
    SourceContentVisibility.instance.addListener(_onVisibility);
  }

  void _chooseGroup(String value) {
    if (value == contentGroup) return;
    setState(() {
      contentGroup = value;
      _locateCurrent = false;
    });
    ReadingLibrary.find(widget.section)
        ?.setSetting(SourcePickerSheet.contentFilterKey, value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _typeKeys[value]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  void _stepGroup(int direction) {
    final values = [
      'all',
      ...SourceContentVisibility.instance
          .groups(widget.section)
          .map((g) => g.$1),
    ];
    final index = values.indexOf(contentGroup);
    final next = index + direction;
    if (index >= 0 && next >= 0 && next < values.length) {
      _chooseGroup(values[next]);
    }
  }

  void _subscriptionChanged() {
    if (mounted) reload();
  }

  void _onVisibility() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SourceSubscriptionSync.revision(widget.section)
        .removeListener(_subscriptionChanged);
    SourceContentVisibility.instance.removeListener(_onVisibility);
    super.dispose();
  }

  Future<void> reload() async {
    final next = await manager.list();
    if (mounted) setState(() => sources = next);
  }

  Future<void> manageSources() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceSectionPage(section: widget.section, manager: manager),
      ),
    );
    if (!mounted) return;
    widget.onChanged?.call();
    await reload();
  }

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> network(SourceDescriptor source) async {
    source =
        (await manager.list()).where((s) => s.id == source.id).firstOrNull ??
        source;
    if (!mounted) return;
    final result = await showGlassDialog<SourceSettingsResult>(
      context: context,
      builder: (_) => SourceNetworkDialog(source: source),
    );
    if (result == null || !mounted) return;
    final profile = result.network;
    await manager.setNetwork(
      source.id,
      userAgent: profile.userAgent,
      cookie: profile.cookie,
      proxy: profile.proxy,
      bridge: profile.bridge,
      allowBadCertificate: profile.allowBadCertificate,
    );
    await manager.setSiteConfig(source.id, result.site);
    SectionPreloader.discard(widget.section);
    widget.onChanged?.call();
    await reload();
  }

  Future<void> openSettings(SourceDescriptor source) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => SourcePreferencesPage(
          section: widget.section,
          sourceId: source.id,
          name: source.name,
          siteUrl: source.siteUrl,
          showWidgetParameters: source.runtimeKind == 'module',
          descriptor: source,
          manager: manager,
          onNetwork: () => network(source),
        ),
      ),
    );
    if (saved == true) widget.onChanged?.call();
    if (mounted) await reload();
  }

  Future<void> deleteSource(SourceDescriptor source) async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除「${source.name}」？其脚本与运行时将一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: LumeTheme.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || busy.contains(source.id)) return;
    setState(() => busy.add(source.id));
    try {
      final result = await SourceMaintenance(
        section: widget.section,
        manager: manager,
      ).remove([source]);
      if (result.errors.isNotEmpty) throw StateError('删除未完成');
      widget.onChanged?.call();
      await reload();
    } catch (error) {
      toast('删除失败：$error');
    } finally {
      if (mounted) setState(() => busy.remove(source.id));
    }
  }

  Future<void> action(SourceDescriptor source) async {
    if (busy.contains(source.id)) return;
    final prefs = SourcePreferences.read(widget.section, source.id);
    final selected = await showGlassDialog<SourceQuickAction>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .28),
      builder: (dialogContext) => Dialog(
        constraints: const BoxConstraints(maxWidth: 320),
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: FrostedGlassWidget(
            nativeGlass: false,
            neutralTint: true,
            color: LumeTheme.surface,
            opacity: .96,
            radius: 24,
            child: Material(
              color: LumeTheme.surface,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final entry in [
                        (
                          SourceQuickAction.pin,
                          Icons.push_pin_outlined,
                          prefs.pinned ? '取消置顶' : '置顶此源',
                        ),
                        (SourceQuickAction.preferences, Icons.tune, '源设置'),
                        (SourceQuickAction.browse, Icons.open_in_new, '浏览'),
                        (SourceQuickAction.test, Icons.network_check, '测试连通性'),
                        (SourceQuickAction.update, Icons.refresh, '更新订阅源'),
                      ])
                        ListTile(
                          leading: LumeIcon(
                            entry.$2,
                            slot: 'source_picker_sheet.1',
                            variant: true,
                            color: LumeTheme.accent,
                          ),
                          title: Text(entry.$3),
                          enabled:
                              entry.$1 != SourceQuickAction.update ||
                              source.subscribed,
                          onTap: () => Navigator.pop(dialogContext, entry.$1),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == SourceQuickAction.browse) {
      Navigator.pop(context, source.id);
      return;
    }
    setState(() => busy.add(source.id));
    try {
      switch (selected) {
        case SourceQuickAction.pin:
          await prefs
              .copyWith(pinned: !prefs.pinned)
              .save(widget.section, source.id);
          _sorted = null;
          widget.onChanged?.call();
        case SourceQuickAction.preferences:
          await openSettings(source);
        case SourceQuickAction.test:
          final result = await manager.testConnectivity(source.id);
          if (!mounted) return;
          setState(() {
            results[source.id] = result;
            busy.remove(source.id);
          });
          await showGlassDialog<void>(
            context: context,
            builder: (_) =>
                SourceTestResultDialog(sourceName: source.name, result: result),
          );
        case SourceQuickAction.update:
          final result = await manager.updateFromSubscription(source.id);
          if (result.status == SourceUpdateStatus.updated) {
            widget.onChanged?.call();
          }
          toast(switch (result.status) {
            SourceUpdateStatus.updated =>
              '「${source.name}」已更新：${result.versionChange}；个人设置已保留${result.message.isEmpty ? '' : '（${result.message}）'}',
            SourceUpdateStatus.unchanged => '「${source.name}」已是最新',
            SourceUpdateStatus.skipped => '跳过：${result.message}',
            SourceUpdateStatus.failed => '更新失败：${result.message}',
          });
        case SourceQuickAction.browse:
          break;
      }
      if (mounted) await reload();
    } catch (error) {
      toast('操作失败：$error');
    } finally {
      if (mounted) setState(() => busy.remove(source.id));
    }
  }

  Widget sourceTile(SourceDescriptor source) {
    final selected = source.id == widget.currentId;
    final busyNow = busy.contains(source.id);
    // 猫源走**单独的**极简卡片：没有左侧图标、没有右侧三点，文字单行居中。
    // 高度 / 圆角 / 描边与其它三个板块共用 SourceCardMetrics。
    if (widget.section == Section.cat) {
      return KeyedSubtree(
        key: selected ? _currentSourceKey : null,
        child: CatSiteTile(
          key: ValueKey('picker-source-${source.id}'),
          height: CatSiteTile.compactHeight,
          label: source.name,
          selected: selected,
          busy: busyNow,
          onTap: busyNow ? null : () => Navigator.pop(context, source.id),
        ),
      );
    }

    final prefs = SourcePreferences.read(widget.section, source.id);
    final adult = SourceContentRating.isAdult(source.id, source.name);
    final accent = Theme.of(context).colorScheme.primary;
    return SourcePickerCard(
      key: selected ? _currentSourceKey : null,
      surfaceKey: ValueKey('picker-card-${source.id}'),
      tapKey: ValueKey('picker-source-${source.id}'),
      moreKey: ValueKey('picker-more-${source.id}'),
      title: source.name,
      selected: selected,
      onTap: busyNow ? null : () => Navigator.pop(context, source.id),
      onMore: () => action(source),
      icon: busyNow
          ? const Center(
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : SourceIcon(
              key: ValueKey('picker-icon-${source.id}'),
              name: source.name,
              siteUrl: source.siteUrl,
              iconUrl: prefs.iconUrl.trim().isEmpty
                  ? source.iconUrl
                  : prefs.iconUrl,
              size: SourceCardMetrics.iconSize,
              radius: 8,
              section: widget.section,
              sourceId: source.id,
            ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              results[source.id]?.status.label ?? source.version,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (adult)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: SourceRatingBadge(compact: true),
            ),
          if (prefs.pinned)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: LumeIcon(
                Icons.push_pin,
                slot: 'source_picker_sheet.2',
                size: 11,
                color: accent,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _orderedSources()
        .where(
          (source) =>
              source.enabled &&
              (contentGroup == 'all' ||
                  SourcePickerGroups.groupFor(widget.section, source) ==
                      contentGroup) &&
              SourceContentVisibility.instance.allows(widget.section, source) &&
              (source.name.toLowerCase().contains(query) ||
                  source.id.toLowerCase().contains(query) ||
                  source.group.toLowerCase().contains(query)),
        )
        .toList();
    final order = sources.map((s) => s.id).toList();
    final compareOrder = SourceOrder.comparator(widget.section, order);
    Future<void> move(
      List<SourceDescriptor> entries,
      String from,
      String to,
    ) async {
      final all = List<SourceDescriptor>.of(sources)
        ..sort((a, b) => compareOrder(a.id, b.id));
      await SourceOrder.move(
        widget.section,
        all.map((s) => s.id).toList(),
        entries.map((s) => s.id).toList(),
        entries.indexWhere((s) => s.id == from),
        entries.indexWhere((s) => s.id == to),
      );
      if (mounted) setState(() => _sorted = null);
    }

    // 猫源卡片：左滑露出设置 / 删除；长按拖拽仍由外层 SourceDragTile 负责。
    Widget catCard(SourceDescriptor source) => SourceSwipeTile(
      height: CatSiteTile.compactHeight,
      actions: <SourceSwipeAction>[
        SourceSwipeAction(
          label: '设置',
          color: LumeTheme.accent,
          onTap: () => openSettings(source),
        ),
        SourceSwipeAction(
          label: '删除',
          color: LumeTheme.danger,
          onTap: () => deleteSource(source),
        ),
      ],
      child: sourceTile(source),
    );

    Widget swipeCard(SourceDescriptor source) => SourceSwipeTile(
      key: ValueKey('picker-swipe-${source.id}'),
      actions: [
        SourceSwipeAction(
          label: '删除',
          color: LumeTheme.danger,
          onTap: () => deleteSource(source),
        ),
      ],
      child: sourceTile(source),
    );

    Widget tile(
      BuildContext context,
      SourceDescriptor source,
      List<SourceDescriptor> entries,
    ) => SourceDragTile(
      key: ValueKey('picker-drag-${source.id}'),
      id: source.id,
      name: source.name,
      accepts: (id) => entries.any((s) => s.id == id),
      onMove: (from, to) => move(entries, from, to),
      child: widget.section == Section.cat
          ? catCard(source)
          : swipeCard(source),
    );

    final grouped = {
      for (final group in SourcePickerGroups.forSection(widget.section))
        group.$1: <SourceDescriptor>[],
    };
    for (final source in visible) {
      grouped[SourcePickerGroups.groupFor(widget.section, source)]!.add(source);
    }
    final groupDefinitions = SourcePickerGroups.forSection(widget.section);
    final current = visible
        .where((source) => source.id == widget.currentId)
        .firstOrNull;
    final currentGroup = current == null
        ? null
        : SourcePickerGroups.groupFor(widget.section, current);
    final currentIndex = currentGroup == null
        ? 0
        : grouped[currentGroup]!.indexWhere(
            (source) => source.id == current!.id,
          );
    final focusKey = _locateCurrent && current != null
        ? _currentSourceKey
        : null;
    final rowHeight = widget.section == Section.cat
        ? CatSiteTile.compactHeight + 6
        : SourceCardMetrics.height + SourceCardMetrics.rowGap;
    final initialOffset = currentGroup == null
        ? 0.0
        : (groupDefinitions
                  .takeWhile((group) => group.$1 != currentGroup)
                  .fold<double>(
                    0,
                    (offset, group) =>
                        offset +
                        (columns
                                ? (grouped[group.$1]!.length + 1) ~/ 2
                                : grouped[group.$1]!.length) *
                            rowHeight +
                        60,
                  ) +
              (columns ? currentIndex ~/ 2 : currentIndex) * rowHeight);
    final rows = <WidgetBuilder>[];
    for (final group in groupDefinitions) {
      final entries = grouped[group.$1]!;
      if (entries.isEmpty) continue;
      rows.add(
        (context) => Semantics(
          header: true,
          child: Padding(
            key: ValueKey('picker-group-${group.$1}'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Text(
              group.$2,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
      );
      for (var i = 0; i < entries.length; i += columns ? 2 : 1) {
        final index = i;
        rows.add(
          (context) => Padding(
            padding: EdgeInsets.fromLTRB(
              widget.section == Section.cat ? 16 : 14,
              0,
              widget.section == Section.cat ? 16 : 14,
              widget.section == Section.cat ? 6 : SourceCardMetrics.rowGap,
            ),
            child: SizedBox(
              height: widget.section == Section.cat
                  ? CatSiteTile.compactHeight
                  : SourceCardMetrics.height,
              child: columns
                  ? Row(
                      children: [
                        Expanded(child: tile(context, entries[index], entries)),
                        const SizedBox(width: SourceCardMetrics.columnGap),
                        Expanded(
                          child: index + 1 < entries.length
                              ? tile(context, entries[index + 1], entries)
                              : const SizedBox(),
                        ),
                      ],
                    )
                  : tile(context, entries[index], entries),
            ),
          ),
        );
      }
      rows.add((_) => const SizedBox(height: 8));
    }
    final singleList = visible.isEmpty
        ? Center(child: Text(query.isEmpty ? '暂无源' : '没有匹配的源'))
        : SourcePickerScrollList(
            key: const ValueKey('picker-grouped-list'),
            storageKey: PageStorageKey('reading-source-$contentGroup-$query'),
            focusKey: focusKey,
            estimatedOffset: initialOffset,
            itemCount: rows.length,
            itemBuilder: (context, index) => rows[index](context),
          );

    final groupedList = singleList;

    final content = SafeArea(
      top: false,
      child: SizedBox(
        height: DrawerGeometry.height(context),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              SourcePickerHeader(
                title: '选择${widget.section.label}源',
                onSync: () async {
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          SubscriptionSyncPage(section: widget.section),
                    ),
                  );
                  if (mounted) await reload();
                },
                onManage: manageSources,
                addAction: AddSourceButton(
                  section: widget.section,
                  manager: manager,
                  onImported: () {
                    widget.onChanged?.call();
                    reload();
                  },
                ),
                onQueryChanged: (value) => setState(() {
                  _locateCurrent = false;
                  query = value.trim().toLowerCase();
                }),
                extraActions: [
                  ...widget.extraActions,
                  IconButton(
                    tooltip: '调整分类顺序',
                    icon: const Icon(Icons.swap_vert),
                    onPressed: () async {
                      await showSourceEntryOrder(
                        context,
                        section: widget.section,
                        settingKey: SourcePickerGroups.orderKey,
                        entries: SourcePickerGroups.forSection(widget.section),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                  if (widget.section == Section.cat)
                    IconButton(
                      tooltip: columns ? '切换为单列' : '切换为双列',
                      icon: LumeIcon(
                        columns
                            ? Icons.view_agenda_outlined
                            : Icons.view_column_outlined,
                        slot: 'source_picker_sheet.5',
                        variant: true,
                      ),
                      onPressed: () async {
                        setState(() {
                          _locateCurrent = false;
                          columns = !columns;
                        });
                        final library = await ReadingLibrary.open(
                          widget.section,
                        );
                        library.setSetting('source.picker.columns', '$columns');
                      },
                    ),
                ],
              ),
              if (widget.section == Section.cat)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '点击选择源，长按拖动排序，左滑打开设置/删除',
                    style: TextStyle(
                      fontSize: LumeTypography.captionSize,
                      color: LumeTheme.muted,
                    ),
                  ),
                ),
              if (widget.section == Section.comic)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final group in [
                        ('all', '全部'),
                        ...SourceContentVisibility.instance.groups(
                          widget.section,
                        ),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            key: _typeKeys.putIfAbsent(group.$1, GlobalKey.new),
                            label: Text(group.$2),
                            selected: contentGroup == group.$1,
                            onSelected: (_) => _chooseGroup(group.$1),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: widget.section == Section.comic
                    ? SourceTypeSwipe(
                        key: const ValueKey('reading-type-swipe'),
                        onStep: _stepGroup,
                        child: groupedList,
                      )
                    : groupedList,
              ),
            ],
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: LumeTheme.surface,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: content,
        ),
      ),
    );
  }
}
