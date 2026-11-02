import 'package:flutter/material.dart';
import 'package:lume_box/features/source/add_source_button.dart';
import 'package:lume_box/features/source/source_entry_order_sheet.dart';
import 'package:lume_box/core/source/kazumi_rule.dart';
import 'package:lume_box/core/source/source_subscription_catalog.dart';

import 'support/fake_source_manager.dart';

import 'dart:convert';

import 'package:lume_box/core/reading/reading_identity.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/reading_section_migration.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_entry_order.dart';
import 'package:lume_box/core/source/source_picker_groups.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SectionDatabase video, comic;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('reading-relocation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ReadingLibrary.open(Section.comic);
    await ReadingLibrary.open(Section.video);
    video = await SectionDatabase.open(await SectionScope.open(Section.video));
    comic = await SectionDatabase.open(await SectionScope.open(Section.comic));
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    video.dispose();
    comic.dispose();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  const audio =
      '// LumeSource: {"id":"book_audio","name":"听书源","version":"1","category":"video","mediaType":"audio"}\nvar LumeSource={};';
  void insert(SectionDatabase db, String id, String script, String section) =>
      db.upsertSource(
        id: id,
        name: id,
        version: '1',
        section: section,
        script: script,
      );

  test('迁移有声与Kazumi，保留收藏逐集进度和源设置，重复运行不重复数据', () async {
    insert(video, 'book_audio', audio, 'video');
    insert(
      video,
      'kazumi_fixture',
      '// LumeSource: {"id":"kazumi_fixture","name":"动漫","version":"1","category":"video"}',
      'video',
    );
    insert(
      video,
      'ordinary',
      '// LumeSource: {"id":"ordinary","name":"电影","version":"1","category":"video"}',
      'video',
    );
    video.setSourceEnabled('book_audio', false);
    video.setSourceNetwork(
      'book_audio',
      userAgent: 'custom',
      cookie: 'local-cookie',
      proxy: '',
      bridge: '',
    );
    video.setSetting('current_source', 'book_audio');
    final old = await ReadingLibrary.open(Section.video);
    old.shelve(
      sourceId: 'book_audio',
      itemId: 'same',
      title: '小说',
      chapterCount: 2,
    );
    old.saveProgress(
      VideoProgress(
        sourceId: 'book_audio',
        section: Section.video,
        itemId: 'same',
        chapterIndex: 0,
        chapterId: 'c1',
        chapterTitle: '第一集',
        updatedAt: DateTime.now(),
        position: const Duration(seconds: 37),
      ),
    );
    old.setSetting(
      'source.preferences.book_audio',
      '{"pickerGroup":"audiobook","pinned":true}',
    );
    old.setSetting(
      'favorites.folders',
      jsonEncode({
        '听书': [ReadingIdentity.key('book_audio', 'same')],
      }),
    );
    final subscriptions = File(
      (await SectionScope.open(Section.video)).resolve('subscriptions.json'),
    );
    subscriptions.writeAsStringSync(
      jsonEncode({
        'subscriptions': [
          {
            'url': 'https://fixture.invalid/audiobook.txt',
            'enabled': false,
            'members': {'book_audio': 'hash'},
          },
        ],
      }),
    );
    await ReadingSectionMigration.run();
    expect(video.source('book_audio'), isNull);
    expect(video.source('kazumi_fixture'), isNull);
    expect(video.source('ordinary'), isNotNull);
    expect(comic.source('book_audio')!.enabled, isFalse);
    expect(comic.source('book_audio')!.network.cookie, 'local-cookie');
    final library = await ReadingLibrary.open(Section.comic);
    expect(library.onShelf('same', sourceId: 'book_audio'), isTrue);
    expect(
      (library.progress(
        'same',
        sourceId: 'book_audio',
      ) as VideoProgress).position.inSeconds,
      37,
    );
    expect(
      library.setting('source.preferences.book_audio'),
      contains('pinned'),
    );
    expect(library.setting('favorites.folders'), contains('听书'));
    final movedSubscriptions = jsonDecode(
      File(
        (await SectionScope.open(Section.comic)).resolve('subscriptions.json'),
      ).readAsStringSync(),
    ) as Map;
    expect(
      (movedSubscriptions['subscriptions'] as List).single['enabled'],
      false,
    );
    expect(old.progress('same', sourceId: 'book_audio'), isNull);
    await ReadingSectionMigration.run();
    expect(comic.sources(), hasLength(2));
    expect(library.shelf(), hasLength(1));
  });
  test('同ID不同脚本不覆盖，仍保留原源与收藏', () async {
    insert(video, 'book_audio', audio, 'video');
    insert(comic, 'book_audio', 'different-local-version', 'comic');
    final old = await ReadingLibrary.open(Section.video);
    old.shelve(sourceId: 'book_audio', itemId: 'book', title: '旧收藏');
    await ReadingSectionMigration.run();
    expect(video.source('book_audio'), isNotNull);
    expect(comic.source('book_audio')!.script, 'different-local-version');
    expect(old.onShelf('book', sourceId: 'book_audio'), isTrue);
  });
  test('小说有声Kazumi归漫画，普通视频仍不能导入漫画', () {
    for (final category in ['novel', 'audiobook', 'kazumi', 'photo']) {
      final meta = SourceMetadata(
        id: 'test',
        name: '测试',
        version: '1',
        category: category,
      );
      expect(meta.sectionMismatch(Section.comic), isNull);
      expect(meta.sectionMismatch(Section.video), isNotNull);
    }
    final legacy = SourceMetadata.parseHeader(audio)!;
    expect(legacy.sectionMismatch(Section.comic, script: audio), isNull);
    expect(legacy.sectionMismatch(Section.video, script: audio), isNotNull);
    expect(
      const SourceMetadata(
        id: 'movie',
        name: '电影',
        version: '1',
        category: 'video',
      ).sectionMismatch(Section.comic),
      isNotNull,
    );
  });
  test('两个板块分类顺序分别持久化，新增分类不丢失且默认归类不受排序影响', () async {
    await SourceEntryOrder.save(Section.comic, SourcePickerGroups.orderKey, [
      'novel',
      'photo',
      'comic',
      'novel',
      'removed',
    ]);
    await SourceEntryOrder.save(Section.video, 'source.picker.typeOrder', [
      'web',
      'python',
      'ordinary',
    ]);
    expect(SourcePickerGroups.forSection(Section.comic).first.$1, 'novel');
    expect(
      SourcePickerGroups.groupFor(
        Section.comic,
        const SourceDescriptor(
          id: 'unknown',
          name: '未知',
          version: '1',
          enabled: true,
        ),
      ),
      'comic',
    );
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await ReadingLibrary.open(Section.comic);
    await ReadingLibrary.open(Section.video);
    expect(SourcePickerGroups.forSection(Section.comic).map((e) => e.$1), [
      'novel',
      'photo',
      'comic',
      'audiobook',
      'kazumi',
    ]);
    expect(
      SourceEntryOrder.read(Section.video, 'source.picker.typeOrder', [
        ('ordinary', 'JS'),
        ('python', 'PY'),
        ('web', '网页'),
      ]).first.$1,
      'web',
    );
  });
  for (final pair in [
    ('有声小说源', '导入有声小说源', SubscriptionCatalog.audiobooksUrl),
    ('Kazumi 动漫规则源', '导入 Kazumi 源', KazumiRule.officialIndex),
  ]) {
    testWidgets('漫画模块提供 ${pair.$1} 导入且取消不写入', (tester) async {
      final manager = FakeSourceManager();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AddSourceButton(section: Section.comic, manager: manager),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('添加源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(pair.$1));
      await tester.pumpAndSettle();
      expect(find.text(pair.$2), findsOneWidget);
      expect(find.text(pair.$3), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(manager.imported, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final section in [Section.comic, Section.video]) {
    testWidgets('${section.label}分类拖动后自动保存顺序', (tester) async {
      const entries = [('one', '第一类'), ('two', '第二类'), ('three', '第三类')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSourceEntryOrder(
                  context,
                  section: section,
                  settingKey: 'order.test',
                  entries: entries,
                ),
                child: const Text('排序'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(ReorderableDragStartListener).first,
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();
      expect(
        SourceEntryOrder.read(section, 'order.test', entries).first.$1,
        isNot('one'),
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
