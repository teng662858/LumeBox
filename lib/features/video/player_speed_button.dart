import 'package:flutter/material.dart';

import 'player_vertical_menu.dart';

import '../../core/player/player_settings.dart';

/// 按钮旁展开竖向浮层，保留全部倍速档位。
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
    style: PlayerVerticalMenu.style,
    menuChildren: [
      PlayerVerticalMenu.body(
        key: const Key('player-speed-menu'),
        children: [
          for (final speed in PlayerSettings.speeds)
            PlayerVerticalMenu.option(
              label: PlayerSpeedButton.label(speed),
              selected: _speed == speed,
              onSelected: (_) => _select(speed),
            ),
        ],
      ),
    ],
    builder: (context, controller, child) => widget.builder(
      () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}
