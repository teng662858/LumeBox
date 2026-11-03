import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/source/source_duplicates.dart';
import '../../shared/widgets/glass_card.dart';

class SourceDuplicatesPage extends StatefulWidget {
  const SourceDuplicatesPage({super.key, required this.manager});
  final SourceManager manager;
  @override
  State<SourceDuplicatesPage> createState() => _SourceDuplicatesPageState();
}

class _SourceDuplicatesPageState extends State<SourceDuplicatesPage> {
  List<SourceDuplicateGroup>? groups;
  String? error;
  int failed = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final sources = await widget.manager.list();
      final scripts = <String, String>{};
      for (final source in sources) {
        if (!mounted) return;
        try {
          final value = await widget.manager.exportScript(source.id);
          if (value != null) {
            scripts[source.id] = value;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (mounted) {
        setState(() => groups = findSourceDuplicates(sources, scripts));
      }
    } catch (_) {
      if (mounted) setState(() => error = '读取源失败，请返回后重试');
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '重复源检查',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('仅比较本机脚本和站点域名，不联网、不自动删除。确认后请返回源管理选择停用或删除。'),
        if (error != null) Text(error!),
        if (groups == null && error == null) const LinearProgressIndicator(),
        if (failed > 0) Text('$failed 个脚本读取失败，未参与内容比较'),
        if (groups?.isEmpty == true)
          const ListTile(title: Text('没有发现相同脚本或同域名源')),
        for (final group in groups ?? <SourceDuplicateGroup>[])
          Card(
            child: ExpansionTile(
              title: Text(group.reason),
              subtitle: Text('${group.sources.length} 个源'),
              children: [
                for (final source in group.sources)
                  ListTile(
                    title: Text(source.name),
                    subtitle: Text(
                      '${source.id} · ${source.version} · ${source.enabled ? '已启用' : '已停用'}',
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
