import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/speech/speech_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/speech_modes_panel.dart';

/// Uses the same library and keys as the novel reader, including shared speech settings.
class NovelSettingsPage extends StatefulWidget {
  const NovelSettingsPage({super.key, this.library, this.focus});
  final ReadingLibrary? library;
  final String? focus;

  @override
  State<NovelSettingsPage> createState() => _NovelSettingsPageState();
}

class _NovelSettingsPageState extends State<NovelSettingsPage> {
  final _fontKey = GlobalKey();
  final _heightKey = GlobalKey();
  final _speechKey = GlobalKey();
  bool _focusScheduled = false;
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
                  if (!_focusScheduled && widget.focus != null) {
                    _focusScheduled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      final key = switch (widget.focus) {
                        'font' => _fontKey,
                        'height' => _heightKey,
                        'speech' => _speechKey,
                        _ => null,
                      };
                      final target = key?.currentContext;
                      if (target != null) {
                        Scrollable.ensureVisible(
                          target,
                          duration: const Duration(milliseconds: 250),
                        );
                      }
                    });
                  }
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
                  final dark =
                      theme == 2 ||
                      (theme == 0 &&
                          Theme.of(context).brightness == Brightness.dark);
                  final background = dark
                      ? const Color(0xff17191d)
                      : theme == 1
                      ? const Color(0xfff1e6ce)
                      : Theme.of(context).colorScheme.surface;
                  void saveSpeech(SpeechSettings value) => store.setSetting(
                    SpeechSettings.settingKey,
                    value.encode(),
                  );
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '阅读排版',
                          style: TextStyle(
                            fontSize: LumeTypography.sectionTitleSize,
                            fontWeight: interfaceFontWeight(
                              context,
                              FontWeight.w600,
                            ),
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                key: const Key('novel-settings-preview'),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: background,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  '翻开这一页，故事正缓缓展开。\n愿每一次阅读，都有舒服的节奏。',
                                  style: TextStyle(
                                    fontSize: font,
                                    height: height,
                                    color: dark
                                        ? const Color(0xffd4d2ca)
                                        : const Color(0xff302c27),
                                  ),
                                ),
                              ),
                              Text('字号 ${font.round()}', key: _fontKey),
                              Slider(
                                value: font,
                                min: 14,
                                max: 32,
                                divisions: 18,
                                onChanged: (value) => store.setSetting(
                                  'novel.fontSize',
                                  '$value',
                                ),
                              ),
                              Text(
                                '行距 ${height.toStringAsFixed(1)}',
                                key: _heightKey,
                              ),
                              Slider(
                                value: height,
                                min: 1.3,
                                max: 2.3,
                                divisions: 10,
                                onChanged: (value) => store.setSetting(
                                  'novel.lineHeight',
                                  '$value',
                                ),
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
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () {
                                    store.setSetting('novel.fontSize', '20');
                                    store.setSetting('novel.lineHeight', '1.5');
                                    store.setSetting('novel.theme', '0');
                                  },
                                  icon: const Icon(Icons.restore),
                                  label: const Text('恢复排版默认'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '朗读',
                          key: _speechKey,
                          style: TextStyle(
                            fontSize: LumeTypography.sectionTitleSize,
                            fontWeight: interfaceFontWeight(
                              context,
                              FontWeight.w600,
                            ),
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                '朗读模式、音色、语速、音量和跟随翻页与漫画朗读共用；自动下一章仅用于小说。',
                              ),
                              Text(
                                '语速 ${(speech.rate / .5).toStringAsFixed(1)} 倍',
                              ),
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
                                onChanged: (value) => saveSpeech(
                                  speech.copyWith(followAlong: value),
                                ),
                              ),
                              SwitchListTile(
                                title: const Text('读完自动下一章'),
                                value:
                                    store.setting('novel.speech.autoNext') !=
                                    'false',
                                onChanged: (value) => store.setSetting(
                                  'novel.speech.autoNext',
                                  '$value',
                                ),
                              ),
                              SpeechModesPanel(
                                settings: speech,
                                onChanged: saveSpeech,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      );
    },
  );
}
