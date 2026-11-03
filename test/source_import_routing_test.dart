import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source_import_routing.dart';
import 'package:lume_box/core/source/github_source_repository.dart';
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
  test('Upload chooses directory automatically, preserving identity and marking audio for older Apps', () {
    final upload = GithubSourceRepository.prepareUpload(
      'audio.js',
      Uint8List.fromList(
        utf8.encode(script({'category': 'video', 'mediaType': 'audio'})),
      ),
      fallbackKind: 'video',
    );
    expect(upload.path, 'audiobook/audio.js');
    expect(upload.metadata.category, 'comic');
    expect(utf8.decode(upload.bytes), contains('"mediaType":"audio"'));
    final movie = GithubSourceRepository.prepareUpload(
      'film.js',
      Uint8List.fromList(utf8.encode(script({'category': 'video'}))),
      contentCategory: 'movie',
    );
    expect(movie.path, 'movie/film.js');
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
