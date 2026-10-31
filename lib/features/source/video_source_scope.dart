import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Opens the shared video source picker from a horizontal swipe that starts at
/// either screen edge: right edge → swipe left, left edge → swipe right.
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
  /// 边缘判定宽度：手指按下时离屏幕左右边缘这么近才算「从边缘划出」。
  static const double _edgeWidth = 28;

  /// 触发距离：至少横划这么远才开抽屉（太短当作误触）。
  static const double _minTravel = 64;

  /// 横竖比：横向位移要明显大于纵向，避免斜着滑列表时误开。
  static const double _directionRatio = 1.2;

  Offset _start = Offset.zero;
  Offset _travel = Offset.zero;
  bool _opening = false;
  bool _fromLeft = false;

  bool _startsAtEdge(PointerEvent event) {
    if (_opening) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final position = box.globalToLocal(event.position);
    final fromLeft = position.dx >= 0 && position.dx <= _edgeWidth;
    final fromRight =
        position.dx >= box.size.width - _edgeWidth &&
        position.dx <= box.size.width;
    if (!fromLeft && !fromRight) return false;
    // 极窄宽度下两边都命中时按右边缘处理（与旧行为一致）。
    _fromLeft = fromLeft && !fromRight;
    return true;
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
              if (recognizer.cancelled) return;
              final dx = _travel.dx;
              final horizontal =
                  dx.abs() > _travel.dy.abs() * _directionRatio;
              // 左边边缘往右划、右边边缘往左划，都是「把源抽屉拉出来」。
              final enough = _fromLeft ? dx >= _minTravel : dx <= -_minTravel;
              if (horizontal && enough) _open();
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
