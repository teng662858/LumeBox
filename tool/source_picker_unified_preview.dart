/// Production source pickers with isolated sample data on a phone emulator.
/// flutter run -d emulator-5554 -t tool/source_picker_unified_preview.dart
library;

import 'package:flutter/services.dart';
import 'package:lume_box/core/security/local_cipher.dart';
import 'package:lume_box/features/settings/content_visibility_page.dart';

import 'danmaku_redesign_preview.dart';

import 'dart:io';

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading_library.dart';
import 'package:lume_box/core/session/privacy_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_content_visibility.dart';
import 'package:lume_box/core/source/source_preferences.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/shared/widgets/drawer_geometry.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/features/source/video_source_picker.dart';

import '../test/support/fake_source_manager.dart';

class _PreviewPaths extends PathProviderPlatform {
  _PreviewPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
}

class _PreviewCats extends CatService {
  // Preview data never invokes source engines or the network.
  // ignore: invalid_use_of_visible_for_testing_member
  _PreviewCats() : super.testing();
  @override
  Future<void> boot() async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sandbox = Directory(
    '${Directory.systemTemp.path}/lumebox-reading-layout-preview',
  )..createSync(recursive: true);
  PathProviderPlatform.instance = _PreviewPaths(sandbox.path);
  // Disposable data and key belong solely to this debug preview sandbox.
  // ignore: invalid_use_of_visible_for_testing_member
  LocalCipher.configurePreview(sandbox.path, LocalCipher.random(32));
  await PrivacySettings.instance.boot(directory: sandbox);
  await PrivacySettings.instance.setShowAdult(true);
  await SourceContentVisibility.instance.boot(
    file: File('${sandbox.path}/visibility.json'),
  );
  for (final section in [Section.comic, Section.video, Section.cat]) {
    await ReadingLibrary.open(section);
  }
  await const SourcePreferences(pinned: true)
      .save(Section.comic, 'preview-comic-0');
  await const SourcePreferences(pinned: true)
      .save(Section.video, 'preview-video-0');
  runApp(const SourcePickerUnifiedPreview());
}

class SourcePickerUnifiedPreview extends StatefulWidget {
  const SourcePickerUnifiedPreview({super.key});
  @override
  State<SourcePickerUnifiedPreview> createState() => _PreviewState();
}

class _PreviewState extends State<SourcePickerUnifiedPreview> {
  final comic = FakeSourceManager(
    sources: [
      for (var i = 0; i < 8; i++)
        SourceDescriptor(
          id: 'preview-comic-$i',
          name: ['漫画星球', '连载漫画', '一个比较长的漫画站点名称', '漫画书屋'][i % 4],
          version: '1.2.${i + 1}',
          enabled: true,
          group: '漫画',
        ),
      for (var i = 0; i < 8; i++)
        SourceDescriptor(
          id: 'preview-photo-$i',
          name: ['壁纸图库', '摄影美图', '一个比较长的美图站点名称', '插画世界'][i % 4],
          version: '2.0.${i + 1}',
          enabled: true,
          group: '美图',
        ),
    ],
  )..selected = 'preview-comic-0';
  late final readingExtras = [
    const SourceDescriptor(
      id: 'preview-novel',
      name: '文字小说（示例源）',
      version: '本地预览',
      enabled: true,
      mediaKind: 'novel',
    ),
    const SourceDescriptor(
      id: 'preview-audio',
      name: '有声小说（示例源）',
      version: '本地预览',
      enabled: true,
      mediaKind: 'audio',
    ),
    const SourceDescriptor(
      id: 'kazumi_preview',
      name: 'Kazumi 动漫（示例源）',
      version: '本地预览',
      enabled: true,
    ),
  ];
  final video = FakeSourceManager(
    sources: [
      for (var i = 0; i < 12; i++)
        SourceDescriptor(
          id: 'preview-video-$i',
          name: ['影视星球', '追剧时光', '一个比较长的视频站点名称', '高清影院'][i % 4],
          version: '1.2.${i + 1}',
          enabled: true,
          runtimeKind: i >= 8 ? 'python' : 'javascript',
        ),
    ],
  )..selected = 'preview-video-0';
  final cats = _PreviewCats();
  bool dark = false;
  @override
  void dispose() {
    cats.dispose();
    super.dispose();
  }

  void openComic(BuildContext context) => showSourcePicker(
    context: context,
    section: Section.comic,
    sources: [...comic.sources, ...readingExtras],
    currentId: comic.selected,
    manager: comic,
  );

  Future<void> openVideo(BuildContext context) async {
    await showLumeBottomSheet<VideoSourceChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VideoSourcePicker(manager: video, service: cats),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: LumeTheme.build(
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('漫画 / 视频 · 分类排序预览'),
          actions: [
            IconButton(
              tooltip: '切换亮暗',
              onPressed: () => setState(() => dark = !dark),
              icon: const Icon(Icons.brightness_6),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('使用生产面板组件，示例数据独立存储'),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => openComic(context),
                child: const Text('预览漫画源选择'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => openVideo(context),
                child: const Text('预览视频源选择'),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ContentVisibilityPage(),
                  ),
                ),
                child: const Text('内容分类显示'),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () async {
                  await SystemChrome.setPreferredOrientations([
                    DeviceOrientation.landscapeLeft,
                  ]);
                  if (!context.mounted) return;
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const DanmakuRedesignPreview(),
                    ),
                  );
                  await SystemChrome.setPreferredOrientations([
                    DeviceOrientation.portraitUp,
                  ]);
                },
                child: const Text('横屏弹幕与线路预览'),
              ),
              const SizedBox(height: 24),
              const Text(
                '高 50 · 圆角 10 · 图标 32\n列间距 8 · 纵向间距 5 · 左右留白 14',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
