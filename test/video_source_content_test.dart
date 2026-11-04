import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/privacy_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_content_category.dart';
import 'package:lume_box/core/source/source_content_visibility.dart';
import 'package:lume_box/core/source/source_preferences.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/source/source_preferences_page.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/features/source/source_import_flow.dart';
import 'package:lume_box/features/source/video_source_picker.dart';
import 'package:lume_box/shared/widgets/source_picker_card.dart';

import 'support/fake_source_manager.dart';

class ContentPickerService extends CatService {
  ContentPickerService() : super.testing();
  @override
  Future<void> boot() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('综合源声明与隐私分级互不覆盖', () async {
    const script =
        '// LumeSource: {"id":"x","name":"X","category":"video","contentCategory":"adult","contentTypes":["video","novel","comic"]}';
    expect(SourceContentCategories.mixedFromScript(script), isTrue);
    expect(
      SourceContentCategories.mixedFromScript(
        '// LumeSource: {"contentTypes":["video","video"]}',
      ),
      isFalse,
    );
    const source = SourceDescriptor(
      id: 'test_mixed',
      name: '综合站',
      version: '1',
      enabled: true,
      contentCategory: 'adult',
      mixedContent: true,
    );
    expect(
      SourceContentCategories.automatic(source),
      SourceContentCategory.mixed,
    );
    await PrivacySettings.instance.setShowAdult(false);
    expect(
      SourceContentVisibility.instance.allows(Section.video, source),
      isFalse,
    );
    await PrivacySettings.instance.setShowAdult(true);
    expect(
      SourceContentVisibility.instance.allows(Section.video, source),
      isTrue,
    );
    await PrivacySettings.instance.setShowAdult(false);
    expect(
      SourceContentCategories.automatic(
        const SourceDescriptor(
          id: 'uaa_video',
          name: 'UAA',
          version: '1',
          enabled: true,
        ),
      ),
      SourceContentCategory.mixed,
    );
  });
  test('截图中的四个旧源无需手动设置即可归类', () {
    for (final entry in [
      ('asmrba_video', SourceContentCategory.adult),
      ('asmrhoney_video', SourceContentCategory.adult),
      ('duboku_video', SourceContentCategory.movie),
      ('ptt_drama', SourceContentCategory.movie),
    ]) {
      expect(
        SourceContentCategories.automatic(
          SourceDescriptor(
            id: entry.$1,
            name: '旧版源',
            version: '1',
            enabled: true,
          ),
        ),
        entry.$2,
      );
    }
  });
  late Directory root;
  late ContentPickerService service;
  late FakeSourceManager manager;
  late ReadingLibrary library;
  const movie = SourceDescriptor(
    id: 'movie',
    name: '360资源站',
    version: '1.0.1',
    enabled: true,
    contentCategory: 'movie',
  );
  const adult = SourceDescriptor(
    id: 'adult',
    name: '成人示例源',
    version: '1',
    enabled: true,
  );
  const unknown = SourceDescriptor(
    id: 'new',
    name: '新导入源',
    version: '1',
    enabled: true,
  );
  setUp(() async {
    root = Directory.systemTemp.createTempSync('source-content-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
    await ReadingLibrary.open(Section.cat);
    await PrivacySettings.instance.setShowAdult(true);
    service = ContentPickerService();
    manager = FakeSourceManager(
      sources: [
        movie,
        adult,
        unknown,
        const SourceDescriptor(
          id: 'pinned',
          name: '置顶影视源',
          version: '1',
          enabled: true,
          contentCategory: 'movie',
        ),
        const SourceDescriptor(
          id: 'py',
          name: 'Python 示例',
          version: '1',
          enabled: true,
          runtimeKind: 'python',
        ),
      ],
    )..selected = 'movie';
    await const SourcePreferences(pinned: true).save(Section.video, 'pinned');
  });
  tearDown(() async {
    service.dispose();
    await PrivacySettings.instance.setShowAdult(false);
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    root.deleteSync(recursive: true);
  });
  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: VideoSourcePicker(manager: manager, service: service),
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> category(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('video-source-content-$id')));
    await tester.pumpAndSettle();
  }

  test('classification uses explicit metadata and known ratings; unknown sources stay unclassified', () {
    expect(
      SourceContentCategories.automatic(movie),
      SourceContentCategory.movie,
    );
    expect(
      SourceContentCategories.automatic(adult),
      SourceContentCategory.adult,
    );
    expect(
      SourceContentCategories.automatic(unknown),
      SourceContentCategory.unclassified,
    );
    expect(SourceContentCategories.appliesTo(manager.sources.last), isFalse);
    expect(
      SourceContentCategories.fromScript(
        '// LumeSource: {"id":"x","name":"X","contentCategory":"adult"}',
      ),
      'adult',
    );
    expect(
      SourceContentCategories.fromScript(
        '// LumeSource: {"contentCategory":"all"}',
      ),
      '',
    );
    expect(SourceContentCategories.fromScript('// LumeSource: invalid'), '');
    expect(
      SourceContentCategories.automatic(
        const SourceDescriptor(
          id: 'web-360',
          name: '360 资源',
          version: '1',
          enabled: true,
          siteUrl: 'https://360zy.com/',
        ),
      ),
      SourceContentCategory.movie,
    );
  });

  test(
    'manual category survives a source revision and respects adult visibility',
    () async {
      await const SourcePreferences(
        contentCategory: 'adult',
        pinned: true,
      ).save(Section.video, unknown.id);
      const updated = SourceDescriptor(
        id: 'new',
        name: '改名后的源',
        version: '2',
        enabled: true,
        contentCategory: 'movie',
      );
      expect(
        SourceContentCategories.forSource(updated),
        SourceContentCategory.adult,
      );
      await PrivacySettings.instance.setShowAdult(false);
      expect(
        SourceContentVisibility.instance.allows(Section.video, updated),
        isFalse,
      );
      await SourcePreferences.read(
        Section.video,
        unknown.id,
      ).copyWith(contentCategory: 'movie').save(Section.video, unknown.id);
      expect(
        SourceContentVisibility.instance.allows(Section.video, updated),
        isTrue,
      );
      expect(SourcePreferences.read(Section.video, unknown.id).pinned, isTrue);
      expect(
        SourcePreferences.read(Section.comic, unknown.id).contentCategory,
        isEmpty,
      );
    },
  );

  testWidgets('JS 分类区分综合与未知源，全部仍能找到未知源', (tester) async {
    manager.sources.add(
      const SourceDescriptor(
        id: 'mixed',
        name: '综合示例源',
        version: '1',
        enabled: true,
        mixedContent: true,
      ),
    );
    await pump(tester);
    expect(find.text('360资源站'), findsOneWidget);
    expect(find.text('成人示例源'), findsNothing);
    expect(find.text('新导入源'), findsNothing);
    expect(
      tester.getTopLeft(find.text('置顶影视源')).dx,
      lessThan(tester.getTopLeft(find.text('360资源站')).dx),
    );
    expect(tester.widget<Text>(find.text('360资源站')).maxLines, 2);
    expect(
      find.byKey(const ValueKey('video-source-content-heading-movie')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('video-source-content-filter')))
          .height,
      lessThanOrEqualTo(46),
    );
    await category(tester, 'adult');
    expect(find.text('成人示例源'), findsOneWidget);
    expect(find.text('360资源站'), findsNothing);
    await category(tester, 'mixed');
    expect(find.text('综合示例源'), findsOneWidget);
    expect(find.text('新导入源'), findsNothing);
    await category(tester, 'all');
    expect(find.text('新导入源'), findsOneWidget);
    for (final id in ['movie', 'adult', 'mixed', 'unclassified']) {
      expect(
        find.byKey(ValueKey('video-source-content-heading-$id')),
        findsOneWidget,
      );
    }
    expect(find.text('Python 示例'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'category is remembered across reopening and search applies within the category',
    (tester) async {
      await pump(tester);
      await category(tester, 'adult');
      expect(library.setting(VideoSourcePicker.contentFilterKey), 'adult');
      await tester.enterText(find.byType(TextField), '360');
      await tester.pumpAndSettle();
      expect(find.text('360资源站'), findsNothing);
      expect(find.text('没有匹配的源'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.text('成人示例源'), findsOneWidget);
      expect(find.text('360资源站'), findsNothing);
    },
  );

  testWidgets(
    'manual classification is available in source settings and persists',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: SourcePreferencesPage(
            section: Section.video,
            sourceId: unknown.id,
            name: unknown.name,
            descriptor: unknown,
            manager: manager,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('source-content-setting-adult')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('source-content-setting-adult')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-content-setting-adult')),
      );
      await tester.tap(find.text('保存'));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(
        SourceContentCategories.forSource(unknown),
        SourceContentCategory.adult,
      );
    },
  );

  testWidgets(
    'manager bulk classifies unclassified JS sources and preserves pinned settings',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      manager.sources.add(
        const SourceDescriptor(
          id: 'new2',
          name: '另一新源',
          version: '1',
          enabled: true,
        ),
      );
      await const SourcePreferences(
        pinned: true,
        iconUrl: 'https://example.test/icon.png',
      ).save(Section.video, 'new');
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: SourceSectionPage(section: Section.video, manager: manager),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('manager-content-unclassified')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('站点维护'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多选站点'));
      await tester.pumpAndSettle();
      for (final id in ['new', 'new2']) {
        final box = find.byKey(ValueKey('select-source-$id'));
        await tester.ensureVisible(box);
        await tester.tap(box);
        await tester.pump();
      }
      final action = find.byKey(const ValueKey('bulk-source-category'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('归到成人'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        SourcePreferences.read(Section.video, 'new').contentCategory,
        'adult',
      );
      expect(
        SourcePreferences.read(Section.video, 'new2').contentCategory,
        'adult',
      );
      expect(SourcePreferences.read(Section.video, 'new').pinned, isTrue);
      expect(
        SourcePreferences.read(Section.video, 'new').iconUrl,
        'https://example.test/icon.png',
      );
      expect(
        SourcePreferences.read(Section.video, 'py').contentCategory,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import assigns a chosen category and automatic reimport preserves it',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      manager.importDescriptor = unknown;
      Future<void> import(String category) async {
        final result = await tester.runAsync(
          () => importSources(
            context,
            manager: manager,
            items: const [SourceImportItem(script: '// example')],
            section: Section.video,
            contentCategory: category,
          ),
        );
        await tester.pumpAndSettle();
        expect(result, isTrue);
      }

      await import('adult');
      expect(
        SourceContentCategories.forSource(unknown),
        SourceContentCategory.adult,
      );
      await import('');
      expect(
        SourceContentCategories.forSource(unknown),
        SourceContentCategory.adult,
      );
      await import('movie');
      expect(
        SourceContentCategories.forSource(unknown),
        SourceContentCategory.movie,
      );
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets('content filters fit width $width at large text scale', (
      tester,
    ) async {
      await pump(tester, width: width, scale: 2);
      await category(tester, 'all');
      expect(find.text('新导入源'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final cards = tester.widgetList<SourcePickerCard>(
        find.byType(SourcePickerCard),
      );
      expect(cards.every((card) => card.titleMaxLines == 2), isTrue);
    });
  }
}
