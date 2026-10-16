import '../../shared/widgets/column_list.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/module_glass_surface.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../shared/widgets/source_update_badge.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../core/source/source_content_rating.dart';
import '../../shared/widgets/source_rating_badge.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_content_visibility.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/reading/reading_library.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_picker_groups.dart';
import '../../core/source/source_preferences.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/source_icon.dart';
import 'source_action_dialogs.dart';
import 'source_preferences_page.dart';

enum SourceQuickAction { pin, preferences, browse, test, update }

Future<String?> showSourcePicker({
  required BuildContext context,
  required Section section,
  required List<SourceDescriptor> sources,
  required String? currentId,
  SourceManager? manager,
  VoidCallback? onChanged,
}) => showLumeBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => SourcePickerSheet(
    section: section,
    sources: sources,
    currentId: currentId,
    manager: manager,
    onChanged: onChanged,
  ),
);

class SourcePickerSheet extends StatefulWidget {
  const SourcePickerSheet({
    super.key,
    required this.section,
    required this.sources,
    required this.currentId,
    this.manager,
    this.onChanged,
  });
  final Section section;
  final List<SourceDescriptor> sources;
  final String? currentId;
  final SourceManager? manager;
  final VoidCallback? onChanged;
  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  late final SourceManager manager =
      widget.manager ?? LumeSources.manager(widget.section);
  late List<SourceDescriptor> sources = List.of(widget.sources);
  late bool columns =
      ReadingLibrary.find(widget.section)?.setting('source.picker.columns') !=
      'false';
  String query = '';
  final busy = <String>{};
  final results = <String, SourceTestResult>{};

  @override
  void initState() {
    super.initState();
    SourceSubscriptionSync.revision(widget.section)
        .addListener(_subscriptionChanged);
    SourceContentVisibility.instance.addListener(_onVisibility);
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

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> network(SourceDescriptor source) async {
    final result = await showDialog<SourceSettingsResult>(
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
    // 换网址 / 账号登入：只落库，不释放运行时——下一次调用前宿主会把新快照
    // 注入脚本（见 SourceRegistry.scriptConfigFor）。
    await manager.setSiteConfig(source.id, result.site);
    await manager.setEnabled(source.id, source.enabled);
    widget.onChanged?.call();
    await reload();
  }

  Future<void> action(SourceDescriptor source) async {
    if (busy.contains(source.id)) return;
    final prefs = SourcePreferences.read(widget.section, source.id);
    final selected = await showDialog<SourceQuickAction>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .28),
      builder: (dialogContext) => Dialog(
        constraints: const BoxConstraints(maxWidth: 320),
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              color: LumeTheme.surface.withValues(alpha: .94),
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
                          leading: Icon(entry.$2, color: LumeTheme.accent),
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
          widget.onChanged?.call();
        case SourceQuickAction.preferences:
          final saved = await Navigator.push<bool>(
            context,
            MaterialPageRoute<bool>(
              builder: (_) => SourcePreferencesPage(
                section: widget.section,
                sourceId: source.id,
                name: source.name,
                siteUrl: source.siteUrl,
                onNetwork: () => network(source),
              ),
            ),
          );
          if (saved == true) widget.onChanged?.call();
        case SourceQuickAction.test:
          final result = await manager.testConnectivity(source.id);
          if (!mounted) return;
          setState(() {
            results[source.id] = result;
            busy.remove(source.id);
          });
          await showDialog<void>(
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
              '「${source.name}」已更新到最新脚本${result.message.isEmpty ? '' : '（${result.message}）'}',
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
    final prefs = SourcePreferences.read(widget.section, source.id);
    final selected = source.id == widget.currentId;

    return Material(
      color: selected
          ? Color.alphaBlend(
              LumeTheme.accent.withValues(alpha: .18),
              LumeTheme.surfaceAlt,
            )
          : LumeTheme.surfaceAlt,
      elevation: 2,
      shadowColor: LumeTheme.cardShadow.first.color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('picker-source-${source.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: busy.contains(source.id)
            ? null
            : () => Navigator.pop(context, source.id),

        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              SourceIcon(
                name: source.name,
                siteUrl: source.siteUrl,
                siteIcon: source.iconUrl,
                iconUrl: prefs.iconUrl,
                section: widget.section,
                sourceId: source.id,
                size: 30,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    SourceUpdateBadge(
                      section: widget.section,
                      sourceId: source.id,
                    ),
                    Text(
                      results[source.id]?.status.label ?? source.version,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (SourceContentRating.isAdult(source.id, source.name))
                const SourceRatingBadge(),
              IconButton(
                key: ValueKey('picker-more-${source.id}'),
                tooltip: '源操作',
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => action(source),
                icon: const Icon(Icons.more_vert, size: 18),
              ),
              if (busy.contains(source.id))
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (prefs.pinned)
                Icon(Icons.push_pin, size: 13, color: LumeTheme.accent)
              else if (selected)
                Icon(Icons.check, size: 15, color: LumeTheme.accent),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = SourceContentVisibility.instance.groups(widget.section);
    final visible = sources
        .where(
          (source) =>
              source.enabled &&
              SourceContentVisibility.instance.allows(widget.section, source) &&
              (source.name.toLowerCase().contains(query) ||
                  source.id.toLowerCase().contains(query) ||
                  source.group.toLowerCase().contains(query)),
        )
        .toList();
    final order = sources.map((s) => s.id).toList();
    visible.sort((a, b) {
      final pinA = SourcePreferences.read(widget.section, a.id).pinned;
      final pinB = SourcePreferences.read(widget.section, b.id).pinned;
      return pinA != pinB
          ? (pinA ? -1 : 1)
          : SourceOrder.compare(widget.section, a.id, b.id, order);
    });
    Future<void> move(
      List<SourceDescriptor> entries,
      String from,
      String to,
    ) async {
      final all = List<SourceDescriptor>.of(
        sources,
      )..sort((a, b) => SourceOrder.compare(widget.section, a.id, b.id, order));
      await SourceOrder.move(
        widget.section,
        all.map((s) => s.id).toList(),
        entries.map((s) => s.id).toList(),
        entries.indexWhere((s) => s.id == from),
        entries.indexWhere((s) => s.id == to),
      );
      if (mounted) setState(() {});
    }

    Widget list(List<SourceDescriptor> entries) {
      Widget tile(BuildContext context, int i) => SourceDragTile(
        key: ValueKey('picker-drag-${entries[i].id}'),
        id: entries[i].id,
        name: entries[i].name,
        accepts: (id) => entries.any((s) => s.id == id),
        onMove: (from, to) => move(entries, from, to),
        child: sourceTile(entries[i]),
      );
      if (entries.isEmpty) {
        return Center(child: Text(query.isEmpty ? '暂无源' : '没有匹配的源'));
      }
      return columns && groups.length != 2
          ? ColumnList(
              itemCount: entries.length,
              itemBuilder: tile,
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
              itemCount: entries.length,
              itemBuilder: tile,
            );
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ModuleGlassSurface(
        module: GlassModule.sources,
        part: GlassPart.panels,
        legacy: Material(
          color: LumeTheme.surface,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: DrawerGeometry.height(context),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              onChanged: (value) => setState(
                                () => query = value.trim().toLowerCase(),
                              ),
                              decoration: const InputDecoration(
                                hintText: '搜索源',
                                prefixIcon: Icon(Icons.search),
                              ),
                            ),
                          ),

                          IconButton(
                            tooltip: columns ? '切换为单列' : '切换为双列',
                            icon: Icon(
                              columns
                                  ? Icons.view_agenda_outlined
                                  : Icons.view_column_outlined,
                            ),
                            onPressed: () async {
                              setState(() => columns = !columns);
                              final library = await ReadingLibrary.open(
                                widget.section,
                              );
                              library.setSetting(
                                'source.picker.columns',
                                '$columns',
                              );
                            },
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '长按源条目拖动排序，点击更多打开操作菜单',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: columns && groups.length == 2
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final group in groups)
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          group.$2,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: LumeTheme.accent,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Expanded(
                                          child: list(
                                            visible
                                                .where(
                                                  (source) =>
                                                      SourcePickerGroups.groupFor(
                                                        widget.section,
                                                        source,
                                                      ) ==
                                                      group.$1,
                                                )
                                                .toList(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            )
                          : list(visible),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: DrawerGeometry.height(context),
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            onChanged: (value) => setState(
                              () => query = value.trim().toLowerCase(),
                            ),
                            decoration: const InputDecoration(
                              hintText: '搜索源',
                              prefixIcon: Icon(Icons.search),
                            ),
                          ),
                        ),

                        IconButton(
                          tooltip: columns ? '切换为单列' : '切换为双列',
                          icon: Icon(
                            columns
                                ? Icons.view_agenda_outlined
                                : Icons.view_column_outlined,
                          ),
                          onPressed: () async {
                            setState(() => columns = !columns);
                            final library = await ReadingLibrary.open(
                              widget.section,
                            );
                            library.setSetting(
                              'source.picker.columns',
                              '$columns',
                            );
                          },
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '长按源条目拖动排序，点击更多打开操作菜单',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: LumeTheme.muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: columns && groups.length == 2
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final group in groups)
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
                                        group.$2,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: LumeTheme.accent,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Expanded(
                                        child: list(
                                          visible
                                              .where(
                                                (source) =>
                                                    SourcePickerGroups.groupFor(
                                                      widget.section,
                                                      source,
                                                    ) ==
                                                    group.$1,
                                              )
                                              .toList(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          )
                        : list(visible),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
