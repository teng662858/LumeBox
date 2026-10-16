import '../../core/source/source_picker_groups.dart';
import '../../core/cache/section_memory_cache.dart';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source_preferences.dart';
import '../../shared/widgets/glass_card.dart';

class SourcePreferencesPage extends StatefulWidget {
  const SourcePreferencesPage({
    super.key,
    required this.section,
    required this.sourceId,
    required this.name,
    this.siteUrl = '',
    this.onNetwork,
    this.showChapterOrder,
  });
  final Section section;
  final String sourceId, name, siteUrl;
  final Future<void> Function()? onNetwork;
  final bool? showChapterOrder;
  @override
  State<SourcePreferencesPage> createState() => _SourcePreferencesPageState();
}

class _SourcePreferencesPageState extends State<SourcePreferencesPage> {
  late SourcePreferences prefs = SourcePreferences.read(
    widget.section,
    widget.sourceId,
  );
  late final icon = TextEditingController(text: prefs.iconUrl);
  late final original = TextEditingController(
    text: prefs.originalOrigin.isEmpty ? widget.siteUrl : prefs.originalOrigin,
  );
  late final custom = TextEditingController(text: prefs.customOrigin);
  String? error;
  @override
  void dispose() {
    icon.dispose();
    original.dispose();
    custom.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final domain = custom.text.trim(),
        from = original.text.trim(),
        url = icon.text.trim();
    if (domain.isNotEmpty &&
        (!SourcePreferences.validOrigin(domain) ||
            !SourcePreferences.validOrigin(from))) {
      setState(() => error = '请填写完整站点地址，如 https://example.com，不含路径或账号密码');
      return;
    }
    if (url.isNotEmpty) {
      final u = Uri.tryParse(url);
      if (u == null ||
          u.scheme != 'https' ||
          u.host.isEmpty ||
          u.userInfo.isNotEmpty) {
        setState(() => error = '图标请使用不含账号密码的 HTTPS 图片地址');
        return;
      }
    }
    await prefs
        .copyWith(iconUrl: url, originalOrigin: from, customOrigin: domain)
        .save(widget.section, widget.sourceId);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(effectModule: GlassModule.sources,
    title: '${widget.name} · 源设置',
    actions: [TextButton(onPressed: save, child: const Text('保存'))],
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.section != Section.cat)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('源抽屉分类'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final group in [
                      ('', '自动'),
                      ...SourcePickerGroups.forSection(widget.section),
                    ])
                      ChoiceChip(
                        label: Text(group.$2),
                        selected: prefs.pickerGroup == group.$1,
                        onSelected: (_) => setState(
                          () => prefs = prefs.copyWith(pickerGroup: group.$1),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

        GlassCard(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('置顶此源'),
                value: prefs.pinned,
                onChanged: (v) =>
                    setState(() => prefs = prefs.copyWith(pinned: v)),
              ),
              if (widget.showChapterOrder ??
                  (widget.section == Section.novel ||
                      widget.section == Section.comic))
                SwitchListTile(
                  title: const Text('新章节在前'),
                  subtitle: const Text('只改变目录的展示顺序'),
                  value: prefs.newestFirst,
                  onChanged: (v) =>
                      setState(() => prefs = prefs.copyWith(newestFirst: v)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              TextField(
                controller: icon,
                decoration: const InputDecoration(
                  labelText: '自定义源图标',
                  hintText: '留空使用站点图标',
                ),
              ),
              if (widget.section != Section.cat)
                TextField(
                  controller: original,
                  decoration: const InputDecoration(labelText: '原站点地址'),
                ),
              if (widget.section != Section.cat)
                TextField(
                  controller: custom,
                  decoration: const InputDecoration(
                    labelText: '自定义站点地址',
                    hintText: '留空沿用源脚本',
                  ),
                ),
              if (widget.section != Section.cat)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('地址替换只作用于这个站点；独立图床与播放 CDN 保持原地址。'),
                ),
            ],
          ),
        ),
        if (widget.onNetwork != null)
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(
              widget.section == Section.cat
                  ? '站点设置与账号配置'
                  : '源设置（网络 / 换网址 / 账号）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onNetwork,
          ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('清理此源的浏览缓存'),
          subtitle: const Text('保留下载内容、书架与阅读进度'),
          onTap: () {
            final count = SectionMemoryCache.instance.removeSource(
              widget.section,
              widget.sourceId,
            );
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('已清理 $count 条浏览缓存')));
          },
        ),
        if (widget.siteUrl.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('复制站点地址'),
            onTap: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: custom.text.trim().isEmpty
                      ? widget.siteUrl
                      : custom.text.trim(),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('站点地址已复制')));
              }
            },
          ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('恢复默认源设置'),
          onTap: () {
            setState(() {
              prefs = const SourcePreferences();
              icon.clear();
              custom.clear();
              original.text = widget.siteUrl;
              error = null;
            });
          },
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
      ],
    ),
  );
}
