import 'package:flutter/material.dart';

import '../../core/session/app_preferences.dart';
import '../../shared/widgets/glass_card.dart';

class ExperienceSettingsCard extends StatefulWidget {
  const ExperienceSettingsCard({super.key});
  @override
  State<ExperienceSettingsCard> createState() => _ExperienceSettingsCardState();
}

class _ExperienceSettingsCardState extends State<ExperienceSettingsCard> {
  final preferences = AppPreferences.instance;
  @override
  Widget build(BuildContext context) => GlassCard(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('使用体验', style: Theme.of(context).textTheme.headlineSmall),
        ),
        SwitchListTile(
          title: const Text('触感反馈'),
          value: preferences.haptics,
          onChanged: (value) {
            setState(() => preferences.haptics = value);
            preferences.save();
            preferences.selectionFeedback();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('触感强度'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final strength in HapticStrength.values)
                    ChoiceChip(
                      label: Text(strength.label),
                      selected: preferences.hapticStrength == strength,
                      onSelected: preferences.haptics
                          ? (_) {
                              setState(
                                () => preferences.hapticStrength = strength,
                              );
                              preferences.save();
                              preferences.selectionFeedback();
                            }
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class BackgroundPlaybackSetting extends StatefulWidget {
  const BackgroundPlaybackSetting({super.key});
  @override
  State<BackgroundPlaybackSetting> createState() =>
      _BackgroundPlaybackSettingState();
}

class _BackgroundPlaybackSettingState extends State<BackgroundPlaybackSetting> {
  @override
  Widget build(BuildContext context) => GlassCard(
    padding: EdgeInsets.zero,
    child: SwitchListTile(
      title: const Text('后台播放'),
      subtitle: const Text('视频退到后台时继续播放音频'),
      value: AppPreferences.instance.backgroundPlayback,
      onChanged: (value) {
        setState(() => AppPreferences.instance.backgroundPlayback = value);
        AppPreferences.instance.save();
      },
    ),
  );
}
