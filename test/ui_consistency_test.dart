import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/module_ui_scale.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/reading/section_image.dart';

import 'support/fake_source_manager.dart';

/// 本轮真机反馈的界面口径回归：
/// - 点封面（哪怕封面没加载出来）也要能打开条目，不能只有点标题才行；
/// - 全屏/竖屏控制栏：统一左右内边距、按钮大小统一、底部按钮均匀分布、
///   播放内核做进控制栏、音轨从播放页拿掉；
/// - 设置里的「控件尺寸」要真的作用到界面（此前只写库、无人读）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_ui_consistency');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
    await ReadingLibrary.open(Section.comic);
    BrowseLayoutSettings.instance.resetForTesting();
    ModuleUiScale.instance.resetForTesting();
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    ModuleUiScale.instance.resetForTesting();
    BrowseLayoutSettings.instance.resetForTesting();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('卡片点击：封面点得动', () {
    Future<void> pumpBrowse(
      WidgetTester tester, {
      required void Function(ExploreSelection) onOpen,
    }) async {
      final library = await ReadingLibrary.open(Section.comic);
      final pipeline = SectionImagePipeline(
        cacheDir: library.imageCacheDir,
        diskCache: false,
        requestSender: (_) async => const NetworkResponse(
          statusCode: 404,
          body: <int>[],
          headers: <String, String>{},
        ),
      );
      addTearDown(pipeline.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: ExploreView(
              section: Section.comic,
              pipeline: pipeline,
              manager: FakeSourceManager(
                sources: const <SourceDescriptor>[
                  SourceDescriptor(
                    id: 'demo',
                    name: '示例源',
                    version: '1',
                    enabled: true,
                  ),
                ],
                opened: <String, DataSource>{'demo': _CoverSource()},
              ),
              onOpenItem: onOpen,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('封面加载失败时，点封面照样打开条目（真机：只有点标题才行）', (tester) async {
      ExploreSelection? opened;
      await pumpBrowse(tester, onOpen: (selection) => opened = selection);

      expect(find.byType(SectionImage), findsWidgets);
      // 点封面正中：必须交给卡片（打开条目），而不是被「重试图片」吃掉。
      await tester.tap(find.byType(SectionImage).first);
      await tester.pumpAndSettle();
      expect(opened?.item.title, '封面挂了的作品');
    });
  });
}

/// 只有一条条目、且**封面一定加载失败**的图源（真机「没封面」的场景）。
class _CoverSource implements DataSource {
  @override
  final Section section = Section.comic;

  @override
  String get id => 'demo';

  @override
  String get name => '示例源';

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(
    items: <SourceItem>[
      SourceItem(
        id: '/book/1',
        title: '封面挂了的作品',
        cover: 'https://images.example/dead.jpg',
      ),
    ],
  );

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => null;
}

/// 三套内核都可用（测试里不接平台目录）。
