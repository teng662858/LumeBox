import 'package:flutter/material.dart';

/// In portrait, reserve a narrow strip on each side for returning from playback.
class PlayerEdgeBack extends StatelessWidget {
  const PlayerEdgeBack({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled || MediaQuery.orientationOf(context) != Orientation.portrait) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        for (final left in [true, false])
          Positioned(
            top: 0,
            bottom: 0,
            left: left ? 0 : null,
            right: left ? null : 0,
            width: 24,
            child: _EdgeDrag(left: left),
          ),
      ],
    );
  }
}

class _EdgeDrag extends StatefulWidget {
  const _EdgeDrag({required this.left});
  final bool left;

  @override
  State<_EdgeDrag> createState() => _EdgeDragState();
}

class _EdgeDragState extends State<_EdgeDrag> {
  double _distance = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: (_) => _distance = 0,
    onHorizontalDragUpdate: (details) => _distance += details.primaryDelta ?? 0,
    onHorizontalDragEnd: (_) {
      if ((widget.left ? _distance : -_distance) >= 64) {
        Navigator.of(context).maybePop();
      }
      _distance = 0;
    },
    onHorizontalDragCancel: () => _distance = 0,
  );
}
