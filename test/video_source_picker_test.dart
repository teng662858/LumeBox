import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_bar.dart';
import 'package:lume_box/features/source/video_source_picker.dart';
import 'package:lume_box/features/source/video_source_scope.dart';

import 'support/fake_source_manager.dart';

class _PickerCatService extends CatService {
  _PickerCatService() : super.testing();
  @override
  Future<void> boot() async {}
}

void main() {
  late Directory root;
  late _PickerCatService service;
  late FakeSourceManager manager;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-type-picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ReadingLibrary.open(Section.video);
    await ReadingLibrary.open(Section.cat);
    service = _PickerCatService();
    service.subscriptions.add(
      CatSubscription(
        id: 'pack',
        name: '牛二',
        url: 'https://example.test/index.js.md5',
        sites: const [
          CatSite(
            subscriptionId: 'pack',
            key: 'a',
            name: '猫源测试长名称站点',
            api: '/a',
          ),
          CatSite(subscriptionId: 'pack', key: 'b', name: '另一个站点', api: '/b'),
        ],
      ),
    );
    manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'ordinary',
          name: '普通视频长名称测试',
          version: '1.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'disabled',
          name: '停用源',
          version: '1',
          enabled: false,
        ),
      ],
    );
  });
  tearDown(() async {
    service.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: VideoSourcePicker(manager: manager, service: service),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('顶部分类筛选和搜索包名，不改变已有源选择', (tester) async {
    await pump(tester);
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('牛二'), findsOneWidget);
    expect(find.text('停用源'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-source-type-cat')));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(find.text('猫源测试长名称站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '牛二');
    await tester.pumpAndSettle();
    expect(find.text('另一个站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的源'), findsOneWidget);
    expect(manager.selectedIds, isEmpty);
  });

  testWidgets('未接入的类型明确显示状态，关闭不会导入空源', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('video-source-type-python')));
    await tester.pumpAndSettle();
    expect(find.text('PY源尚未接入'), findsOneWidget);
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets('选中猫源返回原站点，调用方继续使用原存储', (tester) async {
    VideoSourceChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<VideoSourceChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      VideoSourcePicker(manager: manager, service: service),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('猫源测试长名称站点'));
    await tester.pumpAndSettle();
    expect(result?.site?.id, service.subscriptions.single.sites.first.id);
    expect(result?.sourceId, isNull);
  });

  testWidgets('视频的单个切源按钮使用统一抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoSourceScope(
          openPicker: (_) async {
            opened++;
          },
          child: Scaffold(
            body: ReadingSourceBar(
              section: Section.video,
              manager: manager,
              sources: manager.sources,
              currentId: 'ordinary',
              onSelect: (_) {},
              onManage: () {},
              showManage: false,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('选择视频源'), findsNothing);
  });

  for (final width in [320.0, 390.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('长名称适配宽度 $width 字号 $scale', (tester) async {
        await pump(tester, width: width, scale: scale);
        expect(tester.takeException(), isNull);
        if (width == 390 && scale == 1) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('build/video-source-layout-light.png');
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
