import 'package:flutter/material.dart';

import '../../core/source/source_content_visibility.dart';
import '../../shared/widgets/glass_card.dart';

class ContentVisibilityPage extends StatelessWidget {
  const ContentVisibilityPage({super.key, this.controller});
  final SourceContentVisibility? controller;
  @override
  Widget build(BuildContext context) {
    final settings = controller ?? SourceContentVisibility.instance;
    return GlassScaffold(
      effectModule: GlassModule.settings,
      title: '内容分类显示',
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('开关仅控制首页源选择抽屉中的分类显示。源和已有数据保留，可随时重新显示。'),
            ),
            for (final type in SourceContentVisibility.types)
              SwitchListTile(
                key: ValueKey('content-visible-${type.$1}'),
                title: Text(type.$2),
                subtitle: Text(type.$3),
                value: settings.isVisible(type.$1),
                onChanged: (value) => settings.setVisible(type.$1, value),
              ),
          ],
        ),
      ),
    );
  }
}
