import 'package:flutter/material.dart';

import '../../shared/widgets/glass_card.dart';

import '../../core/cat/cat_service.dart';
import '../../core/session/section.dart';
import '../../core/source/source_subscription_sync.dart';

/// Manual refresh does not use the six-hour automatic-update cooldown.
class SubscriptionSyncPage extends StatefulWidget {
  const SubscriptionSyncPage({super.key, this.section});
  final Section? section;
  @override
  State<SubscriptionSyncPage> createState() => _SubscriptionSyncPageState();
}

class _SubscriptionSyncPageState extends State<SubscriptionSyncPage> {
  bool busy = false;
  String current = '';
  final results = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  Future<void> run() async {
    if (busy) return;
    var failures = 0;
    setState(() {
      busy = true;
      results.clear();
    });
    try {
      for (final section
          in widget.section == null
              ? [Section.comic, Section.video]
              : [widget.section!]) {
        if (mounted) setState(() => current = '正在同步${section.label}订阅…');
        final result = await SourceSubscriptionSync.refresh(
          section,
          force: true,
        );
        results.add('${section.label}：${result.summary}');
        results.addAll(result.errors);
        failures += result.errors.length;
        if (mounted) setState(() {});
      }
      if (widget.section == null) {
        final cats = CatService.instance;
        await cats.boot();
        for (final subscription
            in cats.subscriptions
                .where((s) => s.enabled && !s.isLocal)
                .toList()) {
          if (mounted) setState(() => current = '正在同步猫源：${subscription.name}…');
          try {
            await cats.update(subscription);
            if (mounted) {
              setState(() => results.add('猫源 ${subscription.name}：已同步'));
            }
          } catch (error) {
            failures++;
            if (mounted) {
              setState(
                () => results.add('猫源 ${subscription.name}：同步失败，保留原包。$error'),
              );
            }
          }
        }
      }
    } catch (error) {
      failures++;
      if (mounted) setState(() => results.add('同步未完成：$error'));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          current = failures == 0 ? '订阅检查完成' : '部分订阅未同步成功，请查看下方原因';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: widget.section == null ? '一键同步全部订阅' : '同步${widget.section!.label}订阅',
    child: SettingsSurfaceList(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('立即更新已启用的订阅。单个订阅失败时保留原内容并继续其他订阅；本地手动源、收藏和历史会保留。'),
        const SizedBox(height: 16),
        Text(current),
        if (busy)
          for (final section in [Section.comic, Section.video])
            ValueListenableBuilder<String>(
              valueListenable: SourceSubscriptionSync.progress(section),
              builder: (_, text, child) => text.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${section.label}：$text'),
                    ),
            ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        for (final result in results)
          ListTile(dense: true, title: Text(result)),
        FilledButton.icon(
          onPressed: busy ? null : run,
          icon: const Icon(Icons.sync),
          label: const Text('重新同步'),
        ),
      ],
    ),
  );
}
