import 'package:flutter/material.dart';

import '../../core/search/search_settings.dart';
import '../../shared/widgets/glass_card.dart';

class SearchSettingsPage extends StatelessWidget {
  const SearchSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '搜索',
    child: ListenableBuilder(
      listenable: SearchSettings.instance,
      builder: (context, _) => ListView(
        children: [
          SwitchListTile.adaptive(
            title: const Text('搜索自动繁转简'),
            subtitle: const Text('搜索关键词和标题匹配统一转为简体'),
            value: SearchSettings.instance.simplify,
            onChanged: (value) =>
                SearchSettings.instance.update(simplify: value),
          ),
          SwitchListTile.adaptive(
            title: const Text('精确搜索'),
            subtitle: const Text('只显示标题与完整关键词相同的结果（忽略大小写）'),
            value: SearchSettings.instance.exact,
            onChanged: (value) => SearchSettings.instance.update(exact: value),
          ),
        ],
      ),
    ),
  );
}
