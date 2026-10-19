import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/app.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/configuration_backup.dart';
import 'package:lume_box/core/session/icloud_sync.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/theme/cover_palette.dart';
import 'package:lume_box/core/theme/interface_typography.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/theme/user_fonts.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/adaptive_cover_surface.dart';
import 'package:lume_box/features/settings/custom_accent_picker.dart';
import 'package:lume_box/features/settings/display_settings_group.dart';
import 'package:lume_box/features/settings/font_settings_page.dart';

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double size) => size < 20 ? size * 2 : size * 1.5;
  @override
  double get textScaleFactor => 2;
}

class _CoverPipeline extends SectionImagePipeline {
  _CoverPipeline(String directory, NetworkSender sender)
    : super(
        cacheDir: directory,
        requestSender: sender,
        diskCache: false,
        maxRetries: 0,
      );
  int references = 0;
  @override
  Future<ui.Image?> image(String url, {int? targetWidth}) async {
    final result = await super.image(url, targetWidth: targetWidth);
    if (result != null) references++;
    return result;
  }

  @override
  void release(String url, {int? targetWidth}) {
    references--;
    super.release(url, targetWidth: targetWidth);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File realFont;
  final controller = AppearanceController.instance;
  const captureKey = Key('personalization.capture');

  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages = jsonDecode(config.readAsStringSync())['packages'] as List;
    final flutter = packages.firstWhere((entry) => entry['name'] == 'flutter');
    final sdk = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    realFont = File(
      '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    expect(realFont.existsSync(), isTrue);
    if (const bool.fromEnvironment('PERSONALIZATION_PREVIEW')) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(realFont.readAsBytesSync())),
        );
      await icons.load();
      final chinese = File('C:/Windows/Fonts/msyh.ttc');
      if (chinese.existsSync()) {
        final loader = FontLoader('PersonalizationPreview')
          ..addFont(
            Future.value(ByteData.sublistView(chinese.readAsBytesSync())),
          );
        await loader.load();
      }
    }
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_personalization');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    AppearanceSettingsStore.resetForTesting();
    controller.resetForTesting();
    UserFonts.instance.resetForTesting();
    await controller.boot();
  });
  tearDown(() async {
    controller.resetForTesting();
    AppearanceSettingsStore.resetForTesting();
    UserFonts.instance.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    LumeTheme.build();
    root.deleteSync(recursive: true);
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('PERSONALIZATION_PREVIEW')) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('build/reader-previews/$name.png')
          .writeAsBytesSync(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> host(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(420, 880),
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumeTheme.build(
            brightness: brightness,
            fontFamily: const bool.fromEnvironment('PERSONALIZATION_PREVIEW')
                ? 'PersonalizationPreview'
                : null,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('新增外观字段重启读回，旧配置与坏字段独立回退', () async {
    final settings = const AppearanceSettings(
      customAccentArgb: 0xFF19A7CE,
      useCustomAccent: true,
      adaptiveColor: true,
      textScale: 1.25,
      fontBold: false,
      fontItalic: true,
    ).copyWith(fontId: 'a' * 64);
    controller.apply(settings);
    controller.resetForTesting();
    AppearanceSettingsStore.resetForTesting();
    await controller.boot();
    expect(controller.settings, settings);
    expect(
      AppearanceSettings.fromJson({'accent': 'mint'}).useCustomAccent,
      isFalse,
    );
    final invalid = AppearanceSettings.fromJson({
      'customAccentArgb': -1,
      'useCustomAccent': true,
      'textScale': double.nan,
      'fontId': '../x',
      'adaptiveColor': true,
      'accent': 'forest',
    });
    expect(invalid.customAccent, isNull);
    expect(invalid.textScale, 1);
    expect(invalid.fontId, isEmpty);
    expect(invalid.adaptiveColor, isTrue);
    expect(invalid.accent, ThemeAccent.forest);
    expect(AppearanceSettings.fromJson({'textScale': 99}).textScale, 1.6);
  });

  test('自定义极浅与极深主色保留可读文字，两套主题均有足够对比', () {
    for (final brightness in Brightness.values) {
      for (final custom in [
        Colors.white,
        Colors.black,
        Colors.yellow,
        const Color(0xFFFF2D55),
      ]) {
        final theme = LumeTheme.build(
          brightness: brightness,
          customAccent: custom,
        );
        expect(
          LumeTheme.contrast(
            theme.colorScheme.primary,
            theme.colorScheme.onPrimary,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LumeTheme.contrast(
            theme.colorScheme.primary,
            theme.colorScheme.surface,
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  test('字号叠加系统非线性缩放，普通/斜体和字体进入 ThemeData', () {
    const scaler = InterfaceTextScaler(_NonlinearScaler(), 1.25);
    expect(scaler.scale(16), 40);
    expect(scaler.scale(32), 60);
    final theme = LumeTheme.build(
      fontFamily: 'custom',
      fontBold: false,
      fontItalic: true,
    );
    expect(theme.textTheme.titleLarge!.fontFamily, 'custom');
    expect(theme.textTheme.titleLarge!.fontStyle, FontStyle.italic);
    expect(
      theme.textTheme.titleLarge!.fontWeight!.value,
      lessThanOrEqualTo(400),
    );
  });

  test('真实 OTF 字体导入、去重、重开载入、删除及本机文件排除备份', () async {
    final fonts = UserFonts();
    await fonts.boot();
    final imported = await fonts.importFile(XFile(realFont.path));
    expect(fonts.familyFor(imported.id), imported.family);
    expect((await fonts.importFile(XFile(realFont.path))).id, imported.id);
    expect(fonts.fonts, hasLength(1));
    final reopened = UserFonts();
    await reopened.boot();
    expect(reopened.fonts.single.id, imported.id);
    expect(await reopened.ensureLoaded(imported.id), isTrue);
    expect(
      ConfigurationBackup.files.any((name) => name.contains('custom_fonts')),
      isFalse,
    );
    expect(
      ICloudSync.files.any((name) => name.contains('custom_fonts')),
      isFalse,
    );
    await reopened.remove(imported.id);
    expect(reopened.familyFor(imported.id), isNull);
    expect(
      File('${root.path}/custom_fonts/${imported.id}.font').existsSync(),
      isFalse,
    );
    final deleted = UserFonts();
    await deleted.boot();
    expect(deleted.fonts, isEmpty);
    fonts.dispose();
    reopened.dispose();
    deleted.dispose();
  });

  test('假字体、截断字体被拒绝，丢失/被改写文件使用系统字体', () async {
    final fonts = UserFonts();
    await fonts.boot();
    final fake = File('${root.path}/fake.ttf')..writeAsBytesSync([1, 2, 3]);
    await expectLater(
      fonts.importFile(XFile(fake.path)),
      throwsFormatException,
    );
    expect(
      () => UserFonts.validateFont(
        Uint8List.fromList(realFont.readAsBytesSync().take(64).toList()),
      ),
      throwsFormatException,
    );
    final imported = await fonts.importFile(XFile(realFont.path));
    File('${root.path}/custom_fonts/${imported.id}.font')
        .writeAsBytesSync(realFont.readAsBytesSync()..[100] ^= 1);
    final corrupted = UserFonts();
    await corrupted.boot();
    expect(await corrupted.ensureLoaded(imported.id), isFalse);
    expect(corrupted.familyFor(imported.id), isNull);
    await File('${root.path}/custom_fonts/${imported.id}.font').delete();
    final missing = UserFonts();
    await missing.boot();
    expect(missing.fonts, isEmpty);
    expect(await missing.ensureLoaded(imported.id), isFalse);
    fonts.dispose();
    corrupted.dispose();
    missing.dispose();
  });

  testWidgets('主题色入口确认才应用，HEX 校验、色相和色板有效，取消不覆盖', (tester) async {
    await host(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: DisplaySettingsGroup()),
      ),
    );
    Future<void> open() async {
      await tester.tap(find.text('主题色'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.descendant(
          of: find.byType(OptionSheet<String>),
          matching: find.text('自定义颜色'),
        ),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(OptionSheet<String>),
          matching: find.text('自定义颜色'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    await tester.enterText(find.byKey(const Key('accent.hex')), '123');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('accent.confirm')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('accent.hex')), '#19A7CE');
    await tester.pump();
    final preview = tester.widget<Container>(
      find.byKey(const Key('accent.preview')),
    );
    expect(
      (preview.decoration! as BoxDecoration).color,
      const Color(0xFF19A7CE),
    );
    expect(controller.settings.useCustomAccent, isFalse);
    await tester.tap(find.byKey(const Key('accent.confirm')));
    await tester.pumpAndSettle();
    expect(controller.settings.customAccentArgb, 0xFF19A7CE);
    expect(controller.settings.useCustomAccent, isTrue);
    await open();
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('accent.saturationValue'))),
    );
    await tester.drag(find.byKey(const Key('accent.hue')), const Offset(50, 0));
    await tester.pump();
    final changed = tester
        .widget<TextField>(find.byKey(const Key('accent.hex')))
        .controller!
        .text;
    expect(changed, isNot('19A7CE'));
    await tester.tap(find.byTooltip('取消自定义颜色'));
    await tester.pumpAndSettle();
    expect(controller.settings.customAccentArgb, 0xFF19A7CE);
    await tester.tap(find.byKey(const Key('appearance.adaptiveColor')));
    await tester.pump();
    expect(controller.settings.adaptiveColor, isTrue);
  });

  testWidgets('字体页面实际导入/选中/删除，字号和字形立即保存', (tester) async {
    final fonts = UserFonts();
    await tester.runAsync(fonts.boot);
    await host(
      tester,
      FontSettingsPage(
        fonts: fonts,
        pickFont: () async => XFile(realFont.path),
      ),
    );
    await tester.drag(
      find.byKey(const Key('fonts.scale')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(controller.settings.textScale, greaterThan(1));
    await tester.tap(find.text('普通'));
    await tester.pump();
    expect(controller.settings.fontBold, isFalse);
    await tester.tap(find.text('斜体'));
    await tester.pump();
    expect(controller.settings.fontItalic, isTrue);
    await tester.tap(find.byTooltip('导入字体文件'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pumpAndSettle();
    expect(fonts.fonts, hasLength(1));
    final id = fonts.fonts.single.id;
    expect(controller.settings.fontId, id);
    await tester.scrollUntilVisible(find.byKey(ValueKey('fonts.$id')), 180);
    await Scrollable.ensureVisible(
      tester.element(find.byKey(ValueKey('fonts.$id'))),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(ValueKey('fonts.$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(fonts.fonts, isEmpty);
    expect(controller.settings.fontId, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    fonts.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用根部实时接入自定义主题、字体与系统字号，不靠重启', (tester) async {
    await tester.runAsync(() async {
      for (final section in Section.values) {
        await SectionScope.open(section);
      }
    });
    await tester.pumpWidget(const LumeBoxApp());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '字号示例',
                    key: Key('font-only.text'),
                    style: TextStyle(fontSize: 16),
                  ),
                  IconButton(
                    key: const Key('font-only.icon'),
                    onPressed: () {},
                    icon: const Icon(Icons.settings),
                  ),
                  SizedBox(
                    width: 140,
                    height: 48,
                    child: FilledButton(
                      key: const Key('font-only.button'),
                      onPressed: () {},
                      child: const Text('按钮文字'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final iconBefore = tester.getRect(find.byKey(const Key('font-only.icon')));
    final buttonBefore = tester.getSize(
      find.byKey(const Key('font-only.button')),
    );
    final textBefore = tester.getSize(find.byKey(const Key('font-only.text')));
    final leftBefore = tester
        .getTopLeft(find.byKey(const Key('font-only.text')))
        .dx;
    final screenBefore = MediaQuery.sizeOf(
      tester.element(find.byKey(const Key('font-only.text'))),
    );
    final font = (await tester.runAsync(
      () => UserFonts.instance.importFile(XFile(realFont.path)),
    ))!;
    controller.apply(
      controller.settings.copyWith(
        useCustomAccent: true,
        customAccentArgb: 0xFF19A7CE,
        textScale: 1.25,
        fontId: font.id,
        fontItalic: true,
      ),
    );
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme!.textTheme.bodyMedium!.fontFamily, font.family);
    expect(app.theme!.textTheme.bodyMedium!.fontStyle, FontStyle.italic);
    final context = tester.element(find.byType(Navigator).first);
    expect(MediaQuery.textScalerOf(context).scale(16), 20);
    expect(
      Theme.of(context).colorScheme.primary,
      app.theme!.colorScheme.primary,
    );
    expect(
      app.theme!.colorScheme.primary,
      isNot(ThemeAccent.fallback.colorFor(Brightness.light)),
    );
    expect(
      tester.getSize(find.byKey(const Key('font-only.text'))).height,
      greaterThan(textBefore.height),
    );
    expect(
      tester.getRect(find.byKey(const Key('font-only.icon'))).size,
      iconBefore.size,
    );
    expect(
      tester.getSize(find.byKey(const Key('font-only.button'))),
      buttonBefore,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('font-only.text'))).dx,
      leftBefore,
    );
    expect(
      MediaQuery.sizeOf(
        tester.element(find.byKey(const Key('font-only.text'))),
      ),
      screenBefore,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('封面色提取忽略白边、黑字和透明像素', () {
    final bytes = Uint8List.fromList([
      for (var i = 0; i < 30; i++) ...[255, 255, 255, 255],
      ...[0, 0, 0, 255],
      ...[0, 255, 0, 0],
      for (var i = 0; i < 8; i++) ...[25, 140, 200, 255],
      ...[220, 30, 40, 255],
    ]);
    expect(dominantCoverColor(bytes), const Color(0xFF198CC8));
    expect(
      dominantCoverColor(Uint8List.fromList([255, 255, 255, 255])),
      isNull,
    );
  });

  testWidgets('自适应颜色丢弃旧封面结果，关闭与失败恢复手动颜色且不改全局设置', (tester) async {
    controller.apply(controller.settings.copyWith(adaptiveColor: true));
    final before = controller.settings;
    final old = Completer<Color?>();
    final next = Completer<Color?>();
    Widget surface(Future<Color?> Function() sample) => Scaffold(
      body: AdaptiveCoverSurface(
        sampleColor: sample,
        child: const Text('推荐作品'),
      ),
    );
    await host(tester, surface(() => old.future));
    await host(tester, surface(() => next.future));
    next.complete(Colors.blue);
    await tester.pumpAndSettle();
    final first = Theme.of(tester.element(find.text('推荐作品')))
        .colorScheme
        .primary;
    old.complete(Colors.red);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('推荐作品'))).colorScheme.primary,
      first,
    );
    expect(controller.settings, before);
    expect(find.byKey(const Key('appearance.adaptiveSurface')), findsOneWidget);
    controller.apply(before.copyWith(adaptiveColor: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('appearance.adaptiveSurface')), findsNothing);
    controller.apply(before);
    await tester.pumpAndSettle();
    await host(
      tester,
      surface(() async => throw StateError('cover unavailable')),
    );
    expect(find.byKey(const Key('appearance.adaptiveSurface')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自适应封面真实取样沿用认证头，并归还图片管线引用', (tester) async {
    final png = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFF198CC8), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    }))!;
    final requests = <NetworkRequest>[];
    final pipe = _CoverPipeline(root.path, (request) async {
      requests.add(request);
      return NetworkResponse(
        body: png,
        statusCode: 200,
        headers: {'content-type': 'image/png'},
      );
    });
    controller.apply(controller.settings.copyWith(adaptiveColor: true));
    await host(
      tester,
      Scaffold(
        body: AdaptiveCoverSurface(
          pipeline: pipe,
          item: const SourceItem(
            id: 'cover',
            title: 'Cover',
            cover: 'https://covers.example/image.png',
            coverHeaders: {
              'Referer': 'https://source.example/',
              'X-Cover-Token': 'test-token',
            },
          ),
          child: const Text('封面推荐'),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(requests, hasLength(1));
    expect(requests.single.headers['Referer'], 'https://source.example/');
    expect(requests.single.headers['X-Cover-Token'], 'test-token');
    expect(find.byKey(const Key('appearance.adaptiveSurface')), findsOneWidget);
    expect(pipe.references, 0);
    await capture(tester, 'adaptive-cover');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    pipe.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('颜色及字体界面在窄屏大字、横屏、深色均可滚动操作', (tester) async {
    for (final size in [const Size(320, 640), const Size(740, 340)]) {
      await host(
        tester,
        const Scaffold(body: CustomAccentPicker(initial: Color(0xFFFF2D55))),
        size: size,
        brightness: Brightness.dark,
        scale: 1.6,
      );
      await tester.ensureVisible(find.byKey(const Key('accent.confirm')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accent.confirm')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await host(
        tester,
        const FontSettingsPage(),
        size: size,
        brightness: Brightness.dark,
        scale: 1.6,
      );
      await tester.scrollUntilVisible(find.text('导入字体文件'), 180);
      expect(tester.takeException(), isNull);
    }
    await host(
      tester,
      const Scaffold(body: CustomAccentPicker(initial: Color(0xFFFF2D55))),
    );
    await capture(tester, 'custom-accent');
    await host(tester, const FontSettingsPage());
    await capture(tester, 'font-settings');
    await host(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: DisplaySettingsGroup()),
      ),
    );
    await capture(tester, 'appearance-settings');
  });
}
