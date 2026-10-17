import 'package:flutter/material.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_favicon.dart';
import 'package:lume_box/core/source/source_picker_groups.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

import '../test/support/fake_source_manager.dart';

const previewLogoUrls = [
  'https://github.githubassets.com/favicons/favicon.png',
  'https://www.gstatic.com/youtube/img/branding/favicon/favicon_144x144.png',
];

// Real public PNG logos, fetched by the same resolver as production rows.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    for (final url in previewLogoUrls)
      SourceFavicon.instance.load(origin: '', explicit: [url]),
  ]);
  runApp(const SourceGroupsPreview());
}

class SourceGroupsPreview extends StatefulWidget {
  const SourceGroupsPreview({super.key});
  @override
  State<SourceGroupsPreview> createState() => _SourceGroupsPreviewState();
}

class _SourceGroupsPreviewState extends State<SourceGroupsPreview> {
  Section section = Section.cat;
  bool dark = false;
  int columns = 2;

  List<SourceDescriptor> sources(Section section) => [
    for (final group in SourcePickerGroups.forSection(section))
      for (var i = 0; i < 14; i++)
        SourceDescriptor(
          id: '${section.name}-${group.$1}-$i',
          name: '${group.$2} ${i + 1}',
          version: '1.0',
          enabled: true,
          group: group.$2,
          iconUrl: i == 13 ? '' : previewLogoUrls[i % 2],
        ),
  ];

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: LumeTheme.build(
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    home: Scaffold(
      appBar: AppBar(
        title: Text(section == Section.cat ? '猫源 · 一体列表' : '源列表 · 左右独立分栏'),
        actions: [
          IconButton(
            tooltip: '切换亮暗模式',
            onPressed: () => setState(() => dark = !dark),
            icon: const Icon(Icons.brightness_6),
          ),
        ],
      ),
      body: Center(
        child: SizedBox(
          width: 430,
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final value in Section.values)
                    ChoiceChip(
                      label: Text(value.label),
                      selected: value == section,
                      onSelected: (_) => setState(() => section = value),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  section == Section.cat
                      ? '猫源整块统一滚动 · 真实网络 Logo'
                      : '左右分类独立滚动 · GitHub / YouTube 真实网络 Logo',
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final entries = sources(section);
                    return MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                      ),
                      child: section != Section.cat
                          ? SourcePickerSheet(
                              key: ValueKey(section),
                              section: section,
                              sources: entries,
                              currentId: entries.first.id,
                              manager: FakeSourceManager(sources: entries),
                            )
                          : ListView(
                              children: [
                                ListTile(
                                  title: const Text('示例订阅'),
                                  trailing: IconButton(
                                    tooltip: '切换列数',
                                    icon: Icon(
                                      columns == 2
                                          ? Icons.view_agenda
                                          : Icons.grid_view,
                                    ),
                                    onPressed: () => setState(
                                      () => columns = columns == 2 ? 1 : 2,
                                    ),
                                  ),
                                ),
                                CatGroupedSourceList(
                                  columns: columns,
                                  sites: [
                                    for (final kind in [
                                      'video',
                                      'comic',
                                      'novel',
                                      'live',
                                    ])
                                      for (var i = 0; i < 14; i++)
                                        CatSite(
                                          subscriptionId: 'preview',
                                          key: '$kind-$i',
                                          name:
                                              '站点 ${['video', 'comic', 'novel', 'live'].indexOf(kind) * 14 + i + 1}',
                                          api: '/preview',
                                          kind: kind,
                                          iconUrl: i == 13
                                              ? ''
                                              : previewLogoUrls[i % 2],
                                        ),
                                  ],
                                  itemBuilder: (context, site) => ListTile(
                                    leading: SourceIcon(
                                      name: site.name,
                                      siteIcon: site.iconUrl,
                                      size: 28,
                                      section: Section.cat,
                                      sourceId: site.id,
                                    ),
                                    title: Text(site.name),
                                    trailing: const Icon(
                                      Icons.more_vert,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
