import 'package:flutter/material.dart';

import '../../shared/widgets/glass_card.dart';
import '../comic/comic_image_tools_page.dart';
import 'settings_ui.dart';
import 'translation_languages_page.dart';

/// Shared destination for translation preferences and system language packs.
class GlobalTranslationSettingsPage extends StatefulWidget {
  const GlobalTranslationSettingsPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<GlobalTranslationSettingsPage> createState() =>
      _GlobalTranslationSettingsPageState();
}

class _GlobalTranslationSettingsPageState
    extends State<GlobalTranslationSettingsPage> {
  String selected = 'settings';

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '全局翻译',
    effectModule: GlassModule.settings,
    embedded: widget.embedded,
    child: Column(
      children: [
        SettingsTabBar(
          tabs: const [('settings', '翻译设置'), ('languages', '语言包')],
          selected: selected,
          onSelected: (value) => setState(() => selected = value),
        ),
        Expanded(
          child: selected == 'settings'
              ? const ComicImageToolsSettingsPage(
                  embedded: true,
                  translation: true,
                )
              : const TranslationLanguagesPage(embedded: true),
        ),
      ],
    ),
  );
}
