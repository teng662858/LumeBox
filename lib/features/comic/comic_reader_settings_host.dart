import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import 'comic_reader_preferences.dart';
import 'comic_reader_settings_page.dart';
import 'comic_settings.dart';

class ComicReaderSettingsHost extends StatefulWidget {
  const ComicReaderSettingsHost({
    super.key,
    this.embedded = false,
    this.onOpenImageSettings,
  });
  final bool embedded;
  final ValueChanged<bool>? onOpenImageSettings;
  @override
  State<ComicReaderSettingsHost> createState() =>
      _ComicReaderSettingsHostState();
}

class _ComicReaderSettingsHostState extends State<ComicReaderSettingsHost> {
  late final library = ReadingLibrary.open(Section.comic);

  @override
  Widget build(BuildContext context) => FutureBuilder<ReadingLibrary>(
    future: library,
    builder: (context, snapshot) {
      final store = snapshot.data;
      if (store == null) {
        return Scaffold(
          appBar: widget.embedded ? null : AppBar(title: const Text('漫画阅读器设置')),
          body: Center(
            child: snapshot.hasError
                ? const Text('阅读设置暂不可用，请返回后重试')
                : const CircularProgressIndicator(),
          ),
        );
      }
      return ListenableBuilder(
        listenable: store.settingsRevision,
        builder: (_, _) {
          final settings = ComicReaderSettings.load(store);
          final preferences = ComicReaderPreferences.load(store);
          return ComicReaderSettingsPage(
            embedded: widget.embedded,
            onOpenImageSettings: widget.onOpenImageSettings,
            settings: settings,
            preferences: preferences,
            onChanged: (next) {
              if (next.mode != settings.mode ||
                  next.direction != settings.direction) {
                preferences.flow = next.mode == ComicReadingMode.waterfall
                    ? 'webtoon'
                    : next.mode == ComicReadingMode.doublePage
                    ? 'spread'
                    : next.isRightToLeft
                    ? 'rtl'
                    : 'ltr';
                preferences.save(store);
              }
              next.save(store);
            },
            onPreferencesChanged: () => preferences.save(store),
          );
        },
      );
    },
  );
}
