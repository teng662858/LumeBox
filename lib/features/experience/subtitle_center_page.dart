import '../../shared/widgets/glass_card.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/experience/subtitle_service.dart';
import '../../core/experience/content_center.dart';
import '../../core/player/text_subtitles.dart';

class SubtitleCenterPage extends StatefulWidget {
  const SubtitleCenterPage({super.key, this.title = ''});
  final String title;
  @override
  State<SubtitleCenterPage> createState() => _SubtitleCenterPageState();
}

class _SubtitleCenterPageState extends State<SubtitleCenterPage> {
  late final query = TextEditingController(text: widget.title);
  late final language = TextEditingController(
    text: '${ContentCenter.instance.data['subtitleLanguage'] ?? 'zh-cn,en'}',
  );
  List<SubtitleResult> results = [];
  bool busy = false;
  String status = '';
  SubtitleService? service;
  @override
  void dispose() {
    query.dispose();
    language.dispose();
    service?.close();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => status = '操作失败：检查账户、网络、额度或文件格式');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> configure() async {
    final account = await SubtitleAccount.load();
    final key = TextEditingController(text: account.apiKey),
        token = TextEditingController(text: account.token);
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OpenSubtitles 授权'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: key,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            TextField(
              controller: token,
              obscureText: true,
              decoration: const InputDecoration(labelText: '用户 Bearer Token'),
            ),
            const Text('仅向 OpenSubtitles 官方接口发送。下载额度由账户决定。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await SubtitleAccount(key.text.trim(), token.text.trim()).save();
    }
    Future<void>.delayed(const Duration(seconds: 1), () {
      key.dispose();
      token.dispose();
    });
  }

  Future<void> merge() async {
    const group = XTypeGroup(label: '字幕', extensions: ['srt', 'vtt']);
    final files = await openFiles(acceptedTypeGroups: [group]);
    if (files.length != 2) throw StateError('请选择两个字幕文件');
    final first = await TextSubtitles.load(files.first.path),
        second = await TextSubtitles.load(files.last.path);
    if (first == null || second == null) throw StateError('无法解析字幕');
    final file = File(
      '${(await getTemporaryDirectory()).path}/lumebox-bilingual.srt',
    );
    await file.writeAsString(
      SubtitleService.bilingual(first, second),
      flush: true,
    );
    if (!mounted) return;
    Navigator.pop(context, file.path);
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.video,
    settingsSurface: true,
    title: '字幕中心',
    actions: [
      IconButton(
        onPressed: () => run(configure),
        icon: const Icon(Icons.key_outlined),
      ),
    ],
    child: SettingsSurfaceList(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: query,
          decoration: const InputDecoration(labelText: '作品名称／文件名称'),
        ),
        TextField(
          controller: language,
          decoration: const InputDecoration(labelText: '语言优先级，例如 zh-cn,en'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () => run(() async {
                  ContentCenter.instance.put(
                    'subtitleLanguage',
                    language.text.trim(),
                  );
                  service?.close();
                  service = SubtitleService(await SubtitleAccount.load());
                  results = await service!.search(
                    query.text.trim(),
                    language.text.trim(),
                  );
                  if (mounted) {
                    setState(() => status = '找到 ${results.length} 个字幕文件');
                  }
                }),
          child: const Text('搜索字幕'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : () => run(merge),
          icon: const Icon(Icons.subtitles_outlined),
          label: const Text('选择两个本地字幕合成双语'),
        ),
        if (busy) const LinearProgressIndicator(),
        Text(status),
        for (final result in results)
          ListTile(
            title: Text(result.name),
            subtitle: Text(result.language),
            trailing: const Icon(Icons.download),
            onTap: busy
                ? null
                : () => run(() async {
                    final file = await service!.download(result.id);
                    if (context.mounted) Navigator.pop(context, file.path);
                  }),
          ),
      ],
    ),
  );
}
