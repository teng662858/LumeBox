import 'package:flutter/material.dart';

import '../../core/net/source_subscription.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/source/total_subscription.dart';
import '../../shared/widgets/native_glass_surfaces.dart';
import '../settings/settings_ui.dart';

/// Entry in source management for installing subscriptions from a selected route.
class TotalSubscriptionImportEntry extends StatefulWidget {
  const TotalSubscriptionImportEntry({
    super.key,
    this.managerFactory,
    this.fetchSubscription,
  });
  final SourceManager Function(Section)? managerFactory;
  final Future<SourceFetchResult> Function(String)? fetchSubscription;
  @override
  State<TotalSubscriptionImportEntry> createState() =>
      _TotalSubscriptionImportEntryState();
}

class _TotalSubscriptionImportEntryState
    extends State<TotalSubscriptionImportEntry> {
  Map<Section, SourceManager>? _createdManagers;
  Map<Section, SourceManager> get _managers => _createdManagers ??= {
    for (final section in Section.values)
      section: (widget.managerFactory ?? LumeSources.manager)(section),
  };
  bool _maintaining = false;

  @override
  void dispose() {
    for (final manager in _createdManagers?.values ?? <SourceManager>[]) {
      manager.close();
    }
    super.dispose();
  }

  Future<void> _importAllSubscriptions() async {
    final route = await showGlassDialog<SubscriptionRoute>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择总订阅线路'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text('选择一条线路，自动导入全部订阅源。'),
          ),
          for (final route in SubscriptionCatalog.availableRoutes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, route),
              child: Text(route.label),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (route == null || !mounted || _maintaining) return;
    final service = TotalSubscriptionService(
      managers: _managers,
      fetch: widget.fetchSubscription,
    );
    TotalSubscription? total;
    var restore = <Section, Set<String>>{};
    Map<Section, SubscriptionSyncResult>? retry;
    Map<Section, SubscriptionSyncResult>? lastReport;
    while (true) {
      if (!mounted) return;
      setState(() => _maintaining = true);
      final phase = ValueNotifier<String>(
        total == null ? '正在下载总订阅清单…' : '正在处理订阅…',
      );
      final dialog = showGlassDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在导入订阅源'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: phase,
                  builder: (_, text, _) => Text(text),
                ),
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                for (final section in SubscriptionCatalog.sections)
                  ValueListenableBuilder<String>(
                    valueListenable: SourceSubscriptionSync.progress(section),
                    builder: (_, text, _) => text.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('${section.label}：$text'),
                          ),
                  ),
              ],
            ),
          ),
        ),
      );
      Map<Section, SubscriptionSyncResult>? results;
      String? failure;
      try {
        total ??= await service.read(SubscriptionCatalog.totalFor(route));
        phase.value = '正在下载、校验并安装各板块的源…';
        results = retry != null
            ? await service.retryFailed(total, retry)
            : restore.isEmpty
            ? await service.import(total, installAll: true)
            : await service.restoreExcluded(total, restore);
        if (lastReport != null) {
          for (final previous in lastReport.entries) {
            final current = results[previous.key];
            if (current == null) {
              results[previous.key] = previous.value;
            } else {
              for (final excluded in previous.value.excluded.entries) {
                if (!(restore[previous.key]?.contains(excluded.key) ?? false)) {
                  current.excluded.putIfAbsent(
                    excluded.key,
                    () => excluded.value,
                  );
                }
              }
            }
          }
        }
      } catch (error) {
        failure = '导入失败：$error';
      } finally {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        await dialog;
        phase.dispose();
        if (mounted) setState(() => _maintaining = false);
      }
      if (!mounted) return;
      if (failure != null) {
        final retry = await showGlassDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导入未完成'),
            content: Text(failure!),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重试'),
              ),
            ],
          ),
        );
        if (retry != true) return;
        restore = {};
        continue;
      }
      lastReport = results;
      final selected = <Section, Set<String>>{};
      final action = await showGlassDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('订阅导入结果'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in results!.entries) ...[
                      Text('${entry.key.label}：${entry.value.summary}'),
                      if (entry.value.excluded.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('之前手动移除，勾选后可恢复：'),
                        ),
                        for (final source in entry.value.excluded.entries)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(source.value),
                            subtitle: Text(source.key),
                            value:
                                selected[entry.key]?.contains(source.key) ??
                                false,
                            onChanged: (value) => update(() {
                              final ids = selected.putIfAbsent(
                                entry.key,
                                () => <String>{},
                              );
                              if (value == true) {
                                ids.add(source.key);
                              } else {
                                ids.remove(source.key);
                              }
                            }),
                          ),
                      ],
                      if (entry.value.errors.isNotEmpty)
                        ExpansionTile(
                          title: Text('查看 ${entry.value.errors.length} 条失败原因'),
                          children: [
                            for (final error in entry.value.errors)
                              ListTile(title: SelectableText(error)),
                          ],
                        ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'close'),
                child: const Text('关闭'),
              ),
              if (results.values.any((result) => result.errors.isNotEmpty))
                TextButton(
                  onPressed: () => Navigator.pop(context, 'retry'),
                  child: const Text('重试未完成项'),
                ),
              if (selected.values.any((ids) => ids.isNotEmpty))
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'restore'),
                  child: const Text('恢复选中源'),
                ),
            ],
          ),
        ),
      );
      if (action == 'restore') {
        restore = selected;
        retry = null;
      } else if (action == 'retry') {
        restore = {};
        retry = results;
      } else {
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => SettingsEntryCard(
    icon: Icons.playlist_add,
    title: '一键导入全部订阅源',
    subtitle: '选择线路，安装各板块的订阅源',
    onTap: _maintaining ? null : _importAllSubscriptions,
  );
}
