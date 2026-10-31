// Local UI preview. Uses the production source selection panels.
import 'package:flutter/material.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/reading/comic_image_tools_settings.dart';
import 'package:lume_box/features/comic/comic_image_tools_page.dart';
import 'package:lume_box/features/source/source_preferences_page.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/settings/tmdb_settings_page.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/features/source/video_source_picker.dart';

import '../test/support/fake_source_manager.dart';

final videoSources = [
  SourceDescriptor(
    id: "web-07a5a1a92631",
    name: "360资源站",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://360zy.com/",
    iconUrl: "",
  ),
  SourceDescriptor(
    id: "a123tv",
    name: "A123TV",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://a123tv.com",
    iconUrl: "https://a123tv.com/s2/icon/favicon-180.png",
  ),
  SourceDescriptor(
    id: "luttt_video",
    name: "北觅影视",
    version: "1.1.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "",
    iconUrl: "",
  ),
  SourceDescriptor(
    id: "huavod",
    name: "华视影院",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://huavod.com",
    iconUrl: "https://huavod.com/static/favicon/favicon-96x96.png",
    siteConfig: SourceSiteConfig(mirrors: ['https://huavod.com']),
  ),
  SourceDescriptor(
    id: "ysxq-boju",
    name: "播剧网（ysxq）",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://ysxq.cc",
    iconUrl: "https://ysxq.cc/template/dsn2/static/img/ico.png",
  ),
  SourceDescriptor(
    id: "olehdtv",
    name: "欧乐影院",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://www.olehdtv.com",
    iconUrl: "https://www.olehdtv.com/favicon.ico",
  ),
  SourceDescriptor(
    id: "gaze_video",
    name: "注视影视",
    version: "1.0.3",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://gaze.red/",
    iconUrl: "https://gaze.red/favicon.png",
  ),
  SourceDescriptor(
    id: "gztv5_video",
    name: "瓜子影视",
    version: "3.1.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "",
    iconUrl: "https://gztv5.com/favicon.ico",
  ),
  SourceDescriptor(
    id: "duanju2",
    name: "短剧网",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://www.duanju2.com",
    iconUrl: "https://www.duanju2.com/template/djw/ripro_static/favicon.ico",
  ),
  SourceDescriptor(
    id: "jpyy2_video",
    name: "金牌影院",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "",
    iconUrl: "",
  ),
  SourceDescriptor(
    id: "flixflop",
    name: "飞流视频",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://www.flixflop.com",
    iconUrl: "https://www.flixflop.com/favicon.png",
  ),
  SourceDescriptor(
    id: "fdzys",
    name: "饭搭子影视",
    version: "1.0.1",
    enabled: true,
    section: Section.video,
    contentCategory: "movie",
    siteUrl: "https://fdzys.com",
    iconUrl: "https://fdzys.com/template/mizhiady/statics/images/favicon.ico",
  ),
];
final comicSources = [
  for (final name in ['K漫画', '三四漫画', '我的漫画', '楠楠漫画'])
    SourceDescriptor(
      id: 'preview-$name',
      name: name,
      version: '1.0.0',
      enabled: true,
      section: Section.comic,
    ),
];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  for (final section in Section.values) {
    await ReadingLibrary.open(section);
  }
  await TmdbSettings.instance.boot();
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
  final videos = FakeSourceManager(sources: videoSources);
  final comics = FakeSourceManager(sources: comicSources);
  void openVideo() {
    showVideoSourcePicker(context: context, manager: videos);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => openVideo());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('源卡片 · 55 高 / 33 图标')),
    body: ListView(
      children: [
        ListTile(title: const Text('视频源卡片'), onTap: openVideo),
        ListTile(
          title: const Text('漫画源卡片'),
          onTap: () => showSourcePicker(
            context: context,
            section: Section.comic,
            sources: comicSources,
            currentId: comicSources.first.id,
            manager: comics,
          ),
        ),
        ListTile(
          title: const Text('TMDB 内置配置'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TmdbSettingsPage()),
          ),
        ),
        ListTile(
          title: const Text('AI 图片超分与上色'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const ComicImageToolsSettingsPage(),
            ),
          ),
        ),
        ListTile(
          title: const Text('源设置 · 高清图标'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SourcePreferencesPage(
                section: Section.video,
                sourceId: videoSources[3].id,
                name: videoSources[3].name,
                siteUrl: videoSources[3].siteUrl,
                descriptor: videoSources[3],
                manager: videos,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
