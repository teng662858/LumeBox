import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/retired_module_cache.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/total_subscription.dart';
import 'package:lume_box/core/speech/speech_settings.dart';

void main() {
  test('remaining sections and navigation contain no retired module', () {
    expect(Section.values.map((s) => s.id), ['comic', 'video', 'cat']);
    expect(ShellTab.all.map((t) => t.id), [
      'comic',
      'video',
      'settings',
    ]);
    expect(SpeechSettings.settingKey, 'speech.settings');
  });

  test('old navigation removes retired and merged entries, retaining ordering', () {
    final settings = ShellSettings.fromJson({
      'tabs': [
        {'id': 'novel', 'visible': true},
        {'id': 'settings', 'visible': true},
        {'id': 'video', 'visible': false},
        {'id': 'comic', 'visible': true},
        {'id': 'cat', 'visible': true},
      ],
    });
    expect(settings.tabs.map((t) => t.id), [
      'settings',
      'video',
      'comic',
    ]);
    expect(settings.isVisible('video'), isFalse);
  });

  test('old subscription and source backups keep active sections', () {
    final total = TotalSubscription.decode(
      jsonEncode({
        'format': TotalSubscription.format,
        'version': 1,
        'sections': {
          'novel': ['https://example.test/retired'],
          'comic': ['https://example.test/comic'],
          'video': ['https://example.test/video'],
        },
      }),
    );
    expect(total.entries.keys, [Section.comic, Section.video]);
    expect(total.encode(), isNot(contains('retired')));
    final backup = SourceBackup.decode(
      jsonEncode({
        'format': 'lume.sources',
        'version': 1,
        'sections': {'novel': [], 'comic': [], 'video': []},
      }),
    );
    expect(backup.sections.keys, ['comic', 'video']);
  });

  test(
    'text, image and video payloads remain readable after section migration',
    () {
      expect(() => ChapterContent.parse('正文'), throwsFormatException);
      expect(
        (ChapterContent.parse({'kind': 'text', 'text': '正文'}) as TextContent).text,
        '正文',
      );
      expect(
        ChapterContent.parse({
          'kind': 'images',
          'images': ['page.jpg'],
        }),
        isA<ImageContent>(),
      );
      expect(
        ChapterContent.parse({
          'kind': 'video',
          'url': 'https://example.test/video.mp4',
        }),
        isA<VideoContent>(),
      );
    },
  );

  test(
    'cleanup only deletes retired cache, preserving records and other modules',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lumebox-retired-cache-',
      );
      try {
        final paths = [
          'sections/novel/cache/page.txt',
          'sections/novel/reading.db',
          'sections/comic/cache/page.jpg',
          'sections/video/cache/poster.jpg',
          'settings.json',
          'sections/novel/reading_cache/exports/saved.jpg',
        ];
        final image = File(
          '${root.path}/sections/novel/reading_cache/images/cover.jpg',
        );
        await image.parent.create(recursive: true);
        await image.writeAsString('cached');
        for (final path in paths) {
          final file = File('${root.path}/$path');
          await file.parent.create(recursive: true);
          await file.writeAsString('preserved');
        }
        await clearRetiredModuleCache(supportDirectory: root);
        await clearRetiredModuleCache(supportDirectory: root);
        expect(await File('${root.path}/${paths.first}').exists(), isFalse);
        expect(await image.exists(), isFalse);
        for (final path in paths.skip(1)) {
          expect(await File('${root.path}/$path').readAsString(), 'preserved');
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
