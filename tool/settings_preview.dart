// Local preview only. Production settings pages with a source descriptor fixture.
import 'package:flutter/material.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/reading/comic_image_tools_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_preferences_page.dart';
import 'package:lume_box/features/comic/comic_image_tools_page.dart';

import '../test/support/fake_source_manager.dart';

const source = SourceDescriptor(
  id: 'huavod-preview',
  name: '华视影院',
  version: '1.0.1',
  enabled: true,
  section: Section.video,
  siteUrl: 'https://huavod.com',
  siteConfig: SourceSiteConfig(mirrors: ['https://huavod.com']),
);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReadingLibrary.open(Section.video);
  await ComicImageToolsSettings.instance.boot();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: const Preview(),
    ),
  );
}

class Preview extends StatefulWidget {
  const Preview({super.key});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  final manager = FakeSourceManager(sources: [source]);
  void openSource() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SourcePreferencesPage(
        section: Section.video,
        sourceId: source.id,
        name: source.name,
        siteUrl: source.siteUrl,
        descriptor: source,
        manager: manager,
      ),
    ),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => openSource());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置界面预览')),
    body: ListView(
      children: [
        ListTile(
          title: const Text('源设置'),
          subtitle: const Text('华视影院 · 查看紧凑布局'),
          onTap: openSource,
        ),
        ListTile(
          title: const Text('全局翻译'),
          subtitle: const Text('查看实时翻译开关'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  const ComicImageToolsSettingsPage(translation: true),
            ),
          ),
        ),
      ],
    ),
  );
}
