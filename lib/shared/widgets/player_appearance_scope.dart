import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';

/// Marks the shared player UI and every root-navigator panel it opens.
class PlayerAppearanceScope extends InheritedNotifier<FrostedSettings> {
  PlayerAppearanceScope({super.key, required super.child})
    : super(notifier: FrostedSettings.instance);
  static Widget inherit(BuildContext context, Widget child) =>
      context.getInheritedWidgetOfExactType<PlayerAppearanceScope>() == null
      ? child
      : PlayerAppearanceScope(child: child);

  static bool? nativeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlayerAppearanceScope>()
      ?.notifier
      ?.playerNative;
}

class PlayerAppearanceControl extends StatelessWidget {
  const PlayerAppearanceControl({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FrostedSettings.instance,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('播放器外观'),
          subtitle: Text('两种外观共用相同的页面、设置和操作流程'),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('经典版')),
            ButtonSegment(value: true, label: Text('原生玻璃版')),
          ],
          selected: {FrostedSettings.instance.playerNative},
          onSelectionChanged: (value) =>
              FrostedSettings.instance.setPlayerNative(value.single),
        ),
        const SizedBox(height: 16),
        const PlayerGlassShadeControl(),
      ],
    ),
  );
}

class PlayerGlassShadeControl extends StatelessWidget {
  const PlayerGlassShadeControl({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FrostedSettings.instance,
    builder: (context, _) {
      final settings = FrostedSettings.instance;
      if (!settings.playerNative) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('玻璃控制条深浅 ${(settings.playerGlassShade * 100).round()}%'),
          const Text('向左更通透，向右更深；仅调整播放页顶部和底部控制条'),
          Slider(
            key: const ValueKey('player-glass-shade'),
            value: settings.playerGlassShade,
            max: .5,
            divisions: 50,
            label: '${(settings.playerGlassShade * 100).round()}%',
            onChanged: (value) =>
                settings.setPlayerGlassShade(value, persist: false),
            onChangeEnd: (_) => settings.save(),
          ),
          const SizedBox(height: 16),
        ],
      );
    },
  );
}

class PlayerAppearanceMenu extends StatelessWidget {
  const PlayerAppearanceMenu({super.key});
  @override
  Widget build(BuildContext context) => PopupMenuButton<bool>(
    tooltip: '播放器外观',
    icon: const Icon(Icons.auto_awesome_outlined, size: 20),
    initialValue: FrostedSettings.instance.playerNative,
    onSelected: FrostedSettings.instance.setPlayerNative,
    itemBuilder: (_) => const [
      PopupMenuItem(value: false, child: Text('经典版')),
      PopupMenuItem(value: true, child: Text('原生玻璃版')),
    ],
  );
}
