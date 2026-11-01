import 'package:flutter/material.dart';

import '../../core/player/player_settings.dart';

/// 倍速直接在按钮旁展开，常用档一按即选，其余档位由滑杆细调。
class PlayerSpeedButton extends StatefulWidget {
  const PlayerSpeedButton({
    super.key,
    required this.speed,
    required this.onChanged,
    required this.builder,
    this.onOpen,
    this.onClose,
  });

  final double speed;
  final ValueChanged<double> onChanged;
  final Widget Function(VoidCallback open) builder;
  final VoidCallback? onOpen, onClose;

  static String label(double value) =>
      '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value}×';

  @override
  State<PlayerSpeedButton> createState() => _PlayerSpeedButtonState();
}

class _PlayerSpeedButtonState extends State<PlayerSpeedButton> {
  final _menu = MenuController();
  late double _speed = widget.speed;

  @override
  void didUpdateWidget(covariant PlayerSpeedButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speed != widget.speed) _speed = widget.speed;
  }

  void _select(double speed) {
    setState(() => _speed = speed);
    widget.onChanged(speed);
    _menu.close();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _menu,
    consumeOutsideTap: true,
    onOpen: widget.onOpen,
    onClose: widget.onClose,
    style: MenuStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    menuChildren: [
      SizedBox(
        key: const Key('player-speed-menu'),
        width: 256,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('倍速')),
                Text(
                  PlayerSpeedButton.label(_speed),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final speed in const [.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                  ChoiceChip(
                    label: Text(PlayerSpeedButton.label(speed)),
                    selected: _speed == speed,
                    showCheckmark: false,
                    onSelected: (_) => _select(speed),
                  ),
              ],
            ),
            Slider(
              value: _speed,
              min: PlayerSettings.minSpeed,
              max: PlayerSettings.maxSpeed,
              divisions: PlayerSettings.speeds.length - 1,
              label: PlayerSpeedButton.label(_speed),
              onChanged: (speed) => setState(() => _speed = speed),
              onChangeEnd: _select,
            ),
          ],
        ),
      ),
    ],
    builder: (context, controller, child) => widget.builder(
      () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}
