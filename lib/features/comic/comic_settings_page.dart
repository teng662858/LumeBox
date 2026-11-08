import 'package:flutter/material.dart';

import '../../shared/widgets/glass_card.dart';
import '../settings/settings_ui.dart';
import '../settings/global_translation_settings_page.dart';
import 'comic_reader_settings_host.dart';
import 'comic_image_tools_page.dart';

/// All global comic preferences share one route and the original stores.
class ComicSettingsPage extends StatefulWidget {
  const ComicSettingsPage({super.key, this.initialTab = 'reading'});
  final String initialTab;
  @override
  State<ComicSettingsPage> createState() => _ComicSettingsPageState();
}

class _ComicSettingsPageState extends State<ComicSettingsPage> {
  late String selected = widget.initialTab;
  void select(String id) => setState(() => selected = id);
  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '漫画设置',
    settingsSurface: true,
    child: Column(
      children: [
        SettingsTabBar(
          tabs: const [
            ('reading', '阅读'),
            ('images', '图片工具'),
            ('translation', '漫画翻译'),
          ],
          selected: selected,
          onSelected: select,
        ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(selected),
            child: switch (selected) {
              'images' => const ComicImageToolsSettingsPage(embedded: true),
              'translation' => const GlobalTranslationSettingsPage(
                embedded: true,
              ),
              _ => ComicReaderSettingsHost(
                embedded: true,
                onOpenImageSettings: (translation) =>
                    select(translation ? 'translation' : 'images'),
              ),
            },
          ),
        ),
      ],
    ),
  );
}
