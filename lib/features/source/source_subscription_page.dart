import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/net/source_subscription.dart';
import '../../core/source/source.dart';
import '../../core/source/source_subscription_sync.dart';
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

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      final result = await SourceSubscriptionSync.refresh(
        widget.section,
        force: true,
        manager: widget.manager,
        fetch: widget.fetchSubscription,
      );
      if (!mounted) return;
      setState(() => _syncStatus = result.summary);
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
        saved.enabled = enabled!;
      }
    }
    await service.save();
    if (mounted) setState(() => _service = service);
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
          FilledButton.icon(
            onPressed: _busy ? null : _sync,
            icon: const LumeIcon(
              Icons.system_update_alt,
              slot: 'source_subscription_page.2',
            ),
            label: const Text('一键更新全部订阅'),
          ),
          const Text(
            '订阅地址保存后，启动、回到前台和进入板块时会自动检查。正常间隔 6 小时，失败后 30 分钟可重试。同步新增、更新和移除，保留手动导入的源。',
          ),
          const SizedBox(height: 16),
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
            child: const Text('添加订阅并导入'),
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
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
