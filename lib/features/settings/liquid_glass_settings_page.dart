import '../../shared/widgets/native_glass_controls.dart';

import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/dock_native_glass.dart';
import 'settings_ui.dart';

class LiquidGlassSettingsPage extends StatelessWidget {
  const LiquidGlassSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final settings = FrostedSettings.instance;
    return GlassScaffold(
      title: '原生液态玻璃',
      effectModule: GlassModule.settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final style = settings.native;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SettingsPageIntro(
                title: '系统材质',
                description:
                    'iOS 26 及以上使用系统液态玻璃，旧版 iOS 使用系统磨砂材质。模糊、折射和高光由系统自动处理。',
              ),
              SwitchListTile.adaptive(
                title: const Text('轻量效果'),
                subtitle: const Text('使用实色材质，减少实时模糊、折射和叠加效果；保留当前外观参数。'),
                value: settings.lightweight,
                onChanged: settings.setLightweight,
              ),
              if (!DockNativeGlass.supported)
                const SettingsFooterNote('当前平台显示兼容预览；以下原生材质参数在 iOS 上生效。'),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('材质风格'),
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('标准')),
                        ButtonSegment(value: true, label: Text('通透')),
                      ],
                      selected: {style.clear},
                      onSelectionChanged: (v) =>
                          settings.setNative(style.copyWith(clear: v.single)),
                    ),
                    const SizedBox(height: 20),
                    const Text('材质染色'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final color in const [
                          0xFF7862EC,
                          0xFF147EFB,
                          0xFF20A78A,
                          0xFFE78AA7,
                          0xFFFFFFFF,
                          0xFF34343A,
                        ])
                          Semantics(
                            label: '选择材质颜色',
                            selected: style.tint == color,
                            child: InkResponse(
                              onTap: () => settings.setNative(
                                style.copyWith(tint: color),
                              ),
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(color),
                                  border: Border.all(
                                    color: style.tint == color
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                    width: style.tint == color ? 3 : 1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('染色强度 ${(style.tintOpacity * 100).round()}%'),
                    NativeGlassSlider(
                      key: const ValueKey('native-glass-tint'),
                      value: style.tintOpacity,
                      min: 0,
                      max: .5,
                      onChanged: (v) => settings.setNative(
                        settings.native.copyWith(tintOpacity: v),
                        persist: false,
                      ),
                      onChangeEnd: (_) => settings.save(),
                    ),
                    Text('圆角比例 ${(style.radiusScale * 100).round()}%'),
                    NativeGlassSlider(
                      key: const ValueKey('native-glass-radius'),
                      value: style.radiusScale,
                      min: .5,
                      max: 1.5,
                      onChanged: (v) => settings.setNative(
                        settings.native.copyWith(radiusScale: v),
                        persist: false,
                      ),
                      onChangeEnd: (_) => settings.save(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF89B9F3), Color(0xFFEAABC6)],
                  ),
                ),
                child: const FrostedGlassWidget(
                  nativeGlass: true,
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('原生材质预览')),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await settings.setNative(const NativeGlassStyle());
                },
                icon: const Icon(Icons.restart_alt),
                label: const Text('恢复系统材质默认设置'),
              ),
            ],
          );
        },
      ),
    );
  }
}
