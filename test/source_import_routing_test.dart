import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source_import_routing.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/source/source_import_flow.dart';
import 'package:lume_box/features/source/subscription_sync_report.dart';

import 'support/fake_source_manager.dart';

String script(Map<String, Object> values) =>
    '// LumeSource: ${jsonEncode({'id': 'sample', 'name': 'Sample', 'version': '1', ...values})}\nvar LumeSource={};';
void main() {
  test('Automatic board and repository directory use media metadata before video labels', () {
    for (final (meta, section, kind) in [
      ({'category': 'video', 'mediaType': 'audio'}, Section.comic, 'audiobook'),
      ({'category': 'novel'}, Section.comic, 'novel'),
      ({'category': 'photo'}, Section.comic, 'photo'),
      ({'category': 'comic'}, Section.comic, 'comic'),
      (
        {'category': 'video', 'contentCategory': 'movie'},
        Section.video,
        'movie',
      ),
      (
        {'category': 'video', 'contentCategory': 'adult'},
        Section.video,
        'video',
      ),
    ]) {
      expect(
        SourceImportRouting.section(script(meta), fallback: Section.cat),
        section,
      );
      expect(SourceImportRouting.repositoryKind(script(meta)), kind);
      expect(
        SourceImportRouting.section(
          script(meta).replaceFirst('//', '#'),
          fallback: Section.cat,
        ),
        section,
      );
    }
  });
  test('声明视频综合内容的听书源保留视频板块', () {
    final mixed = script({
      'category': 'video',
      'contentTypes': ['audio', 'video'],
    }).replaceFirst('Sample', '听友听书');
    expect(SourceImportRouting.section(mixed), Section.video);
  });
  testWidgets(
    'Importing audio from video automatically installs into comic and notifies selection',
    (tester) async {
      final video = FakeSourceManager(), comic = FakeSourceManager();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final revision = SourceSubscriptionSync.revision(Section.comic).value;
      final notices = SourceSubscriptionSync.changeCount(Section.comic).value;
      final done = await importSources(
        context,
        manager: video,
        section: Section.video,
        managers: {Section.comic: comic},
        items: [
          SourceImportItem(
            script: script({'category': 'video', 'mediaType': 'audio'}),
          ),
        ],
      );
      await tester.pump();
      expect(done, isTrue);
      expect(
        SourceSubscriptionSync.changeCount(Section.comic).value,
        notices,
        reason: '手动首次导入不产生订阅更新提醒',
      );
      expect(video.imported, isEmpty);
      expect(comic.imported, hasLength(1));
      expect(comic.sources, hasLength(1));
      expect(
        SourceSubscriptionSync.revision(Section.comic).value,
        greaterThan(revision),
      );
      expect(find.textContaining('已自动归入漫画'), findsOneWidget);
    },
  );
  testWidgets(
    'Subscription results collapse long diagnostics and explain unchanged counts',
    (tester) async {
      final result = SubscriptionSyncResult()
        ..added = 2
        ..unchanged = 54
        ..checked = 4
        ..errors.add(
          'https://example.invalid/audiobook/audio.js: 跨板块源被拒绝：technical-details',
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionSyncReport(results: {Section.comic: result}),
          ),
        ),
      );
      expect(find.textContaining('已存在 54'), findsOneWidget);
      expect(find.textContaining('technical-details'), findsNothing);
      await tester.tap(find.text('查看未导入原因'));
      await tester.pumpAndSettle();
      expect(find.text('audio'), findsOneWidget);
      expect(find.textContaining('technical-details'), findsNothing);
      await tester.tap(find.text('audio'));
      await tester.pumpAndSettle();
      expect(find.textContaining('technical-details'), findsOneWidget);
    },
  );
}
