import 'package:flutter/material.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/configuration_settings_page.dart';

// Production page and theme, with mobile-only icons visible on desktop.
void main() => runApp(const SettingsPreview());

class SettingsPreview extends StatelessWidget {
  const SettingsPreview({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Lume Box · 配置与体验',
    theme: LumeTheme.build(),
    home: Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: Center(
        child: SizedBox(
          width: 430,
          child: Theme(
            data: LumeTheme.build(),
            child: const ConfigurationSettingsPage(previewIcons: true),
          ),
        ),
      ),
    ),
  );
}
