import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/speech/speech_settings.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/speech_modes_panel.dart';

/// Uses the same library and keys as the novel reader, including shared speech settings.
class NovelSettingsPage extends StatefulWidget {
  const NovelSettingsPage({super.key, this.library});
  final ReadingLibrary? library;

  @override
  State<NovelSettingsPage> createState() => _NovelSettingsPageState();
}

class _NovelSettingsPageState extends State<NovelSettingsPage> {
  late final Future<ReadingLibrary> library = widget.library == null
      ? ReadingLibrary.open(Section.comic)
      : Future.value(widget.library);

  @override
  Widget build(BuildContext context) => FutureBuilder<ReadingLibrary>(
    future: library,
    builder: (context, snapshot) {
      final store = snapshot.data;
      return GlassScaffold(
        title: '小说设置',
        effectModule: GlassModule.settings,
        child: store == null
            ? Center(
                child: snapshot.hasError
                    ? const Text('阅读设置暂不可用')
                    : const CircularProgressIndicator(),
              )
            : ListenableBuilder(
                listenable: store.settingsRevision,
                builder: (context, _) {
                  final font =
                      (double.tryParse(store.setting('novel.fontSize') ?? '') ??
                              20)
                          .clamp(14.0, 32.0);
                  final height =
                      (double.tryParse(
                                store.setting('novel.lineHeight') ?? '',
                              ) ??
                              1.5)
                          .clamp(1.3, 2.3);
                  final theme =
                      (int.tryParse(store.setting('novel.theme') ?? '') ?? 0)
                          .clamp(0, 2);
                  final speech = SpeechSettings.decode(
                    store.setting(SpeechSettings.settingKey),
                  );
                  void saveSpeech(SpeechSettings value) => store.setSetting(
                    SpeechSettings.settingKey,
                    value.encode(),
                  );
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text(
                        '阅读排版',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('字号 ${font.round()}'),
                      Slider(
                        value: font,
                        min: 14,
                        max: 32,
                        divisions: 18,
                        onChanged: (value) =>
                            store.setSetting('novel.fontSize', '$value'),
                      ),
                      Text('行距 ${height.toStringAsFixed(1)}'),
                      Slider(
                        value: height,
                        min: 1.3,
                        max: 2.3,
                        divisions: 10,
                        onChanged: (value) =>
                            store.setSetting('novel.lineHeight', '$value'),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final entry in const {
                            0: '跟随系统',
                            1: '护眼',
                            2: '夜间',
                          }.entries)
                            ChoiceChip(
                              label: Text(entry.value),
                              selected: theme == entry.key,
                              onSelected: (_) => store.setSetting(
                                'novel.theme',
                                '${entry.key}',
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        '朗读',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Text('朗读声音与漫画朗读共用设置'),
                      Text('语速 ${(speech.rate / .5).toStringAsFixed(1)} 倍'),
                      Slider(
                        value: speech.rate,
                        min: SpeechSettings.minRate,
                        max: SpeechSettings.maxRate,
                        onChanged: (value) =>
                            saveSpeech(speech.copyWith(rate: value)),
                      ),
                      Text('音量 ${(speech.volume * 100).round()}%'),
                      Slider(
                        value: speech.volume,
                        onChanged: (value) =>
                            saveSpeech(speech.copyWith(volume: value)),
                      ),
                      SwitchListTile(
                        title: const Text('朗读跟随翻页'),
                        value: speech.followAlong,
                        onChanged: (value) =>
                            saveSpeech(speech.copyWith(followAlong: value)),
                      ),
                      SwitchListTile(
                        title: const Text('读完自动下一章'),
                        value:
                            store.setting('novel.speech.autoNext') != 'false',
                        onChanged: (value) =>
                            store.setSetting('novel.speech.autoNext', '$value'),
                      ),
                      SpeechModesPanel(settings: speech, onChanged: saveSpeech),
                    ],
                  );
                },
              ),
      );
    },
  );
}
