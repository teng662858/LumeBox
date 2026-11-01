import '../../shared/widgets/browse_side_drawer.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Edge-only gestures, with independent left/right panels and live drag motion.
/// The onOpen fallback supports callers that only need a settled swipe action.
class SourcePickerEdgeSwipe extends StatefulWidget {
  const SourcePickerEdgeSwipe({
    super.key,
    required this.onOpen,
    required this.child,
    this.onOpenLeft,
    this.onOpenRight,
  });

  final Future<void> Function() onOpen;
  final Widget child;
  final Future<void> Function(BrowseDrawerMotion motion)? onOpenLeft,
      onOpenRight;

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
  BrowseDrawerMotion? _motion;
  double _width = 1;

  @override
  void dispose() {
    _motion?.settle(false);
    super.dispose();
  }

  bool _startsAtEdge(PointerEvent event) {
    if (_opening) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final position = box.globalToLocal(event.position);
    // Keep native Back gestures in their reserved strip (notably Android).
    final systemEdges = MediaQuery.systemGestureInsetsOf(context);
    final fromLeft =
        position.dx >= systemEdges.left &&
        position.dx <= systemEdges.left + _edgeWidth;
    final fromRight =
        position.dx >= box.size.width - systemEdges.right - _edgeWidth &&
        position.dx <= box.size.width - systemEdges.right;
    if (!fromLeft && !fromRight) return false;
    // 极窄宽度下两边都命中时按右边缘处理（与旧行为一致）。
    _fromLeft = fromLeft && !fromRight;
    _width = browseDrawerWidth(box.size.width);
    return true;
  }

  Future<void> _open({BrowseDrawerMotion? motion}) async {
    if (_opening) return;
    _opening = true;
    try {
      final callback = _fromLeft ? widget.onOpenLeft : widget.onOpenRight;
      if (motion != null && callback != null) {
        await callback(motion);
      } else {
        await widget.onOpen();
      }
    } finally {
      _opening = false;
      if (identical(_motion, motion)) _motion = null;
      motion?.dispose();
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
              final distance = _fromLeft ? _travel.dx : -_travel.dx;
              final callback = _fromLeft
                  ? widget.onOpenLeft
                  : widget.onOpenRight;
              if (_motion == null &&
                  !_opening &&
                  callback != null &&
                  distance > 8 &&
                  distance > _travel.dy.abs() * _directionRatio) {
                _motion = BrowseDrawerMotion();
                _motion!.update(distance / _width);
                _open(motion: _motion);
              }
              _motion?.update(distance / _width);
            }
            ..onEnd = (details) {
              if (recognizer.cancelled) {
                _motion?.settle(false);
                return;
              }
              final input = _motion;
              if (input != null) {
                final velocity =
                    (_fromLeft ? 1 : -1) * (details.primaryVelocity ?? 0);
                input.settle(
                  velocity > 650 || (velocity >= -650 && input.progress >= .5),
                );
                return;
              }
              final dx = _travel.dx;
              final horizontal = dx.abs() > _travel.dy.abs() * _directionRatio;
              // 左边边缘往右划、右边边缘往左划，都是「把源抽屉拉出来」。
              final enough = _fromLeft ? dx >= _minTravel : dx <= -_minTravel;
              if (horizontal && enough) _open();
            }
            ..onCancel = () {
              _travel = Offset.zero;
              _motion?.settle(false);
            };
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

  final Future<void> Function(
    BuildContext context, {
    BrowseDrawerMotion? motion,
  })
  openPicker;

  static VideoSourceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoSourceScope>();

  @override
  bool updateShouldNotify(VideoSourceScope oldWidget) => false;
}
