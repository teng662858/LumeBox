import 'package:flutter/material.dart';

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import '../../core/player/player_settings.dart';

/// 磨砂浮层：左侧竖向微调，右侧仅展示常用档位。
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
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    menuChildren: [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            key: const Key('player-speed-menu'),
            width: 208,
            height: math.max(
              160,
              math.min(304, MediaQuery.sizeOf(context).height - 80),
            ),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xC42A2C32),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x26FFFFFF), width: .5),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 38,
                        child: Column(
                          children: [
                            const Text(
                              '4×',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                            Expanded(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 14,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 9,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                    activeTrackColor: const Color(0xFF4F9DFF),
                                    inactiveTrackColor: Colors.white12,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: _speed,
                                    min: PlayerSettings.minSpeed,
                                    max: PlayerSettings.maxSpeed,
                                    divisions: PlayerSettings.speeds.length - 1,
                                    label: PlayerSpeedButton.label(_speed),
                                    onChanged: (value) =>
                                        setState(() => _speed = value),
                                    onChangeEnd: _select,
                                  ),
                                ),
                              ),
                            ),
                            const Text(
                              '0.25×',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          primary: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final speed in const [
                                3.0,
                                2.0,
                                1.5,
                                1.25,
                                1.0,
                                .75,
                                .5,
                              ])
                                ChoiceChip(
                                  label: SizedBox(
                                    width: double.infinity,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (_speed == speed) ...[
                                          const Icon(
                                            Icons.check_rounded,
                                            size: 15,
                                            color: Color(0xFF75B2FF),
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Text(PlayerSpeedButton.label(speed)),
                                        if (speed == 1) const Text(' 常速'),
                                      ],
                                    ),
                                  ),
                                  selected: _speed == speed,
                                  showCheckmark: false,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  side: BorderSide.none,
                                  backgroundColor: Colors.transparent,
                                  selectedColor: const Color(0x334F9DFF),
                                  labelStyle: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: _speed == speed
                                        ? const Color(0xFF75B2FF)
                                        : Colors.white,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  onSelected: (_) => _select(speed),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 16, color: Colors.white12),
                Text(
                  '${PlayerSpeedButton.label(_speed)}${_speed == 1 ? ' 常速' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
    builder: (context, controller, child) => widget.builder(
      () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}
