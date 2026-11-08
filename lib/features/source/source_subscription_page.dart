import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/net/source_subscription.dart';
import '../../core/source/source.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/source/source_subscription_catalog.dart';
import '../../shared/widgets/glass_card.dart';

class SourceSubscriptionPage extends StatefulWidget {
  const SourceSubscriptionPage({
    super.key,
    required this.section,
    this.manager,
    this.fetchSubscription,
    this.extraActions = const [],
  });
  final Section section;
  final SourceManager? manager;
  final Future<SourceFetchResult> Function(String url)? fetchSubscription;
  final List<Widget> extraActions;
  @override
  State<SourceSubscriptionPage> createState() => _SourceSubscriptionPageState();
}

class _SourceSubscriptionPageState extends State<SourceSubscriptionPage> {
  SourceSubscriptionSync? _service;
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _syncStatus;
  List<String> _syncErrors = [];
  bool _mixedSubscription = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await SourceSubscriptionSync.waitForIdle(widget.section);
      final service = await SourceSubscriptionSync.open(
        widget.section,
        manager: widget.manager,
      );
      if (mounted) setState(() => _service = service);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _add() async {
    final service = _service;
    if (service == null || _url.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SourceSubscriptionSync.remember(widget.section, [
        _url.text,
      ], manager: widget.manager);
      _url.clear();
      await _sync();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addOfficial(SubscriptionRoute route) async {
    if (_service == null || _busy) return;
    final url = _mixedSubscription && widget.section == Section.video
        ? SubscriptionCatalog.mixedFor(route)
        : SubscriptionCatalog.sectionUrl(widget.section, route: route);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SourceSubscriptionSync.remember(widget.section, [
        url,
      ], manager: widget.manager);
      await _sync();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _error = null;
      _syncErrors = [];
    });
    try {
      final result = await SourceSubscriptionSync.refresh(
        widget.section,
        force: true,
        manager: widget.manager,
        fetch: widget.fetchSubscription,
      );
      if (!mounted) return;
      setState(() {
        _syncStatus = result.summary;
        _syncErrors = List.of(result.errors);
      });
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(
    SavedSourceSubscription record, {
    bool? enabled,
    bool? autoInstallNew,
    bool remove = false,
  }) async {
    await SourceSubscriptionSync.waitForIdle(widget.section);
    final service = await SourceSubscriptionSync.open(
      widget.section,
      manager: widget.manager,
    );
    if (remove) {
      service.subscriptions.removeWhere((s) => s.url == record.url);
    } else {
      for (final saved in service.subscriptions.where(
        (s) => s.url == record.url,
      )) {
        if (enabled != null) saved.enabled = enabled;
        if (autoInstallNew != null) saved.autoInstallNew = autoInstallNew;
      }
    }
    await service.save();
    if (mounted) setState(() => _service = service);
  }

  Future<void> _choosePending(SavedSourceSubscription record) async {
    final selected = <String>{};
    final install = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('选择安装 · ${record.pending.length} 个源'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                CheckboxListTile(
                  title: const Text('全选'),
                  value: selected.length == record.pending.length,
                  onChanged: (value) => update(() {
                    selected.clear();
                    if (value == true) selected.addAll(record.pending.keys);
                  }),
                ),
                for (final entry in record.pending.entries)
                  CheckboxListTile(
                    title: Text(entry.value),
                    subtitle: Text(
                      entry.key,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: selected.contains(entry.key),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                selected.addAll(record.pending.keys);
                Navigator.pop(context, true);
              },
              child: const Text('全部导入'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text('安装 ${selected.length} 个'),
            ),
          ],
        ),
      ),
    );
    if (install != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await SourceSubscriptionSync.waitForIdle(widget.section);
      final service = await SourceSubscriptionSync.open(
        widget.section,
        manager: widget.manager,
      );
      final saved = service.subscriptions
          .where((s) => s.url == record.url)
          .firstOrNull;
      if (saved == null) return;
      saved.approvedUrls.addAll(selected.where(saved.pending.containsKey));
      saved.checkedAt = null;
      await service.save();
      await _sync();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return GlassScaffold(
      effectModule: GlassModule.sources,
      title: '${widget.section.label} · 订阅管理',
      actions: widget.extraActions,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ValueListenableBuilder<int>(
            valueListenable: SourceSubscriptionSync.changeCount(widget.section),
            builder: (_, count, _) => count == 0
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const LumeIcon(
                      Icons.notifications_active_outlined,
                      slot: 'source_subscription_page.1',
                    ),
                    title: Text('订阅源已变动 $count 条'),
                    subtitle: Text(
                      SourceSubscriptionSync.notices(widget.section)
                          .map(
                            (entry) => '${entry['name']} · ${entry['status']}',
                          )
                          .join('\n'),
                    ),
                    trailing: TextButton(
                      onPressed: () =>
                          SourceSubscriptionSync.changeCount(widget.section)
                                  .value =
                              0,
                      child: const Text('知道了'),
                    ),
                  ),
          ),
          if (_syncStatus != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_syncStatus!),
            ),
          for (final failure in _syncErrors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText(failure),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _sync,
            icon: const LumeIcon(
              Icons.system_update_alt,
              slot: 'source_subscription_page.2',
            ),
            label: const Text('一键更新全部订阅'),
          ),
          const Text(
            '订阅自动检查已安装源的更新和移除。新发现的源进入待安装列表，勾选后才安装。正常间隔 6 小时，失败后 30 分钟可重试。保留手动导入的源。',
          ),
          const SizedBox(height: 16),
          if (widget.section == Section.comic ||
              widget.section == Section.video) ...[
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '官方订阅',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '选择分类和线路后立即添加并检查可安装的源。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (widget.section == Section.video) ...[
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('全部视频订阅'),
                          selected: !_mixedSubscription,
                          onSelected: _busy
                              ? null
                              : (_) =>
                                    setState(() => _mixedSubscription = false),
                        ),
                        ChoiceChip(
                          label: const Text('综合源订阅'),
                          selected: _mixedSubscription,
                          onSelected: _busy
                              ? null
                              : (_) =>
                                    setState(() => _mixedSubscription = true),
                        ),
                      ],
                    ),
                    if (_mixedSubscription)
                      const Text('综合源包含多种内容；成人内容仍受隐私设置控制。'),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final route in SubscriptionCatalog.availableRoutes)
                        ActionChip(
                          label: Text(route.label),
                          onPressed: _busy || service == null
                              ? null
                              : () => _addOfficial(route),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          const Text('自定义订阅', style: TextStyle(fontWeight: FontWeight.w600)),
          TextField(
            controller: _url,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '添加订阅地址',
              hintText: 'https://…/sources.txt',
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _add,
            child: const Text('添加订阅并检查可安装源'),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          if (service == null)
            const Center(child: CircularProgressIndicator())
          else if (service.subscriptions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('暂无订阅。添加一次后不必重复填写。'),
            )
          else
            for (final record in service.subscriptions)
              Card(
                child: Column(
                  children: [
                    if (record.pending.isNotEmpty)
                      ListTile(
                        title: Text('${record.pending.length} 个新源待选择安装'),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _choosePending(record),
                          child: const Text('选择安装'),
                        ),
                      ),
                    SwitchListTile(
                      title: Text(
                        record.url,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.bodySize,
                        ),
                      ),
                      subtitle: Text(
                        record.error.isNotEmpty
                            ? record.error
                            : record.checkedAt == null
                            ? '已保存 · ${record.enabled ? '自动更新开启' : '自动更新关闭'} · 尚未同步'
                            : '上次同步：${record.checkedAt!.toLocal().toString().split('.').first}',
                      ),
                      secondary: const LumeIcon(
                        Icons.rss_feed,
                        slot: 'source_subscription_page.3',
                      ),
                      value: record.enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _change(record, enabled: value),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _change(record, remove: true),
                      child: const Text('取消订阅（保留已导入源）'),
                    ),
                    SwitchListTile(
                      title: const Text('自动安装此订阅的新源'),
                      subtitle: const Text('默认关闭；开启后新发现的源会直接安装'),
                      value: record.autoInstallNew,
                      onChanged: _busy
                          ? null
                          : (value) => _change(record, autoInstallNew: value),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
