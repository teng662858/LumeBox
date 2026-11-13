import 'package:flutter/material.dart';

import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section_module_settings.dart';
import '../settings/experience_settings_card.dart';

/// Defaults consumed by the native playback session. Unsupported legacy
/// Flutter display and gesture settings are not offered in this entry.
class NativeVideoSettingsPage extends StatelessWidget {
  const NativeVideoSettingsPage({
    super.key,
    required this.settings,
    required this.library,
    required this.onChanged,
  });
  final PlayerSettings settings;
  final ReadingLibrary library;
  final ValueChanged<PlayerSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final kernel = this.settings.kernel == PlayerKernel.avplayer
        ? PlayerKernel.avplayer
        : PlayerKernel.mpv;
    final settings = this.settings.copyWith(kernel: kernel);
    return Scaffold(
      appBar: AppBar(title: const Text('播放器设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<PlayerKernel>(
            initialValue: kernel,
            decoration: const InputDecoration(labelText: '默认播放内核'),
            items: const [
              DropdownMenuItem(
                value: PlayerKernel.avplayer,
                child: Text('系统 AVPlayer'),
              ),
              DropdownMenuItem(value: PlayerKernel.mpv, child: Text('MPV')),
            ],
            onChanged: (value) {
              if (value != null) onChanged(settings.copyWith(kernel: value));
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<double>(
            key: ValueKey(
              'native-speed-${settings.kernel.id}-${settings.speed}',
            ),
            initialValue: settings.speed,
            decoration: const InputDecoration(labelText: '播放速度'),
            items: [
              for (final rate in PlayerSettings.speeds)
                DropdownMenuItem(value: rate, child: Text('$rate×')),
            ],
            onChanged: (value) {
              if (value != null) onChanged(settings.copyWith(speed: value));
            },
          ),
          SwitchListTile(
            title: const Text('自动下一集'),
            value: settings.autoNext,
            onChanged: (value) => onChanged(settings.copyWith(autoNext: value)),
          ),
          SwitchListTile(
            title: const Text('显示内嵌字幕'),
            value: settings.subtitlesEnabled,
            onChanged: (value) =>
                onChanged(settings.copyWith(subtitlesEnabled: value)),
          ),
          SwitchListTile(
            title: const Text('MPV 硬件解码'),
            value: settings.hardwareDecoding,
            onChanged: (value) =>
                onChanged(settings.copyWith(hardwareDecoding: value)),
          ),
          const BackgroundPlaybackSetting(),
          const SizedBox(height: 16),
          DropdownButtonFormField<DefaultQuality>(
            initialValue: settings.defaultQuality,
            decoration: const InputDecoration(labelText: '默认清晰度'),
            items: [
              for (final quality in DefaultQuality.values)
                DropdownMenuItem(value: quality, child: Text(quality.label)),
            ],
            onChanged: (value) {
              if (value != null) onChanged(settings.copyWith(defaultQuality: value));
            },
          ),
          SwitchListTile(
            title: const Text('记住手动选择的清晰度'),
            value: settings.rememberManualQuality,
            onChanged: (value) =>
                onChanged(settings.copyWith(rememberManualQuality: value)),
          ),
          const Text('音轨、字幕文件、画面比例、线路和画质可在播放页调整。'),
          const SizedBox(height: 16),
          StatefulBuilder(
            builder: (context, update) {
              final buffer = SectionModuleSettings.load(library);
              return Column(
                children: [
                  TextFormField(
                    initialValue: '${buffer.bufferSeconds}',
                    decoration: const InputDecoration(
                      labelText: '前向缓冲秒数',
                      helperText: '0 使用默认策略，起播不等待缓存填满',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      final seconds = int.tryParse(value);
                      if (seconds != null && seconds >= 0) {
                        SectionModuleSettings.load(library)
                            .copyWith(bufferSeconds: seconds.clamp(0, 86400))
                            .save(library);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue:
                        const [
                          32,
                          64,
                          128,
                          256,
                          512,
                          1024,
                        ].contains(buffer.bufferMiB)
                        ? buffer.bufferMiB
                        : null,
                    decoration: InputDecoration(
                      labelText: 'MPV 内存缓冲上限',
                      hintText: '${buffer.bufferMiB} MiB',
                    ),
                    items: [
                      for (final amount in const [32, 64, 128, 256, 512, 1024])
                        DropdownMenuItem(
                          value: amount,
                          child: Text('$amount MiB'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(
                          () =>
                              SectionModuleSettings.load(library)
                                  .copyWith(bufferMiB: value)
                                  .save(library),
                        );
                      }
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
