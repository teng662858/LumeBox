import '../../core/session/section.dart';
import '../../core/source/source_picker_groups.dart';

import 'package:flutter/material.dart';

import '../../core/source/source_content_visibility.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

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
            const SettingsFooterNote(
              '开关仅控制首页源选择抽屉中的分类显示。源和已有数据保留，可随时重新显示。',
              padding: EdgeInsets.only(bottom: 12),
            ),
            for (final section in [Section.comic, Section.video]) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '${section.label}板块',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final entry in SourcePickerGroups.forSection(
                section,
              ).where((entry) => entry.$1 != 'tvbox'))
                SwitchListTile(
                  key: ValueKey('content-visible-${entry.$1}'),
                  title: Text(entry.$2),
                  subtitle: Text(
                    SourceContentVisibility.types
                        .firstWhere((type) => type.$1 == entry.$1)
                        .$3,
                  ),
                  value: settings.isVisible(entry.$1),
                  onChanged: (value) => settings.setVisible(entry.$1, value),
                ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '视频源类型',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final id in const [
              'js',
              'python',
              'tvbox',
              'module',
              'cat',
              'web',
            ])
              Builder(
                builder: (context) {
                  final entry = SourceContentVisibility.types.firstWhere(
                    (type) => type.$1 == id,
                  );
                  return SwitchListTile(
                    key: ValueKey('content-visible-$id'),
                    title: Text(entry.$2),
                    subtitle: Text(entry.$3),
                    value: settings.isVisible(id),
                    onChanged: (value) => settings.setVisible(id, value),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
