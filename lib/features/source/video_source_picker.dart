import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cat/cat_service.dart';
import '../../core/reading/reading_library.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_content_visibility.dart';
import '../../core/source/source_order.dart';
import '../../core/source/source_preferences.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/lume_icon.dart';
import '../../shared/widgets/source_card_metrics.dart';
import '../../shared/widgets/source_drag_tile.dart';
import '../../shared/widgets/source_icon.dart';
import '../cat/cat_subscription_page.dart';
import 'source_import_dialog.dart';
import 'source_preferences_page.dart';

enum VideoSourceType {
  all('全部'),
  ordinary('普通'),
  cat('猫源'),
  python('PY'),
  module('模块'),
  web('网页');

  const VideoSourceType(this.label);
  final String label;
}

class VideoSourceChoice {
  const VideoSourceChoice.ordinary(this.sourceId) : site = null;
  const VideoSourceChoice.cat(this.site) : sourceId = null;
  final String? sourceId;
  final CatSite? site;
}

Future<VideoSourceChoice?> showVideoSourcePicker({
  required BuildContext context,
  required SourceManager manager,
  String? currentCatId,
  bool showingCat = false,
}) => showLumeBottomSheet<VideoSourceChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  builder: (_) => VideoSourcePicker(
    manager: manager,
    currentCatId: currentCatId,
    showingCat: showingCat,
  ),
);

/// Type tabs belong only to the drawer. Subscriptions are headings, not another
/// home-page selector. IDs and playback continue to use their original stores.
class VideoSourcePicker extends StatefulWidget {
  const VideoSourcePicker({
    super.key,
    required this.manager,
    this.currentCatId,
    this.showingCat = false,
    this.service,
  });
  final SourceManager manager;
  final String? currentCatId;
  final bool showingCat;
  final CatService? service;

  @override
  State<VideoSourcePicker> createState() => _VideoSourcePickerState();
}

class _VideoSourcePickerState extends State<VideoSourcePicker> {
  late final service = widget.service ?? CatService.instance;
  VideoSourceType type = VideoSourceType.all;
  String query = '';
  List<SourceDescriptor> sources = [];
  String? currentId, error;
  bool loading = true;
  final busy = <String>{};

  @override
  void initState() {
    super.initState();
    service.addListener(changed);
    SourceContentVisibility.instance.addListener(changed);
    PrivacySettings.instance.addListener(changed);
    unawaited(load());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    service.removeListener(changed);
    SourceContentVisibility.instance.removeListener(changed);
    PrivacySettings.instance.removeListener(changed);
    super.dispose();
  }

  Future<void> load() async {
    try {
      await ReadingLibrary.open(Section.video);
      await ReadingLibrary.open(Section.cat);
      await service.boot();
      final rows = await widget.manager.list();
      final current = await widget.manager.current();
      if (!mounted) return;
      setState(() {
        sources = rows;
        currentId = current?.id;
        loading = false;
        error = null;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  bool matches(String text) => text.toLowerCase().contains(query);

  Future<void> edit(Section section, String id, String name, String url) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcePreferencesPage(
          section: section,
          sourceId: id,
          name: name,
          siteUrl: url,
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> add() async {
    final target = await showModalBottomSheet<VideoSourceType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '添加视频源',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final row in [
              (VideoSourceType.ordinary, Icons.code, '普通视频源', '导入 JS 文件或订阅链接'),
              (VideoSourceType.cat, Icons.pets_outlined, '猫源订阅', '管理订阅包与包内站点'),
              (VideoSourceType.python, Icons.terminal, 'Python 源', '运行环境尚未接入'),
              (
                VideoSourceType.module,
                Icons.extension_outlined,
                '模块源',
                '模块兼容尚未接入',
              ),
              (VideoSourceType.web, Icons.language, '网页主页', '网页入口尚未接入'),
            ])
              ListTile(
                leading: LumeIcon(
                  row.$2,
                  slot: 'video_source_picker.add',
                  variant: true,
                ),
                title: Text(row.$3),
                subtitle: Text(row.$4),
                onTap: () => Navigator.pop(context, row.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || target == null) return;
    if (target == VideoSourceType.ordinary) {
      await runSourceImport(
        context,
        section: Section.video,
        manager: widget.manager,
      );
    } else if (target == VideoSourceType.cat) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const CatSubscriptionPage()),
      );
    } else {
      setState(() => type = target);
      return;
    }
    if (mounted) await load();
  }

  Future<void> refresh(CatSubscription record) async {
    if (busy.contains(record.id)) return;
    setState(() => busy.add(record.id));
    try {
      await service.refreshSites(record);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$failure')));
      }
    } finally {
      if (mounted) setState(() => busy.remove(record.id));
    }
  }

  Widget card({
    required String id,
    required String name,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onMore,
    SourceDescriptor? descriptor,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Tooltip(
      message: name,
      child: Semantics(
        selected: selected,
        child: Container(
          height: 68 + (scale - 1).clamp(0, 2) * 36,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    accent.withValues(alpha: .08),
                    LumeTheme.surface,
                  )
                : LumeTheme.surface,
            borderRadius: SourceCardMetrics.borderRadius,
            border: Border.all(
              color: selected ? accent : SourceCardMetrics.unselectedBorder,
            ),
            boxShadow: SourceCardMetrics.shadow,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: SourceCardMetrics.borderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('video-picker-source-$id'),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, right: 2),
                child: Row(
                  children: [
                    if (descriptor != null) ...[
                      SourceIcon(
                        name: name,
                        siteUrl: descriptor.siteUrl,
                        iconUrl: descriptor.iconUrl,
                        size: 28,
                        radius: 7,
                        section: Section.video,
                        sourceId: descriptor.id,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: LumeTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.15,
                              color: selected ? accent : LumeTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '$name的设置',
                      onPressed: onMore,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const LumeIcon(
                        Icons.more_vert,
                        size: 18,
                        slot: 'video_source_picker.more',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget grid(List<Widget> cards) => LayoutBuilder(
    builder: (context, constraints) {
      final single =
          constraints.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      return Column(
        children: [
          for (var i = 0; i < cards.length; i += single ? 1 : 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[i]),
                  if (!single) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: i + 1 < cards.length
                          ? cards[i + 1]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
        ],
      );
    },
  );

  Widget heading(String title, int count, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Text('$count', style: TextStyle(fontSize: 12, color: LumeTheme.muted)),
        ?trailing,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ordinary = sources
        .where(
          (s) =>
              s.enabled &&
              SourceContentVisibility.instance.allows(Section.video, s) &&
              matches('${s.name} ${s.id} ${s.group}'),
        )
        .toList();
    final originalOrder = sources.map((s) => s.id).toList();
    ordinary.sort((a, b) {
      final pa = SourcePreferences.read(Section.video, a.id).pinned;
      final pb = SourcePreferences.read(Section.video, b.id).pinned;
      return pa != pb
          ? (pa ? -1 : 1)
          : SourceOrder.compare(Section.video, a.id, b.id, originalOrder);
    });
    final records = service.subscriptions.where((s) => s.enabled).toList();
    final groups = <(CatSubscription, List<CatSite>)>[];
    for (final record in records) {
      final sites = record.sites
          .where(
            (s) =>
                PrivacySettings.instance.allowsSource(s.id, s.name) &&
                matches('${record.name} ${s.name} ${s.key}'),
          )
          .toList();
      final order = record.sites.map((s) => s.id).toList();
      sites.sort((a, b) => SourceOrder.compare(Section.cat, a.id, b.id, order));
      if (sites.isNotEmpty || (record.sites.isEmpty && matches(record.name))) {
        groups.add((record, sites));
      }
    }
    final planned = [
      VideoSourceType.python,
      VideoSourceType.module,
      VideoSourceType.web,
    ].contains(type);
    final showOrdinary =
        type == VideoSourceType.all || type == VideoSourceType.ordinary;
    final showCat = type == VideoSourceType.all || type == VideoSourceType.cat;
    final empty =
        (!showOrdinary || ordinary.isEmpty) && (!showCat || groups.isEmpty);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: LumeTheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: DrawerGeometry.height(context),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '选择视频源',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '添加视频源',
                          onPressed: add,
                          icon: const LumeIcon(
                            Icons.add,
                            slot: 'video_source_picker.add_button',
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const LumeIcon(
                            Icons.close,
                            slot: 'video_source_picker.close',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: TextField(
                      onChanged: (value) =>
                          setState(() => query = value.trim().toLowerCase()),
                      decoration: const InputDecoration(
                        hintText: '搜索源名称或订阅包',
                        prefixIcon: LumeIcon(
                          Icons.search,
                          slot: 'video_source_picker.search',
                        ),
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final item in VideoSourceType.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('video-source-type-${item.name}'),
                              label: Text(item.label),
                              selected: type == item,
                              showCheckmark: false,
                              onSelected: (_) => setState(() => type = item),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : error != null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('源列表加载失败'),
                                  TextButton(
                                    onPressed: load,
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              children: [
                                if (planned)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 48,
                                      horizontal: 20,
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          '${type.label}源尚未接入',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          switch (type) {
                                            VideoSourceType.python => '正在规划 Python 运行环境；本版可继续使用普通视频源和猫源。',
                                            VideoSourceType.module =>
                                              '后续接入兼容模块后，会在这里显示可用的源。',
                                            _ => '后续可从这里打开添加的网页主页。',
                                          },
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: LumeTheme.muted,
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (!planned && empty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 48,
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          query.isEmpty ? '还没有可用的源' : '没有匹配的源',
                                        ),
                                        if (query.isEmpty)
                                          TextButton(
                                            onPressed: add,
                                            child: const Text('添加源'),
                                          ),
                                      ],
                                    ),
                                  ),
                                if (showOrdinary && ordinary.isNotEmpty) ...[
                                  heading('普通视频源', ordinary.length),
                                  grid([
                                    for (final s in ordinary)
                                      SourceDragTile(
                                        key: ValueKey(
                                          'video-picker-drag-${s.id}',
                                        ),
                                        id: s.id,
                                        name: s.name,
                                        accepts: (id) =>
                                            ordinary.any((s) => s.id == id),
                                        onMove: (from, to) async {
                                          final ids = ordinary
                                              .map((s) => s.id)
                                              .toList();
                                          await SourceOrder.move(
                                            Section.video,
                                            originalOrder,
                                            ids,
                                            ids.indexOf(from),
                                            ids.indexOf(to),
                                          );
                                          changed();
                                        },
                                        child: card(
                                          id: s.id,
                                          name: s.name,
                                          subtitle:
                                              !widget.showingCat &&
                                                  currentId == s.id
                                              ? '当前使用'
                                              : 'JS · ${s.version}',
                                          descriptor: s,
                                          selected:
                                              !widget.showingCat &&
                                              currentId == s.id,
                                          onTap: () => Navigator.pop(
                                            context,
                                            VideoSourceChoice.ordinary(s.id),
                                          ),
                                          onMore: () => edit(
                                            Section.video,
                                            s.id,
                                            s.name,
                                            s.siteUrl,
                                          ),
                                        ),
                                      ),
                                  ]),
                                ],
                                if (showCat)
                                  for (final (record, sites) in groups) ...[
                                    heading(
                                      record.name,
                                      sites.length,
                                      trailing: IconButton(
                                        tooltip: '刷新${record.name}站点',
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        icon: busy.contains(record.id)
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const LumeIcon(
                                                Icons.refresh,
                                                size: 20,
                                                slot: 'video_source_picker.refresh',
                                              ),
                                      ),
                                    ),
                                    if (sites.isEmpty)
                                      TextButton(
                                        onPressed: busy.contains(record.id)
                                            ? null
                                            : () => refresh(record),
                                        child: const Text('加载包内站点'),
                                      ),
                                    grid([
                                      for (final s in sites)
                                        SourceDragTile(
                                          key: ValueKey(
                                            'video-picker-drag-${s.id}',
                                          ),
                                          id: s.id,
                                          name: s.name,
                                          accepts: (id) =>
                                              sites.any((s) => s.id == id),
                                          onMove: (from, to) async {
                                            final ids = sites
                                                .map((s) => s.id)
                                                .toList();
                                            await SourceOrder.move(
                                              Section.cat,
                                              record.sites
                                                  .map((s) => s.id)
                                                  .toList(),
                                              ids,
                                              ids.indexOf(from),
                                              ids.indexOf(to),
                                            );
                                            changed();
                                          },
                                          child: card(
                                            id: s.id,
                                            name: s.name,
                                            subtitle:
                                                widget.currentCatId == s.id
                                                ? '当前使用'
                                                : '猫源',
                                            selected:
                                                widget.currentCatId == s.id,
                                            onTap: () => Navigator.pop(
                                              context,
                                              VideoSourceChoice.cat(s),
                                            ),
                                            onMore: () => edit(
                                              Section.cat,
                                              s.id,
                                              s.name,
                                              s.siteUrl,
                                            ),
                                          ),
                                        ),
                                    ]),
                                  ],
                              ],
                            ),
                    ),
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
