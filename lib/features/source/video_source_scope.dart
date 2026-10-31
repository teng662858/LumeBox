import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Opens the shared video source picker from a leftward swipe at the right edge.
class SourcePickerEdgeSwipe extends StatefulWidget {
  const SourcePickerEdgeSwipe({
    super.key,
    required this.onOpen,
    required this.child,
  });

  final Future<void> Function() onOpen;
  final Widget child;

  @override
  State<SourcePickerEdgeSwipe> createState() => _SourcePickerEdgeSwipeState();
}

class _SourcePickerEdgeSwipeState extends State<SourcePickerEdgeSwipe> {
  Offset _start = Offset.zero;
  Offset _travel = Offset.zero;
  bool _opening = false;

  bool _startsAtEdge(PointerEvent event) {
    if (_opening) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final position = box.globalToLocal(event.position);
    return position.dx >= box.size.width - 28 && position.dx <= box.size.width;
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      await widget.onOpen();
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    gestures: {
      _SourceEdgeDrag: GestureRecognizerFactoryWithHandlers<_SourceEdgeDrag>(
        () => _SourceEdgeDrag(debugOwner: this),
        (recognizer) {
          recognizer
            ..startsAtEdge = _startsAtEdge
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = (details) {
              _start = details.globalPosition;
              _travel = Offset.zero;
            }
            ..onUpdate = (details) {
              _travel = details.globalPosition - _start;
            }
            ..onEnd = (_) {
              if (!recognizer.cancelled &&
                  _travel.dx <= -64 &&
                  _travel.dx.abs() > _travel.dy.abs() * 1.2) {
                _open();
              }
            }
            ..onCancel = () => _travel = Offset.zero;
        },
      ),
    },
    child: widget.child,
  );
}

/// Outside the edge strip, leave horizontal gestures to the content below.
class _SourceEdgeDrag extends HorizontalDragGestureRecognizer {
  _SourceEdgeDrag({super.debugOwner});

  late bool Function(PointerEvent event) startsAtEdge;
  bool cancelled = false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      startsAtEdge(event) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    cancelled = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) cancelled = true;
    super.handleEvent(event);
  }
}

/// Video and Cat keep their own stores; this scope only shares navigation.
class VideoSourceScope extends InheritedWidget {
  const VideoSourceScope({
    super.key,
    required this.openPicker,
    required super.child,
  });

  final Future<void> Function(BuildContext context) openPicker;

  static VideoSourceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoSourceScope>();

  @override
  bool updateShouldNotify(VideoSourceScope oldWidget) => false;
}
