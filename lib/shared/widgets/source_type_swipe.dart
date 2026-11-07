import 'package:flutter/material.dart';

/// Page-like swipes change the displayed source type. Short swipes leave cards
/// in place, and edge gestures belong to the enclosing drawer.
class SourceTypeSwipe extends StatefulWidget {
  const SourceTypeSwipe({super.key, required this.onStep, required this.child});
  final ValueChanged<int> onStep;
  final Widget child;
  @override
  State<SourceTypeSwipe> createState() => _SourceTypeSwipeState();
}

class _SourceTypeSwipeState extends State<SourceTypeSwipe> {
  int? _pointer;
  Offset _start = Offset.zero;
  Offset _travel = Offset.zero;
  Duration _started = Duration.zero;
  bool _eligible = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_pointer != null) {
          _eligible = false;
          return;
        }
        _pointer = event.pointer;
        _start = event.localPosition;
        _travel = Offset.zero;
        _started = event.timeStamp;
        final edges = MediaQuery.systemGestureInsetsOf(context);
        _eligible =
            _start.dx > edges.left + 32 &&
            _start.dx < bounds.maxWidth - edges.right - 32;
      },
      onPointerMove: (event) {
        if (_pointer == event.pointer) _travel = event.localPosition - _start;
      },
      onPointerCancel: (event) {
        if (_pointer == event.pointer) _pointer = null;
      },
      onPointerUp: (event) {
        if (_pointer != event.pointer) return;
        _pointer = null;
        final elapsed = event.timeStamp - _started;
        if (_eligible &&
            elapsed < const Duration(milliseconds: 600) &&
            _travel.dx.abs() >= 72 &&
            _travel.dx.abs() > _travel.dy.abs() * 1.5) {
          widget.onStep(_travel.dx < 0 ? 1 : -1);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Own horizontal drags over blank list space, keeping the drawer still.
        onHorizontalDragUpdate: (_) {},
        child: widget.child,
      ),
    ),
  );
}
