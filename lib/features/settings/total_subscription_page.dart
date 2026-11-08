import '../source/source_subscription_page.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/session/section.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/total_subscription.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';
import '../source/subscription_sync_report.dart';

class TotalSubscriptionPage extends StatefulWidget {
  const TotalSubscriptionPage({super.key, this.service});
  final TotalSubscriptionService? service;
  @override
  State<TotalSubscriptionPage> createState() => _TotalSubscriptionPageState();
}

class _TotalSubscriptionPageState extends State<TotalSubscriptionPage> {
  late final service = widget.service ?? TotalSubscriptionService();
  final input = TextEditingController(text: SubscriptionCatalog.totalUrl);
  bool busy = false;
  String? status;
  String? exported;
  Map<Section, SubscriptionSyncResult>? results;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = null;
      results = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => status = '未完成：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> import() async {
    final total = await service.read(input.text);
    if (!mounted) return;
    setState(() => busy = false);
    final yes = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入总订阅'),
        content: Text(
          '${total.entries.entries.map((entry) => '${entry.key.label}：${entry.value.length} 个订阅').join('\n')}\n\n按板块保存并检查。已有源正常更新，新源先进入待安装列表，请勾选后安装。保留其他订阅和手动导入的源。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    final imported = await service.import(total);
    if (mounted) {
      setState(() => results = imported);
    }
  }

  Future<void> selectFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '总订阅',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    input.text = await file.readAsString();
    await import();
  }

  Future<void> saveExport() async {
    final text = exported;
    if (text == null) return;
    final name =
        'LumeBox-total-subscription-${DateTime.now().millisecondsSinceEpoch}.json';
    if (Platform.isIOS || Platform.isAndroid) {
      final saved = await const MethodChannel('lumebox/configuration')
          .invokeMethod<bool>('export', {'text': text, 'name': name});
      if (mounted && saved == true) setState(() => status = '总订阅文件已导出');
    } else {
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      await XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'application/json',
      ).saveTo(location.path);
      if (mounted) setState(() => status = '总订阅文件已导出');
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '总订阅导入导出',
    child: SettingsSurfaceList(
      padding: const EdgeInsets.all(16),
      children: [
        if (results != null)
          for (final entry in results!.entries.where(
            (e) => e.value.pending > 0,
          ))
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SourceSubscriptionPage(
                    section: entry.key,
                    manager: service.managers[entry.key],
                    fetchSubscription: service.fetch,
                  ),
                ),
              ),
              child: Text(
                '${entry.key.label} · 选择安装 ${entry.value.pending} 个新源',
              ),
            ),
        if (busy)
          for (final section in [Section.comic, Section.video])
            SizedBox(
              child: ValueListenableBuilder<String>(
                valueListenable: SourceSubscriptionSync.progress(section),
                builder: (_, text, child) => text.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassCard(
                          padding: const EdgeInsets.all(12),
                          child: Text('${section.label}：$text'),
                        ),
                      ),
              ),
            ),
        const SettingsFooterNote(
          '自动分类并导入手机：漫画、美图、小说、有声归漫画板块；影视、视频归视频板块。猫源订阅仍在猫源配置中心管理。',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final route in SubscriptionCatalog.availableRoutes)
              ChoiceChip(
                label: Text(route.label),
                selected:
                    input.text.trim() == SubscriptionCatalog.totalFor(route),
                onSelected: busy
                    ? null
                    : (_) => setState(() {
                        input.text = SubscriptionCatalog.totalFor(route);
                      }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: !busy,
          controller: input,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '总订阅地址或 JSON',
            hintText: '粘贴总订阅地址或之前导出的总订阅内容',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : () => run(import),
          icon: const LumeIcon(
            Icons.download,
            slot: 'total_subscription_page.1',
          ),
          label: const Text('导入总订阅'),
        ),
        Wrap(
          spacing: 12,
          children: [
            TextButton(
              onPressed: busy ? null : () => run(selectFile),
              child: const Text('从文件导入'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (data != null) input.text = data.text ?? '';
                    }),
              child: const Text('粘贴剪贴板'),
            ),
          ],
        ),
        const Divider(height: 32),
        const SettingsFooterNote(
          '导出已保存的订阅地址及启用状态。不包含源脚本、账号、Cookie、收藏或历史；本地 JS 源可通过源总管理备份。',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => run(() async {
                  final text = (await service.export()).encode();
                  if (mounted) setState(() => exported = text);
                }),
          icon: const LumeIcon(
            Icons.upload_file,
            slot: 'total_subscription_page.2',
          ),
          label: const Text('生成总订阅导出'),
        ),
        if (exported != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(child: SelectableText(exported!)),
          ),
          Wrap(
            spacing: 12,
            children: [
              TextButton(
                onPressed: busy ? null : () => run(saveExport),
                child: const Text('导出文件'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: exported!));
                        if (mounted) setState(() => status = '总订阅已复制');
                      },
                child: const Text('复制总订阅'),
              ),
            ],
          ),
        ],
        if (busy) const LinearProgressIndicator(),
        if (results != null) SubscriptionSyncReport(results: results!),
        if (status != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(status!),
          ),
      ],
    ),
  );
}
