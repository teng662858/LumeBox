import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../../shared/widgets/video_glass_surface.dart';

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
      VideoGlassSurface(
        radius: 16,
        dark: Theme.of(context).brightness == Brightness.dark,
        materialOpacity: VideoGlassSurface.panelOpacity,
        child: Builder(
          builder: (context) => Container(
            key: const Key('player-speed-menu'),
            width: 184,
            height: math.max(
              160,
              math.min(264, MediaQuery.sizeOf(context).height - 80),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Column(
                          children: [
                            Text(
                              '4×',
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            Expanded(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 12,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 8,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 12,
                                    ),
                                    activeTrackColor: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    inactiveTrackColor: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: .12),
                                    thumbColor: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
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
                            Text(
                              '0.25×',
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
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
                                          Icon(
                                            Icons.check_rounded,
                                            size: 15,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Text(PlayerSpeedButton.label(speed)),
                                        if (speed == 1) Text(' 常速'),
                                      ],
                                    ),
                                  ),
                                  selected: _speed == speed,
                                  showCheckmark: false,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 1,
                                  ),
                                  side: BorderSide.none,
                                  color: const WidgetStatePropertyAll(
                                    Colors.transparent,
                                  ),
                                  backgroundColor: Colors.transparent,
                                  selectedColor: Colors.transparent,
                                  disabledColor: Colors.transparent,
                                  surfaceTintColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  elevation: 0,
                                  pressElevation: 0,
                                  labelStyle: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: _speed == speed
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface,
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
                Divider(height: 12, color: Theme.of(context).dividerColor),
                Text(
                  '${PlayerSpeedButton.label(_speed)}${_speed == 1 ? ' 常速' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
