import 'package:flutter/material.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import '../test/support/fake_source_manager.dart';

// Standalone UI preview: production source-management page, sample data, no iOS runtime.
void main() => runApp(const SourceManagementPreview());

class SourceManagementPreview extends StatefulWidget {
  const SourceManagementPreview({super.key});
  @override
  State<SourceManagementPreview> createState() =>
      _SourceManagementPreviewState();
}

class _SourceManagementPreviewState extends State<SourceManagementPreview> {
  bool dark = false;
  final manager = FakeSourceManager(
    sources: const [
      SourceDescriptor(
        id: 'preview-a',
        name: '漫画源示例 A',
        version: '1.0',
        enabled: true,
      ),
      SourceDescriptor(
        id: 'preview-b',
        name: '漫画源示例 B',
        version: '1.0',
        enabled: false,
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: LumeTheme.build(
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    home: Stack(
      children: [
        SourceSectionPage(section: Section.comic, manager: manager),
        Positioned(
          right: 16,
          bottom: 20,
          child: FloatingActionButton(
            tooltip: '切换亮暗预览',
            onPressed: () => setState(() => dark = !dark),
            child: Icon(dark ? Icons.light_mode : Icons.dark_mode),
          ),
        ),
      ],
    ),
  );
}
