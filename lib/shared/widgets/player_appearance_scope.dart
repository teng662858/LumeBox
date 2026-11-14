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
      ],
    ),
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
